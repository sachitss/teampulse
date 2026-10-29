-- =============================================================================
-- 0010 A timesheet month can only be locked after it has ended (Kathmandu date).
-- Locking the current month would stop everyone recording time for the rest of it.
-- =============================================================================
create or replace function app.guard_period_unlock() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if old.status = 'locked' and new.status <> 'locked' and auth.uid() is not null and not app.is_admin() then
    raise exception 'Only an admin can unlock a locked timesheet period' using errcode = '42501';
  end if;
  if new.status = 'locked' and old.status <> 'locked' then
    if new.end_ad >= app.kathmandu_date(now()) then
      raise exception 'A month can only be locked after it has ended' using errcode = '23514';
    end if;
    new.locked_at := now();
  end if;
  return new;
end $$;
