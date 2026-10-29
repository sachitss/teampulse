import type { MetadataRoute } from 'next';

// Makes TeamPulse installable from the browser on Windows, macOS, Android and iPhone.
export default function manifest(): MetadataRoute.Manifest {
  return {
    id: '/',
    name: 'TeamPulse — PEACE Consultancy',
    short_name: 'TeamPulse',
    description: 'Time, tasks, leave and payslips for the PEACE team.',
    start_url: '/today',
    scope: '/',
    display: 'standalone',
    orientation: 'any',
    background_color: '#f6f7f6',
    theme_color: '#0f5257',
    lang: 'en',
    categories: ['business', 'productivity'],
    icons: [
      { src: '/icons/icon-192.png', sizes: '192x192', type: 'image/png', purpose: 'any' },
      { src: '/icons/icon-512.png', sizes: '512x512', type: 'image/png', purpose: 'any' },
      { src: '/icons/icon-maskable-512.png', sizes: '512x512', type: 'image/png', purpose: 'maskable' },
    ],
    shortcuts: [
      { name: 'Today', url: '/today' },
      { name: 'Timesheet', url: '/timesheet' },
    ],
  };
}
