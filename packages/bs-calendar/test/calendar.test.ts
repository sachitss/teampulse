import { test } from 'node:test';
import assert from 'node:assert/strict';
import { createRequire } from 'node:module';
import * as cal from '../src/index.ts';

const require = createRequire(import.meta.url);
const libB = require('bikram-sambat');
const { default: NepaliDate } = require('nepali-date-converter');

// ---------------------------------------------------------------------------
// Cross-checks against two independent libraries
// ---------------------------------------------------------------------------

test('every day of verified years 2000–2083 matches BOTH reference libraries', () => {
  let ad = '1943-04-14';
  let checked = 0;
  for (;;) {
    const ours = cal.adToBs(ad);
    if (ours.year > cal.LAST_VERIFIED_BS_YEAR) break;
    const b = libB.toBik(ad);
    assert.deepEqual(ours, { year: b.year, month: b.month, day: b.day }, `bikram-sambat mismatch on ${ad}`);
    // nepali-date-converter uses 0-based months
    // nepali-date-converter reads the *local* calendar date, so skip days that do
    // not exist in the test machine's zone (e.g. Kiribati skipped 1994-12-31).
    const [yy, mm, dd] = ad.split('-').map(Number);
    const local = new Date(yy, mm - 1, dd, 12);
    if (local.getDate() === dd) {
      const a = new NepaliDate(local).getBS();
      assert.deepEqual(ours, { year: a.year, month: a.month + 1, day: a.date }, `nepali-date-converter mismatch on ${ad}`);
    }
    assert.equal(cal.bsToAd(ours), ad, `round trip failed on ${ad}`);
    ad = cal.addDaysAd(ad, 1);
    checked++;
  }
  assert.ok(checked > 30_000, `expected >30k days, checked ${checked}`);
});

test('provisional years 2084–2090 match bikram-sambat (agreed with two public calendars for 2084)', () => {
  let ad = cal.bsToAd({ year: 2084, month: 1, day: 1 });
  for (;;) {
    let ours;
    try { ours = cal.adToBs(ad); } catch { break; }
    const b = libB.toBik(ad);
    assert.deepEqual(ours, { year: b.year, month: b.month, day: b.day }, `mismatch on ${ad}`);
    ad = cal.addDaysAd(ad, 1);
  }
});

// ---------------------------------------------------------------------------
// Known anchors
// ---------------------------------------------------------------------------

test('known anchor dates', () => {
  assert.equal(cal.bsToAd({ year: 2000, month: 1, day: 1 }), '1943-04-14');
  assert.equal(cal.bsToAd({ year: 2083, month: 1, day: 1 }), '2026-04-14'); // Nepali New Year 2083
  assert.equal(cal.bsToAd({ year: 2083, month: 4, day: 1 }), '2026-07-17'); // 1 Shrawan 2083 = start of FY 2083/84
  assert.equal(cal.bsToAd({ year: 2084, month: 1, day: 1 }), '2027-04-14'); // Nepali New Year 2084
  assert.deepEqual(cal.adToBs('2026-10-29'), { year: 2083, month: 7, day: 12 });
});

test('the 2084 provisional table matches the public calendars checked on 2026-10-29', () => {
  assert.deepEqual(
    Array.from({ length: 12 }, (_, i) => cal.daysInMonth(2084, i + 1)),
    [31, 31, 32, 31, 31, 30, 30, 30, 29, 30, 30, 30],
  );
  assert.equal(cal.isProvisional(2084), true);
  assert.equal(cal.isProvisional(2083), false);
});

// ---------------------------------------------------------------------------
// Kathmandu time (UTC+05:45)
// ---------------------------------------------------------------------------

test('day boundary in Kathmandu is 18:15 UTC, not midnight', () => {
  assert.deepEqual(cal.todayBs(new Date('2026-10-28T18:14:59.999Z')), { year: 2083, month: 7, day: 11 });
  assert.deepEqual(cal.todayBs(new Date('2026-10-28T18:15:00.000Z')), { year: 2083, month: 7, day: 12 });
  assert.equal(cal.kathmanduDayStartUtc('2026-10-29'), '2026-10-28T18:15:00.000Z');
});

test('server time zone cannot shift results', () => {
  // All arithmetic is in UTC days; these must hold whatever TZ the process runs in.
  assert.equal(cal.addDaysAd('2026-12-31', 1), '2027-01-01');
  assert.equal(cal.addDaysAd('2028-02-28', 1), '2028-02-29'); // leap day
  assert.equal(cal.kathmanduAdDate(new Date('2026-12-31T18:15:00Z')), '2027-01-01');
});

// ---------------------------------------------------------------------------
// Fiscal years and payroll months
// ---------------------------------------------------------------------------

test('fiscal year 2083/84 runs 1 Shrawan 2083 to end of Asar 2084', () => {
  const fy = cal.fiscalYearRange('2083/84');
  assert.equal(fy.startAd, '2026-07-17');
  assert.equal(fy.endAd, '2027-07-16');
  assert.equal(fy.months.length, 12);
  assert.deepEqual(fy.months.map((m) => m.month), [4, 5, 6, 7, 8, 9, 10, 11, 12, 1, 2, 3]);
  assert.equal(fy.months[0].year, 2083);
  assert.equal(fy.months[11].year, 2084);
  // Baisakh–Asar 2084 fall inside FY 2083/84 and are provisional today.
  assert.equal(fy.provisional, true);
  assert.deepEqual(fy.endBs, { year: 2084, month: 3, day: 32 });
  // Months tile the year with no gaps or overlaps.
  for (let i = 1; i < 12; i++) assert.equal(fy.months[i].startAd, cal.addDaysAd(fy.months[i - 1].endAd, 1));
  const total = fy.months.reduce((s, m) => s + m.days, 0);
  assert.equal(total, 365);
});

test('fiscal year 2082/83 is fully verified', () => {
  const fy = cal.fiscalYearRange('2082/83');
  assert.equal(fy.provisional, false);
  assert.equal(fy.startAd, cal.bsToAd({ year: 2082, month: 4, day: 1 }));
  assert.equal(cal.addDaysAd(fy.endAd, 1), '2026-07-17');
});

test('fiscal year label of a date', () => {
  assert.equal(cal.fiscalYearLabel({ year: 2083, month: 3, day: 32 }), '2082/83');
  assert.equal(cal.fiscalYearLabel({ year: 2083, month: 4, day: 1 }), '2083/84');
  assert.equal(cal.fiscalYearLabel({ year: 2084, month: 1, day: 1 }), '2083/84');
  assert.equal(cal.fiscalYearLabel({ year: 2099 - 1, month: 4, day: 1 }), '2098/99');
  assert.throws(() => cal.parseFiscalYear('2083/85'));
});

test('payroll month Kartik 2083', () => {
  const m = cal.monthRange(2083, 7);
  // 12 Kartik 2083 = 29 Oct 2026 (anchor test above), so 1 Kartik = 18 Oct.
  assert.deepEqual(m, { year: 2083, month: 7, days: 30, startAd: '2026-10-18', endAd: '2026-11-16', provisional: false });
});

// ---------------------------------------------------------------------------
// Validation, arithmetic, formatting
// ---------------------------------------------------------------------------

test('invalid dates are rejected, never silently rolled over', () => {
  assert.throws(() => cal.bsToAd({ year: 2083, month: 7, day: 31 }), cal.BsRangeError); // Kartik 2083 has 30 days
  assert.throws(() => cal.bsToAd({ year: 2083, month: 13, day: 1 }), cal.BsRangeError);
  assert.throws(() => cal.bsToAd({ year: 1999, month: 1, day: 1 }), cal.BsRangeError);
  assert.throws(() => cal.adToBs('2026-02-30'), cal.BsRangeError);
  assert.throws(() => cal.adToBs('1943-04-13'), cal.BsRangeError);
  assert.throws(() => cal.parseBs('2083-7-31'), cal.BsRangeError);
  assert.equal(cal.isValidBs({ year: 2084, month: 3, day: 32 }), true);
});

test('BS arithmetic', () => {
  assert.deepEqual(cal.addDaysBs({ year: 2083, month: 12, day: 30 }, 1), { year: 2084, month: 1, day: 1 });
  assert.equal(cal.diffDaysBs({ year: 2083, month: 4, day: 1 }, { year: 2084, month: 4, day: 1 }), 365);
  assert.ok(cal.compareBs({ year: 2083, month: 4, day: 1 }, { year: 2083, month: 3, day: 32 }) > 0);
});

test('formatting in English and Nepali', () => {
  const d = { year: 2083, month: 7, day: 12 };
  assert.equal(cal.formatBs(d), '2083-07-12');
  assert.deepEqual(cal.parseBs('2083-07-12'), d);
  assert.equal(cal.formatBsLong(d), '12 Kartik 2083');
  assert.equal(cal.formatBsLong(d, 'ne'), '१२ कार्तिक २०८३');
});

// ---------------------------------------------------------------------------
// Runtime overrides (HR replaces a provisional year with the official calendar)
// ---------------------------------------------------------------------------

test('overrides replace a provisional year and are validated', () => {
  const official2084 = { status: 'verified' as const, days: [31, 32, 31, 32, 31, 30, 30, 30, 29, 29, 30, 31] };
  try {
    cal.setMonthTableOverrides({ 2084: official2084 });
    assert.equal(cal.isProvisional(2084), false);
    assert.equal(cal.daysInMonth(2084, 2), 32);
    // Later dates shift consistently; earlier dates are untouched.
    assert.equal(cal.bsToAd({ year: 2083, month: 4, day: 1 }), '2026-07-17');
    assert.equal(cal.bsToAd({ year: 2085, month: 1, day: 1 }), cal.addDaysAd('2027-04-14', 366));
    assert.throws(() => cal.setMonthTableOverrides({ 2084: { status: 'verified', days: [31, 31] } }), cal.BsRangeError);
  } finally {
    cal.setMonthTableOverrides({});
  }
  assert.equal(cal.isProvisional(2084), true);
});
