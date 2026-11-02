-- =============================================================================
-- Screenshot retention raised from 14 to 30 days (PEACE, decided 2026-11-02).
--   * Other activity stays at 12 months (activity_retention_days default 365).
--   * Payroll/HR records stay at 7 years (hr_retention_years default 7).
--   * No change to WHAT is captured: application name and website domain only —
--     no window titles, no full URLs, no page content. Recording still requires
--     the published notice plus each employee's consent, exactly as before.
-- =============================================================================

alter table public.org_settings alter column screenshot_retention_days set default 30;
update public.org_settings set screenshot_retention_days = 30 where screenshot_retention_days = 14;
