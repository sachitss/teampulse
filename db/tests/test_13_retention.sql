-- Retention periods (PEACE, decided 2026-11-02): screenshots 30 days, other activity 12 months,
-- payroll/HR 7 years. Capture stays minimal — application name and website domain only, so no
-- window-title / full-URL / page-content columns exist on the evidence tables.
begin;
select tst.ok((select screenshot_retention_days = 30 and activity_retention_days = 365 and hr_retention_years = 7
               from org_settings),
              'retention is 30 days / 12 months / 7 years');

select tst.ok(not exists (select 1 from information_schema.columns
                          where table_schema = 'public'
                            and table_name in ('app_events', 'screenshots', 'web_events')
                            and column_name in ('window_title', 'url', 'page_title')),
              'evidence tables carry no window-title, full-URL or page-content columns');
rollback;
