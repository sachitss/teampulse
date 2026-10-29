// Monthly timesheet by BS month, with Kathmandu day boundaries.
import type { Db } from './db.ts';
import { monthRange, adToBs, formatBs, MONTHS_EN, type BsMonthRange } from '@teampulse/bs-calendar';

export interface DayRow {
  ad: string;
  bs: string;
  bsDay: number;
  weekday: number;         // ISO 1 = Mon … 7 = Sun
  holiday: boolean;
  onLeave: boolean;
  minutes: number;         // approved + automatic time
  pendingMinutes: number;  // manual time awaiting approval
}

export interface Period {
  id: string | null;
  status: 'open' | 'submitted' | 'approved' | 'locked';
  submitted_at: string | null;
  approved_at: string | null;
}

export interface MonthSheet {
  userId: string;
  range: BsMonthRange;
  label: string;
  days: DayRow[];
  totalMinutes: number;
  pendingMinutes: number;
  period: Period;
}

export async function monthSheet(db: Db, userId: string, bsYear: number, bsMonth: number): Promise<MonthSheet> {
  const range = monthRange(bsYear, bsMonth);
  const rows = await db.query<{ ad: string; weekday: number; holiday: boolean; on_leave: boolean; minutes: number; pending: number }>(`
    with days as (
      select d::date as ad, app.kathmandu_day_start(d::date) as s, app.kathmandu_day_start(d::date + 1) as e
        from generate_series($2::date, $3::date, interval '1 day') d
    )
    select days.ad::text as ad, extract(isodow from days.ad)::int as weekday,
           app.is_holiday_for($1, days.ad) as holiday,
           exists (select 1 from leave_requests r where r.user_id = $1 and r.status = 'approved'
                     and days.ad between r.start_ad and r.end_ad) as on_leave,
           coalesce(round(sum(extract(epoch from (least(coalesce(t.ended_at, now()), days.e) - greatest(t.started_at, days.s))) / 60)
                          filter (where t.approval = 'approved')), 0)::int as minutes,
           coalesce(round(sum(extract(epoch from (least(coalesce(t.ended_at, now()), days.e) - greatest(t.started_at, days.s))) / 60)
                          filter (where t.approval = 'pending')), 0)::int as pending
      from days
      left join time_entries t on t.user_id = $1 and t.started_at < days.e and coalesce(t.ended_at, now()) > days.s
     group by days.ad, days.s, days.e
     order by days.ad`, [userId, range.startAd, range.endAd]);
  const period = await db.one<Period>(`
    select id, status, submitted_at, approved_at from timesheet_periods
     where user_id = $1 and bs_year = $2 and bs_month = $3`, [userId, bsYear, bsMonth]);
  const days: DayRow[] = rows.map((r) => {
    const bs = adToBs(r.ad);
    return { ad: r.ad, bs: formatBs(bs), bsDay: bs.day, weekday: r.weekday, holiday: r.holiday, onLeave: r.on_leave,
             minutes: r.minutes, pendingMinutes: r.pending };
  });
  return {
    userId, range, label: `${MONTHS_EN[bsMonth - 1]} ${bsYear}`, days,
    totalMinutes: days.reduce((s, d) => s + d.minutes, 0),
    pendingMinutes: days.reduce((s, d) => s + d.pendingMinutes, 0),
    period: period ?? { id: null, status: 'open', submitted_at: null, approved_at: null },
  };
}

/** The employee submits their month (creates the period row if needed). */
export async function submitMonth(db: Db, bsYear: number, bsMonth: number): Promise<void> {
  await db.query(`insert into timesheet_periods (user_id, bs_year, bs_month) values (auth.uid(), $1, $2)
                  on conflict (user_id, bs_year, bs_month) do nothing`, [bsYear, bsMonth]);
  const r = await db.query(`update timesheet_periods set status = 'submitted'
                             where user_id = auth.uid() and bs_year = $1 and bs_month = $2 and status = 'open' returning id`, [bsYear, bsMonth]);
  if (r.length === 0) throw new Error('This month has already been submitted.');
}

export function hm(minutes: number): string {
  const h = Math.floor(minutes / 60), m = minutes % 60;
  return `${h}:${String(m).padStart(2, '0')}`;
}
