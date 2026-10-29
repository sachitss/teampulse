// Display helpers. Everything shown to people is in Kathmandu time, with BS dates first.
import { adToBs, formatBsLong, kathmanduAdDate } from '@teampulse/bs-calendar';

export const TZ = 'Asia/Kathmandu';

export function fmtTime(iso: string | Date): string {
  return new Intl.DateTimeFormat('en-GB', { timeZone: TZ, hour: '2-digit', minute: '2-digit' }).format(new Date(iso));
}

export function fmtAdShort(ad: string): string {
  return new Intl.DateTimeFormat('en-GB', { timeZone: 'UTC', day: 'numeric', month: 'short', year: 'numeric' }).format(new Date(`${ad}T00:00:00Z`));
}

/** e.g. "12 Kartik 2083 (29 Oct 2026)" for an instant, in Kathmandu. */
export function fmtDayOf(iso: string | Date): string {
  const ad = kathmanduAdDate(new Date(iso));
  return `${formatBsLong(adToBs(ad))} (${fmtAdShort(ad)})`;
}

export function fmtDateTime(iso: string | Date): string {
  return `${fmtDayOf(iso)} ${fmtTime(iso)}`;
}

export function minutesHm(minutes: number): string {
  const h = Math.floor(minutes / 60), m = Math.round(minutes % 60);
  return `${h}h ${String(m).padStart(2, '0')}m`;
}

export const WEEKDAY = ['', 'Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];

export function npr(paisa: number | bigint | string | null | undefined): string {
  if (paisa == null) return '—';
  const n = Number(paisa) / 100;
  return 'NPR ' + new Intl.NumberFormat('en-IN', { minimumFractionDigits: 2, maximumFractionDigits: 2 }).format(n);
}
