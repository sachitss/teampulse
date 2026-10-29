import Link from 'next/link';
import { requireMe, isManagerOrAbove, isHr, isAdmin } from '@/lib/me';
import { TopNav, TabBar, type NavItem } from '@/components/nav';

export default async function AppLayout({ children }: { children: React.ReactNode }) {
  const me = await requireMe();
  const items: NavItem[] = [
    { href: '/today', label: 'Today', icon: '⏱' },
    { href: '/timesheet', label: 'Timesheet', icon: '🗓' },
  ];
  if (isManagerOrAbove(me)) items.push({ href: '/approvals', label: 'Approvals', icon: '✔' });
  if (isManagerOrAbove(me)) items.push({ href: '/projects', label: 'Projects', icon: '📁' });
  if (isHr(me)) items.push({ href: '/people', label: 'People', icon: '👥' });
  if (isAdmin(me)) items.push({ href: '/settings', label: 'Settings', icon: '⚙' });

  return (
    <>
      <header className="topbar">
        <Link href="/today" className="brand"><img src="/icons/icon-192.png" alt="" />TeamPulse</Link>
        <TopNav items={items} />
        <div className="who">
          <span className="name">{me.fullName}</span>
          <form action="/sign-out" method="post" style={{ display: 'inline' }}><button>Sign out</button></form>
        </div>
      </header>
      <main>
        {me.needsMfa && (
          <p className="notice warn">
            You signed in without two-factor, so your {me.role === 'admin' ? 'admin' : 'HR'} rights are switched off for this session.{' '}
            {me.session.via === 'supabase' ? <Link href="/mfa">Verify with your authenticator app</Link> : 'Sign in again with 2FA.'}
          </p>
        )}
        {children}
      </main>
      <TabBar items={items} />
    </>
  );
}
