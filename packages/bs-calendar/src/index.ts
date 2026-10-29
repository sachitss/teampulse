// @teampulse/bs-calendar — Bikram Sambat (BS) calendar utilities.
//
// Design rules (from the TeamPulse build prompt):
//  * BS is the primary calendar for payroll months, leave years and holidays.
//  * Month lengths come from a year-specific table (src/data.ts). They are never
//    computed with a formula, because BS month lengths vary from year to year.
//  * Years after LAST_VERIFIED_BS_YEAR are provisional projections. Every result
//    that touches one says so (`provisional: true`), so payroll can warn.
//  * All AD dates are plain 'YYYY-MM-DD' strings and all arithmetic is done in
//    whole UTC days, so the server's own time zone can never shift a date.
//  * "Today" for PEACE is computed in Asia/Kathmandu (UTC+05:45).

import {
  BS_EPOCH_AD,
  FIRST_BS_YEAR,
  LAST_BS_YEAR,
  LAST_VERIFIED_BS_YEAR,
  MONTH_TABLE,
  type YearStatus,
} from './data.ts';

export { FIRST_BS_YEAR, LAST_BS_YEAR, LAST_VERIFIED_BS_YEAR, type YearStatus };

export interface BsDate {
  year: number;
  /** 1 = Baisakh … 12 = Chaitra */
  month: number;
  day: number;
}

export const MONTHS_EN = [
  'Baisakh', 'Jestha', 'Asar', 'Shrawan', 'Bhadra', 'Ashwin',
  'Kartik', 'Mangsir', 'Poush', 'Magh', 'Falgun', 'Chaitra',
] as const;

export const MONTHS_NE = [
  'बैशाख', 'जेठ', 'असार', 'साउन', 'भदौ', 'असोज',
  'कार्तिक', 'मंसिर', 'पुष', 'माघ', 'फागुन', 'चैत',
] as const;

/** Shrawan is month 4: the Nepali fiscal year runs 1 Shrawan – last day of Asar. */
export const FISCAL_YEAR_START_MONTH = 4;

/** Kathmandu is UTC+05:45 all year (no daylight saving). */
export const KATHMANDU_OFFSET_MINUTES = 5 * 60 + 45;

const MS_PER_DAY = 86_400_000;

export class BsRangeError extends RangeError {}

// ---------------------------------------------------------------------------
// Runtime overrides
//
// The database table bs_calendar_months is the runtime source of truth: when the
// official calendar for a provisional year is published, HR updates it there.
// Server code loads that table once and calls setMonthTableOverrides() so this
// library and SQL always agree.
// ---------------------------------------------------------------------------

let overrides: Record<number, { status: YearStatus; days: readonly number[] }> = {};

export function setMonthTableOverrides(
  table: Record<number, { status: YearStatus; days: readonly number[] }>,
): void {
  for (const [y, row] of Object.entries(table)) {
    if (row.days.length !== 12 || row.days.some((d) => d < 29 || d > 32 || !Number.isInteger(d))) {
      throw new BsRangeError(`Invalid month lengths for BS ${y}`);
    }
  }
  overrides = { ...table };
  rebuildYearStarts();
}

function yearRow(year: number) {
  const row = overrides[year] ?? MONTH_TABLE[year];
  if (!row) throw new BsRangeError(`BS year ${year} is outside the supported range ${FIRST_BS_YEAR}–${LAST_BS_YEAR}`);
  return row;
}

// Day number (days since BS epoch) of 1 Baisakh of each year, rebuilt on override.
let yearStartDay: Map<number, number> = new Map();
function rebuildYearStarts(): void {
  yearStartDay = new Map();
  let acc = 0;
  for (let y = FIRST_BS_YEAR; y <= LAST_BS_YEAR; y++) {
    yearStartDay.set(y, acc);
    acc += yearRow(y).days.reduce((s, d) => s + d, 0);
  }
  yearStartDay.set(LAST_BS_YEAR + 1, acc); // sentinel: one past the last day
}
rebuildYearStarts();

// ---------------------------------------------------------------------------
// Basic queries
// ---------------------------------------------------------------------------

export function yearStatus(year: number): YearStatus {
  return yearRow(year).status;
}

export function isProvisional(year: number): boolean {
  return yearStatus(year) === 'provisional';
}

export function daysInMonth(year: number, month: number): number {
  if (!Number.isInteger(month) || month < 1 || month > 12) throw new BsRangeError(`Invalid BS month ${month}`);
  return yearRow(year).days[month - 1];
}

export function daysInYear(year: number): number {
  return yearRow(year).days.reduce((s, d) => s + d, 0);
}

export function isValidBs(d: BsDate): boolean {
  try {
    return Number.isInteger(d.day) && d.day >= 1 && d.day <= daysInMonth(d.year, d.month);
  } catch {
    return false;
  }
}

function assertValid(d: BsDate): void {
  if (!isValidBs(d)) throw new BsRangeError(`Invalid BS date ${formatBs(d)}`);
}

// ---------------------------------------------------------------------------
// AD helpers (whole UTC days only)
// ---------------------------------------------------------------------------

const EPOCH_UTC_DAY = adToUtcDay(BS_EPOCH_AD);

/** 'YYYY-MM-DD' → whole days since 1970-01-01 (UTC). */
function adToUtcDay(ad: string): number {
  const m = /^(\d{4})-(\d{2})-(\d{2})$/.exec(ad);
  if (!m) throw new BsRangeError(`AD date must be 'YYYY-MM-DD', got '${ad}'`);
  const [y, mo, d] = [Number(m[1]), Number(m[2]), Number(m[3])];
  const ms = Date.UTC(y, mo - 1, d);
  const back = new Date(ms);
  if (back.getUTCFullYear() !== y || back.getUTCMonth() !== mo - 1 || back.getUTCDate() !== d) {
    throw new BsRangeError(`Invalid AD date '${ad}'`);
  }
  return Math.round(ms / MS_PER_DAY);
}

function utcDayToAd(day: number): string {
  return new Date(day * MS_PER_DAY).toISOString().slice(0, 10);
}

/** Add n days to an AD date. */
export function addDaysAd(ad: string, n: number): string {
  return utcDayToAd(adToUtcDay(ad) + n);
}

// ---------------------------------------------------------------------------
// Conversion
// ---------------------------------------------------------------------------

/** Days since 1 Baisakh 2000 (0-based). */
function bsToDayNumber(d: BsDate): number {
  assertValid(d);
  let n = yearStartDay.get(d.year)!;
  for (let m = 1; m < d.month; m++) n += daysInMonth(d.year, m);
  return n + d.day - 1;
}

function dayNumberToBs(n: number): BsDate {
  if (n < 0 || n >= yearStartDay.get(LAST_BS_YEAR + 1)!) {
    throw new BsRangeError(`Date is outside the supported BS range ${FIRST_BS_YEAR}–${LAST_BS_YEAR}`);
  }
  // Binary search for the year.
  let lo = FIRST_BS_YEAR, hi = LAST_BS_YEAR;
  while (lo < hi) {
    const mid = (lo + hi + 1) >> 1;
    if (yearStartDay.get(mid)! <= n) lo = mid; else hi = mid - 1;
  }
  const year = lo;
  let rest = n - yearStartDay.get(year)!;
  for (let month = 1; month <= 12; month++) {
    const len = daysInMonth(year, month);
    if (rest < len) return { year, month, day: rest + 1 };
    rest -= len;
  }
  throw new Error('unreachable');
}

/** BS → AD ('YYYY-MM-DD'). */
export function bsToAd(d: BsDate): string {
  return utcDayToAd(EPOCH_UTC_DAY + bsToDayNumber(d));
}

/** AD ('YYYY-MM-DD') → BS. */
export function adToBs(ad: string): BsDate {
  return dayNumberToBs(adToUtcDay(ad) - EPOCH_UTC_DAY);
}

/** Add n days to a BS date. */
export function addDaysBs(d: BsDate, n: number): BsDate {
  return dayNumberToBs(bsToDayNumber(d) + n);
}

/** Whole days from a to b (b − a). */
export function diffDaysBs(a: BsDate, b: BsDate): number {
  return bsToDayNumber(b) - bsToDayNumber(a);
}

export function compareBs(a: BsDate, b: BsDate): number {
  return a.year - b.year || a.month - b.month || a.day - b.day;
}

// ---------------------------------------------------------------------------
// Kathmandu "today"
// ---------------------------------------------------------------------------

/** The AD calendar date in Kathmandu at the given instant (default: now). */
export function kathmanduAdDate(instant: Date = new Date()): string {
  const shifted = instant.getTime() + KATHMANDU_OFFSET_MINUTES * 60_000;
  return new Date(shifted).toISOString().slice(0, 10);
}

/** The BS date in Kathmandu at the given instant (default: now). */
export function todayBs(instant: Date = new Date()): BsDate {
  return adToBs(kathmanduAdDate(instant));
}

/**
 * The UTC instant at which a Kathmandu calendar day begins.
 * e.g. 2083-07-12 BS (= 2026-10-29 AD) starts at 2026-10-28T18:15:00.000Z.
 * Use this for day boundaries in SQL and reports, never local midnight on the server.
 */
export function kathmanduDayStartUtc(ad: string): string {
  const ms = adToUtcDay(ad) * MS_PER_DAY - KATHMANDU_OFFSET_MINUTES * 60_000;
  return new Date(ms).toISOString();
}

// ---------------------------------------------------------------------------
// Months and fiscal years
// ---------------------------------------------------------------------------

export interface BsMonthRange {
  year: number;
  month: number;
  days: number;
  startAd: string;
  endAd: string;
  provisional: boolean;
}

/** AD start and end of a BS month — the unit of a payroll period. */
export function monthRange(year: number, month: number): BsMonthRange {
  const days = daysInMonth(year, month);
  const startAd = bsToAd({ year, month, day: 1 });
  return { year, month, days, startAd, endAd: addDaysAd(startAd, days - 1), provisional: isProvisional(year) };
}

/** The BS year in which a fiscal year starts: 1 Shrawan 2083 → FY "2083/84" → 2083. */
export function fiscalYearStartYear(d: BsDate): number {
  return d.month >= FISCAL_YEAR_START_MONTH ? d.year : d.year - 1;
}

/** "2083/84" for any date between 1 Shrawan 2083 and the last day of Asar 2084. */
export function fiscalYearLabel(d: BsDate): string {
  const y = fiscalYearStartYear(d);
  return `${y}/${String((y + 1) % 100).padStart(2, '0')}`;
}

export function parseFiscalYear(label: string): number {
  const m = /^(\d{4})\/(\d{2})$/.exec(label);
  if (!m || (Number(m[1]) + 1) % 100 !== Number(m[2])) throw new BsRangeError(`Invalid fiscal year '${label}'`);
  return Number(m[1]);
}

export interface FiscalYearRange {
  label: string;
  startBs: BsDate;
  endBs: BsDate;
  startAd: string;
  endAd: string;
  /** The 12 payroll months in order, Shrawan … Asar. */
  months: BsMonthRange[];
  provisional: boolean;
}

export function fiscalYearRange(label: string): FiscalYearRange {
  const y = parseFiscalYear(label);
  const months: BsMonthRange[] = [];
  for (let i = 0; i < 12; i++) {
    const m = ((FISCAL_YEAR_START_MONTH - 1 + i) % 12) + 1;
    months.push(monthRange(m >= FISCAL_YEAR_START_MONTH ? y : y + 1, m));
  }
  const startBs = { year: y, month: FISCAL_YEAR_START_MONTH, day: 1 };
  const endBs = { year: y + 1, month: 3, day: daysInMonth(y + 1, 3) };
  return {
    label,
    startBs,
    endBs,
    startAd: months[0].startAd,
    endAd: months[11].endAd,
    months,
    provisional: months.some((m) => m.provisional),
  };
}

// ---------------------------------------------------------------------------
// Formatting
// ---------------------------------------------------------------------------

const DEVANAGARI_DIGITS = '०१२३४५६७८९';

export function toDevanagariDigits(s: string | number): string {
  return String(s).replace(/[0-9]/g, (c) => DEVANAGARI_DIGITS[Number(c)]);
}

/** ISO-like BS string: '2083-07-12'. */
export function formatBs(d: BsDate): string {
  return `${d.year}-${String(d.month).padStart(2, '0')}-${String(d.day).padStart(2, '0')}`;
}

export function parseBs(s: string): BsDate {
  const m = /^(\d{4})-(\d{1,2})-(\d{1,2})$/.exec(s.trim());
  if (!m) throw new BsRangeError(`BS date must be 'YYYY-MM-DD', got '${s}'`);
  const d = { year: Number(m[1]), month: Number(m[2]), day: Number(m[3]) };
  assertValid(d);
  return d;
}

/** '12 Kartik 2083' or, with lang 'ne', '१२ कार्तिक २०८३'. */
export function formatBsLong(d: BsDate, lang: 'en' | 'ne' = 'en'): string {
  assertValid(d);
  if (lang === 'ne') return `${toDevanagariDigits(d.day)} ${MONTHS_NE[d.month - 1]} ${toDevanagariDigits(d.year)}`;
  return `${d.day} ${MONTHS_EN[d.month - 1]} ${d.year}`;
}
