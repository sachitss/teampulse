-- SQL calendar functions agree with the TypeScript library's verified anchors.
begin;
select tst.ok(app.ad_to_bs('1943-04-14') = '2000-01-01', 'epoch');
select tst.ok(app.ad_to_bs('2026-04-14') = '2083-01-01', 'New Year 2083');
select tst.ok(app.ad_to_bs('2026-07-17') = '2083-04-01', '1 Shrawan 2083');
select tst.ok(app.ad_to_bs('2026-10-29') = '2083-07-12', '29 Oct 2026');
select tst.ok(app.bs_to_ad('2083-07-12') = '2026-10-29', 'reverse');
select tst.ok(app.bs_to_ad('2084-03-32') = '2027-07-16', 'last day of FY 2083/84 (32-day Asar)');
select tst.fails($$select app.bs_to_ad('2083-07-31')$$, 'invalid bs date');   -- Kartik 2083 has 30 days
select tst.fails($$select app.bs_to_ad('2083-13-01')$$, 'invalid bs date');
select tst.fails($$select app.ad_to_bs('1900-01-01')$$, 'outside');
select tst.ok(app.fiscal_year_of('2026-07-16') = '2082/83', 'FY before Shrawan');
select tst.ok(app.fiscal_year_of('2026-07-17') = '2083/84', 'FY from Shrawan');
select tst.ok(app.is_provisional_date('2027-04-14'), '2084 provisional');
select tst.ok(not app.is_provisional_date('2027-04-13'), '2083 verified');

-- Kathmandu day boundaries (UTC+05:45).
select tst.ok(app.kathmandu_day_start('2026-10-29') = '2026-10-28 18:15:00+00', 'day starts 18:15 UTC');
select tst.ok(app.kathmandu_date('2026-10-28 18:14:59+00') = '2026-10-28', 'one second before');
select tst.ok(app.kathmandu_date('2026-10-28 18:15:00+00') = '2026-10-29', 'at boundary');

-- Table integrity: months are contiguous with no gaps or overlaps, 12 per year.
select tst.ok(not exists (
  select 1 from (select ad_start, days, lead(ad_start) over (order by ad_start) as next_start from bs_calendar_months) m
   where next_start is not null and ad_start + days <> next_start), 'calendar months are contiguous');
select tst.ok(not exists (select bs_year from bs_calendar_months group by bs_year having count(*) <> 12), '12 months per year');
select tst.ok((select count(*) from bs_calendar_months where status = 'verified' and bs_year > 2083) = 0, 'only up to 2083 verified');
rollback;
