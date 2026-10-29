// Outgoing email over plain SMTP (Synology MailPlus, Google Workspace, Zoho, Microsoft 365,
// or any provider PEACE already uses). Optional: without SMTP settings the app still works,
// and invitation / reset links are shown to the admin to pass on instead.
import 'server-only';
import nodemailer from 'nodemailer';
import { asSystem } from './db.ts';

export function mailConfigured(): boolean {
  return Boolean(process.env.SMTP_HOST && process.env.MAIL_FROM);
}

let transport: nodemailer.Transporter | null = null;
function transporter(): nodemailer.Transporter {
  transport ??= nodemailer.createTransport({
    host: process.env.SMTP_HOST,
    port: Number(process.env.SMTP_PORT ?? 587),
    secure: Number(process.env.SMTP_PORT ?? 587) === 465,
    requireTLS: Number(process.env.SMTP_PORT ?? 587) !== 465,
    auth: process.env.SMTP_USER ? { user: process.env.SMTP_USER, pass: process.env.SMTP_PASSWORD } : undefined,
  });
  return transport;
}

/** Send a plain-text email. Returns false (never throws) if it could not be sent. */
export async function sendMail(to: string, subject: string, text: string, kind: string): Promise<boolean> {
  if (!mailConfigured()) return false;
  let ok = true, error: string | null = null;
  try {
    await transporter().sendMail({ from: process.env.MAIL_FROM, to, subject, text });
  } catch (e) {
    ok = false; error = (e as Error).message.slice(0, 300);
    console.error('email failed', kind, error);
  }
  // Log the fact of sending — never the body, which may contain a sign-in link.
  await asSystem((db) => db.query(
    `insert into email_log (kind, recipients, subject, status, attempts, last_error, sent_at)
     values ($1, array[$2], $3, $4::email_status, 1, $5, case when $4 = 'sent' then now() end)`,
    [kind, to, subject, ok ? 'sent' : 'failed', error])).catch(() => {});
  return ok;
}

export function appUrl(path: string): string {
  return `${(process.env.APP_BASE_URL ?? 'http://localhost:3000').replace(/\/$/, '')}${path}`;
}
