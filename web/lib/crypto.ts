// Small, dependency-free crypto helpers for sign-in. Pure functions: unit-tested directly.
import { createHash, createHmac, randomBytes, createCipheriv, createDecipheriv, timingSafeEqual } from 'node:crypto';

export function sha256(data: string | Buffer): Buffer {
  return createHash('sha256').update(data).digest();
}

/** URL-safe random token (default 32 bytes = 256 bits). */
export function randomToken(bytes = 32): string {
  return randomBytes(bytes).toString('base64url');
}

// ---------------------------------------------------------------------------
// AES-256-GCM for secrets at rest (two-factor secrets; later PAN/bank numbers).
// Key: ENCRYPTION_KEY = 32 random bytes, base64. Output: iv(12) | tag(16) | ciphertext.
// ---------------------------------------------------------------------------
function key(): Buffer {
  const k = Buffer.from(process.env.ENCRYPTION_KEY ?? '', 'base64');
  if (k.length !== 32) throw new Error('ENCRYPTION_KEY must be 32 random bytes, base64-encoded (openssl rand -base64 32)');
  return k;
}

export function encrypt(plain: string): Buffer {
  const iv = randomBytes(12);
  const c = createCipheriv('aes-256-gcm', key(), iv);
  const body = Buffer.concat([c.update(plain, 'utf8'), c.final()]);
  return Buffer.concat([iv, c.getAuthTag(), body]);
}

export function decrypt(blob: Buffer): string {
  const d = createDecipheriv('aes-256-gcm', key(), blob.subarray(0, 12));
  d.setAuthTag(blob.subarray(12, 28));
  return Buffer.concat([d.update(blob.subarray(28)), d.final()]).toString('utf8');
}

// ---------------------------------------------------------------------------
// TOTP (RFC 6238): SHA-1, 30-second steps, 6 digits — what every authenticator app uses.
// ---------------------------------------------------------------------------
const B32 = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ234567';

export function base32Encode(buf: Buffer): string {
  let bits = 0, value = 0, out = '';
  for (const byte of buf) {
    value = (value << 8) | byte; bits += 8;
    while (bits >= 5) { out += B32[(value >>> (bits - 5)) & 31]; bits -= 5; }
  }
  if (bits > 0) out += B32[(value << (5 - bits)) & 31];
  return out;
}

export function base32Decode(s: string): Buffer {
  const clean = s.toUpperCase().replace(/[^A-Z2-7]/g, '');
  let bits = 0, value = 0; const out: number[] = [];
  for (const ch of clean) {
    value = (value << 5) | B32.indexOf(ch); bits += 5;
    if (bits >= 8) { out.push((value >>> (bits - 8)) & 255); bits -= 8; }
  }
  return Buffer.from(out);
}

export function newTotpSecret(): string {
  return base32Encode(randomBytes(20));   // 160-bit secret
}

export function hotp(secret: Buffer, counter: number, digits = 6): string {
  const msg = Buffer.alloc(8);
  msg.writeBigUInt64BE(BigInt(counter));
  const h = createHmac('sha1', secret).update(msg).digest();
  const off = h[h.length - 1] & 0x0f;
  const bin = ((h[off] & 0x7f) << 24) | (h[off + 1] << 16) | (h[off + 2] << 8) | h[off + 3];
  return String(bin % 10 ** digits).padStart(digits, '0');
}

export function totpCounter(nowMs = Date.now()): number {
  return Math.floor(nowMs / 1000 / 30);
}

export function totp(secretB32: string, nowMs = Date.now()): string {
  return hotp(base32Decode(secretB32), totpCounter(nowMs));
}

/**
 * Check a 6-digit code, allowing one step either side for phone clock drift.
 * Returns the matching counter (to block replay of the same code), or null.
 */
export function verifyTotp(secretB32: string, code: string, nowMs = Date.now(), lastCounter: number | null = null): number | null {
  if (!/^\d{6}$/.test(code)) return null;
  const secret = base32Decode(secretB32);
  const now = totpCounter(nowMs);
  for (const c of [now, now - 1, now + 1]) {
    if (lastCounter !== null && c <= lastCounter) continue;
    const expect = Buffer.from(hotp(secret, c));
    if (timingSafeEqual(expect, Buffer.from(code))) return c;
  }
  return null;
}

export function otpauthUri(secretB32: string, account: string, issuer = 'TeamPulse'): string {
  const label = encodeURIComponent(`${issuer}:${account}`);
  return `otpauth://totp/${label}?secret=${secretB32}&issuer=${encodeURIComponent(issuer)}&algorithm=SHA1&digits=6&period=30`;
}
