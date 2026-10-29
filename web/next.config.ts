import type { NextConfig } from 'next';

const securityHeaders = [
  { key: 'X-Content-Type-Options', value: 'nosniff' },
  { key: 'X-Frame-Options', value: 'DENY' },
  { key: 'Referrer-Policy', value: 'strict-origin-when-cross-origin' },
  { key: 'Permissions-Policy', value: 'camera=(), microphone=(), geolocation=()' },
];

const nextConfig: NextConfig = {
  // The shared BS calendar package ships TypeScript source.
  transpilePackages: ['@teampulse/bs-calendar'],
  serverExternalPackages: ['pg'],
  poweredByHeader: false,
  async headers() {
    return [
      { source: '/:path*', headers: securityHeaders },
      // The service worker must never be cached by the browser, so updates reach every device.
      { source: '/sw.js', headers: [{ key: 'Cache-Control', value: 'no-cache, no-store, must-revalidate' },
                                     { key: 'Content-Type', value: 'application/javascript; charset=utf-8' },
                                     { key: 'Content-Security-Policy', value: "default-src 'self'; script-src 'self'" }] },
    ];
  },
};

export default nextConfig;
