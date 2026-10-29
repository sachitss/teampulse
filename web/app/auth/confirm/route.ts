// Links in invitation and password-reset emails land here.
// Supabase email templates must point to:
//   {{ .SiteURL }}/auth/confirm?token_hash={{ .TokenHash }}&type=invite&next=/reset-password    (Invite user)
//   {{ .SiteURL }}/auth/confirm?token_hash={{ .TokenHash }}&type=recovery&next=/reset-password  (Reset password)
import { type NextRequest, NextResponse } from 'next/server';
import type { EmailOtpType } from '@supabase/supabase-js';
import { supabaseServer, supabaseConfigured } from '@/lib/auth';

const ALLOWED_NEXT = new Set(['/reset-password', '/today']);

export async function GET(request: NextRequest) {
  const { searchParams, origin } = new URL(request.url);
  const tokenHash = searchParams.get('token_hash');
  const type = searchParams.get('type') as EmailOtpType | null;
  const next = ALLOWED_NEXT.has(searchParams.get('next') ?? '') ? searchParams.get('next')! : '/today';
  if (supabaseConfigured() && tokenHash && type) {
    const sb = await supabaseServer();
    const { error } = await sb.auth.verifyOtp({ type, token_hash: tokenHash });
    if (!error) return NextResponse.redirect(`${origin}${next}`);
  }
  return NextResponse.redirect(`${origin}/sign-in?link=expired`);
}
