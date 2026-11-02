-- Organisation name set to its full legal name (PEACE, 2026-11-02):
-- "PEACE Biomedical & Engineering Consultancy Pvt. Ltd." The app's visible name
-- is in the web UI; org_settings.org_name is the canonical record, kept in step here.
alter table public.org_settings
  alter column org_name set default 'PEACE Biomedical & Engineering Consultancy Pvt. Ltd.';
update public.org_settings
   set org_name = 'PEACE Biomedical & Engineering Consultancy Pvt. Ltd.'
 where org_name = 'PEACE Consultancy';
