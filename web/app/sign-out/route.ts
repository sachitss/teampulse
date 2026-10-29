import { NextResponse, type NextRequest } from 'next/server';
import { cookies } from 'next/headers';
import { DEV_COOKIE, supabaseServer, supabaseConfigured } from '@/lib/auth';

export async function POST(request: NextRequest) {
  (await cookies()).delete(DEV_COOKIE);
  if (supabaseConfigured()) await (await supabaseServer()).auth.signOut();
  return NextResponse.redirect(new URL('/sign-in', request.url), { status: 303 });
}
