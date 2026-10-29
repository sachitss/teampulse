'use client';
import Link from 'next/link';
import { usePathname } from 'next/navigation';

export interface NavItem { href: string; label: string; icon: string }

export function TopNav({ items }: { items: NavItem[] }) {
  const path = usePathname();
  return (
    <nav aria-label="Main">
      {items.map((i) => (
        <Link key={i.href} href={i.href} aria-current={path.startsWith(i.href) ? 'page' : undefined}>{i.label}</Link>
      ))}
    </nav>
  );
}

export function TabBar({ items }: { items: NavItem[] }) {
  const path = usePathname();
  return (
    <nav className="tabbar" aria-label="Main">
      {items.slice(0, 5).map((i) => (
        <Link key={i.href} href={i.href} aria-current={path.startsWith(i.href) ? 'page' : undefined}>
          <span className="ico" aria-hidden>{i.icon}</span>{i.label}
        </Link>
      ))}
    </nav>
  );
}
