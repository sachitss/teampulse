import type { Metadata, Viewport } from 'next';
import './globals.css';
import { RegisterServiceWorker } from '@/components/register-sw';

export const metadata: Metadata = {
  title: { default: 'TeamPulse', template: '%s · TeamPulse' },
  description: 'Time, tasks, leave and payslips for the PEACE team.',
  applicationName: 'TeamPulse',
  appleWebApp: { capable: true, title: 'TeamPulse', statusBarStyle: 'black-translucent' },
  icons: { icon: '/favicon.ico', apple: '/icons/apple-touch-icon.png' },
  robots: { index: false, follow: false },
};

export const viewport: Viewport = {
  themeColor: '#0f5257',
  width: 'device-width',
  initialScale: 1,
  viewportFit: 'cover',
};

export default function RootLayout({ children }: { children: React.ReactNode }) {
  return (
    <html lang="en">
      <body>
        {children}
        <RegisterServiceWorker />
      </body>
    </html>
  );
}
