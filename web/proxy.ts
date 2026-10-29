// Next.js 16 proxy (formerly middleware). Keeps the Supabase session fresh on every
// request so server pages always see a valid, verified token. Access decisions are
// NOT made here — pages call requireMe(), and the database enforces RLS.
import { NextResponse, type NextRequest } from 'next/server';
import { createServerClient } from '@supabase/ssr';

export async function proxy(request: NextRequest) {
  const url = process.env.NEXT_PUBLIC_SUPABASE_URL, key = process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY;
  if (!url || !key) return NextResponse.next();

  let response = NextResponse.next({ request });
  const supabase = createServerClient(url, key, {
    cookies: {
      getAll: () => request.cookies.getAll(),
      setAll: (list) => {
        list.forEach(({ name, value }) => request.cookies.set(name, value));
        response = NextResponse.next({ request });
        list.forEach(({ name, value, options }) => response.cookies.set(name, value, options));
      },
    },
  });
  await supabase.auth.getClaims();   // refreshes an expired access token using the refresh token
  return response;
}

export const config = {
  // Skip static files, icons, the service worker and the manifest.
  matcher: ['/((?!_next/|icons/|favicon.ico|sw.js|manifest.webmanifest).*)'],
};
