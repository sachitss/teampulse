-- =============================================================================
-- 0007 Employee loans and salary advances, repaid through payroll
--
-- The app records and schedules loans; it does not move money. Disbursement is
-- recorded by HR after the bank transfer is made.
--   * Employee requests (or HR enters) → Admin approves (MFA, never own loan)
--     → schedule generated → HR records disbursement → loan active.
--   * Each month the payroll engine links that month's instalment to the run and
--     sets payroll_lines.loan_deduction_paisa. On payroll APPROVAL the database
--     checks the amounts match and posts the repayment to the loan ledger.
--   * Outstanding balance = sum of an append-only ledger. Never edited directly.
--   * Loans are pay data: visible to the employee, HR and admin — never managers.
-- =============================================================================

create type public.loan_status          as enum ('requested', 'approved', 'rejected', 'active', 'closed', 'written_off', 'cancelled');
create type public.loan_interest_method as enum ('none', 'flat', 'reducing');
create type public.loan_ledger_kind     as enum ('disbursement', 'interest', 'repayment_payroll', 'repayment_manual', 'adjustment', 'write_off');
create type public.instalment_status    as enum ('planned', 'deducted', 'paid_manually', 'deferred', 'waived');

-- Company loan policy (single row). PEACE's own policy, not law.
create table public.loan_policy (
  id                         boolean primary key default true check (id),
  -- Total loan deductions in a month may not exceed this share of that month's gross.
  max_deduction_bp_of_gross  int not null default 5000 check (max_deduction_bp_of_gross between 0 and 10000),
  max_active_loans           smallint not null default 1 check (max_active_loans >= 1),
  -- Months of service before an employee may borrow (0 = from day one).
  min_service_months         smallint not null default 6 check (min_service_months >= 0),
  allow_during_probation     boolean not null default false,
  recover_on_exit            boolean not null default true,
  status                     public.rule_status not null default 'to_confirm',
  confirmed_by               uuid references public.profiles (id),
  confirmed_at               timestamptz,
  updated_at                 timestamptz not null default now(),
  check (status <> 'confirmed' or (confirmed_by is not null and confirmed_at is not null))
);
insert into public.loan_policy default values;

create table public.loan_types (
  id                   uuid primary key default gen_random_uuid(),
  code                 text not null unique check (code ~ '^[a-z_]+$'),
  name_en              text not null,
  name_ne              text,
  -- Cap as a fixed amount and/or as months of basic salary (whichever is lower applies).
  max_principal_paisa  bigint check (max_principal_paisa is null or max_principal_paisa > 0),
  max_months_of_basic  numeric(5,2) check (max_months_of_basic is null or max_months_of_basic > 0),
  max_instalments      smallint not null check (max_instalments between 1 and 120),
  default_interest_bp  int not null default 0 check (default_interest_bp between 0 and 5000),
  interest_method      public.loan_interest_method not null default 'none',
  active               boolean not null default true,
  check ((interest_method = 'none') = (default_interest_bp = 0))
);

create table public.employee_loans (
  id                     uuid primary key default gen_random_uuid(),
  user_id                uuid not null references public.profiles (id) on delete cascade,
  loan_type_id           uuid not null references public.loan_types (id),
  principal_paisa        bigint not null check (principal_paisa > 0),
  interest_bp            int not null default 0 check (interest_bp between 0 and 5000),   -- annual
  interest_method        public.loan_interest_method not null default 'none',
  instalments            smallint not null check (instalments between 1 and 120),
  first_bs_year          smallint not null,
  first_bs_month         smallint not null,
  purpose                text not null check (length(trim(purpose)) > 0),
  status                 public.loan_status not null default 'requested',
  requested_by           uuid references public.profiles (id),
  requested_at           timestamptz not null default now(),
  decided_by             uuid references public.profiles (id),
  decided_at             timestamptz,
  decision_note          text,
  total_repayable_paisa  bigint,                -- principal + interest, from the schedule
  disbursed_on           date,                  -- recorded by HR after the bank transfer
  disbursement_ref       text,
  closed_at              timestamptz,
  created_at             timestamptz not null default now(),
  check ((interest_method = 'none') = (interest_bp = 0)),
  check (status not in ('active', 'closed', 'written_off') or disbursed_on is not null),
  foreign key (first_bs_year, first_bs_month) references public.bs_calendar_months (bs_year, bs_month)
);
create index on public.employee_loans (user_id, status);

create table public.loan_schedule (
  id             uuid primary key default gen_random_uuid(),
  loan_id        uuid not null references public.employee_loans (id) on delete cascade,
  seq            smallint not null check (seq >= 1),
  bs_year        smallint not null,
  bs_month       smallint not null,
  principal_paisa bigint not null check (principal_paisa >= 0),
  interest_paisa bigint not null default 0 check (interest_paisa >= 0),
  due_paisa      bigint not null,
  status         public.instalment_status not null default 'planned',
  payroll_run_id uuid references public.payroll_runs (id) on delete set null,
  note           text,
  unique (loan_id, seq),
  check (due_paisa = principal_paisa + interest_paisa),
  check (status not in ('deferred', 'waived', 'paid_manually') or (note is not null and length(trim(note)) > 0)),
  foreign key (bs_year, bs_month) references public.bs_calendar_months (bs_year, bs_month)
);
create index on public.loan_schedule (bs_year, bs_month, status);
create unique index loan_schedule_one_per_month on public.loan_schedule (loan_id, bs_year, bs_month)
  where status in ('planned', 'deducted');

create table public.loan_ledger (
  id              uuid primary key default gen_random_uuid(),
  loan_id         uuid not null references public.employee_loans (id) on delete cascade,
  entry_ad        date not null default current_date,
  kind            public.loan_ledger_kind not null,
  -- Positive increases what is owed; negative reduces it.
  amount_paisa    bigint not null check (amount_paisa <> 0),
  schedule_id     uuid references public.loan_schedule (id) on delete set null,
  payroll_run_id  uuid references public.payroll_runs (id) on delete set null,
  reason          text,
  created_by      uuid references public.profiles (id),
  created_at      timestamptz not null default now(),
  check ((kind in ('disbursement', 'interest') and amount_paisa > 0)
      or (kind in ('repayment_payroll', 'repayment_manual', 'write_off') and amount_paisa < 0)
      or  kind = 'adjustment'),
  check (kind not in ('adjustment', 'write_off', 'repayment_manual') or (reason is not null and length(trim(reason)) > 0))
);
create index on public.loan_ledger (loan_id, entry_ad);
create trigger loan_ledger_append_only before update or delete on public.loan_ledger
  for each row execute function app.block_mutation();

create view public.loan_balances with (security_invoker = true) as
  select l.id as loan_id, l.user_id, l.status, l.principal_paisa, l.total_repayable_paisa,
         coalesce(sum(g.amount_paisa), 0)::bigint as outstanding_paisa,
         coalesce(sum(-g.amount_paisa) filter (where g.kind in ('repayment_payroll', 'repayment_manual')), 0)::bigint as repaid_paisa
    from public.employee_loans l
    left join public.loan_ledger g on g.loan_id = l.id
   group by l.id;

-- Payroll: loan deductions get their own column on the register and payslip.
alter table public.payroll_lines add column loan_deduction_paisa bigint not null default 0 check (loan_deduction_paisa >= 0);
alter table public.payroll_lines drop constraint payroll_lines_check;
alter table public.payroll_lines add constraint payroll_lines_net_check
  check (net_paisa = gross_paisa - ssf_employee_paisa - tds_paisa - loan_deduction_paisa - other_deductions_paisa);

-- -----------------------------------------------------------------------------
-- Schedule generation — exact to the paisa (the instalments always sum to the principal)
--   none      equal principal instalments, the last one absorbs the remainder
--   flat      total interest = principal × rate × months / 12, spread equally
--   reducing  standard EMI on the declining balance; the last instalment clears it
-- -----------------------------------------------------------------------------
create or replace function app.generate_loan_schedule(p_loan uuid) returns bigint
language plpgsql security definer set search_path = public as $$
declare
  l record; m record;
  n int; i int := 0;
  base bigint; prin bigint; intr bigint;
  total_int bigint; int_base bigint;
  r numeric; emi bigint; bal bigint;
  total bigint := 0;
begin
  select * into l from public.employee_loans where id = p_loan;
  n := l.instalments;
  delete from public.loan_schedule where loan_id = p_loan and status = 'planned';
  base := l.principal_paisa / n;
  if l.interest_method = 'flat' then
    total_int := round(l.principal_paisa * l.interest_bp / 10000.0 * n / 12.0);
    int_base  := total_int / n;
  elsif l.interest_method = 'reducing' then
    r   := l.interest_bp / 10000.0 / 12.0;
    emi := round(l.principal_paisa * r / (1 - power(1 + r, -n)));
    bal := l.principal_paisa;
  end if;

  for m in select bs_year, bs_month from public.bs_calendar_months
            where (bs_year, bs_month) >= (l.first_bs_year, l.first_bs_month)
            order by bs_year, bs_month limit n loop
    i := i + 1;
    if l.interest_method = 'reducing' then
      intr := round(bal * r);
      prin := case when i = n then bal else least(emi - intr, bal) end;
      bal  := bal - prin;
    else
      prin := case when i = n then l.principal_paisa - base * (n - 1) else base end;
      intr := case when l.interest_method = 'flat'
                   then case when i = n then total_int - int_base * (n - 1) else int_base end
                   else 0 end;
    end if;
    insert into public.loan_schedule (loan_id, seq, bs_year, bs_month, principal_paisa, interest_paisa, due_paisa)
    values (p_loan, i, m.bs_year, m.bs_month, prin, intr, prin + intr);
    total := total + prin + intr;
  end loop;

  if i < n then
    raise exception 'The BS calendar table does not reach far enough for % instalments', n using errcode = '22008';
  end if;
  if (select sum(principal_paisa) from public.loan_schedule where loan_id = p_loan) <> l.principal_paisa then
    raise exception 'Schedule does not sum to the principal' using errcode = '23514';
  end if;
  return total;
end $$;

-- The lower of the type's fixed cap and N months of the employee's current basic.
create or replace function app.loan_cap_paisa(p_user uuid, p_type uuid) returns bigint
language sql stable security definer set search_path = public as $$
  select least(
    t.max_principal_paisa,
    case when t.max_months_of_basic is null then null
         else (select round(s.basic_paisa * t.max_months_of_basic)::bigint
                 from public.salary_records s
                where s.user_id = p_user and s.effective_from_ad <= app.kathmandu_date(now())
                order by s.effective_from_ad desc limit 1) end)
  from public.loan_types t where t.id = p_type
$$;

-- -----------------------------------------------------------------------------
-- Loan lifecycle guard
-- -----------------------------------------------------------------------------
create or replace function app.guard_loan() returns trigger
language plpgsql security definer set search_path = public as $$
declare
  t record; pol record; p record; cap bigint; active_n int;
  is_system boolean := auth.uid() is null;
begin
  select * into t from public.loan_types where id = new.loan_type_id;
  select * into pol from public.loan_policy;

  if tg_op = 'INSERT' then
    if not t.active then raise exception 'Loan type % is not active', t.code using errcode = '23514'; end if;
    if new.instalments > t.max_instalments then
      raise exception '% allows at most % instalments', t.name_en, t.max_instalments using errcode = '23514';
    end if;
    cap := app.loan_cap_paisa(new.user_id, new.loan_type_id);
    if cap is not null and new.principal_paisa > cap then
      raise exception 'Amount exceeds the % limit of NPR %', t.name_en, to_char(cap / 100.0, 'FM99,99,99,990.00') using errcode = '23514';
    end if;
    if not is_system and new.user_id <> auth.uid() and not app.is_hr() then
      raise exception 'You can only request a loan for yourself' using errcode = '42501';
    end if;
    if new.status <> 'requested' and not is_system then
      raise exception 'A new loan starts as a request' using errcode = '23514';
    end if;
    new.requested_by := coalesce(auth.uid(), new.requested_by);
    return new;
  end if;

  -- Terms are frozen once a decision has been made.
  if old.status <> 'requested' and (
       new.principal_paisa is distinct from old.principal_paisa or new.interest_bp is distinct from old.interest_bp
    or new.interest_method is distinct from old.interest_method or new.instalments is distinct from old.instalments
    or new.first_bs_year is distinct from old.first_bs_year or new.first_bs_month is distinct from old.first_bs_month
    or new.user_id is distinct from old.user_id or new.loan_type_id is distinct from old.loan_type_id) then
    raise exception 'Loan terms cannot change after a decision; close it and create a new loan instead' using errcode = '42501';
  end if;

  if new.status = old.status then return new; end if;

  if new.status = 'cancelled' then
    if old.status = 'requested' then
      if not is_system and old.user_id <> auth.uid() and not app.is_hr() then
        raise exception 'Only the employee or HR can cancel a loan request' using errcode = '42501';
      end if;
    elsif old.status = 'approved' then          -- approved but never paid out
      if not is_system and not app.is_hr() then
        raise exception 'Only HR or an admin can cancel an approved loan' using errcode = '42501';
      end if;
    else
      raise exception 'Only a request or an approved, undisbursed loan can be cancelled' using errcode = '23514';
    end if;
    return new;
  end if;

  if new.status in ('approved', 'rejected') then
    if old.status <> 'requested' then raise exception 'Only a pending request can be decided' using errcode = '23514'; end if;
    if not is_system and not app.is_admin() then
      raise exception 'Only an admin can approve or reject a loan' using errcode = '42501';
    end if;
    if not is_system and old.user_id = auth.uid() then
      raise exception 'You cannot decide your own loan' using errcode = '42501';
    end if;
    new.decided_by := auth.uid(); new.decided_at := now();
    if new.status = 'approved' then
      select * into p from public.profiles where id = old.user_id;
      if not pol.allow_during_probation and p.employment_type = 'probation' then
        raise exception 'Loan policy does not allow loans during probation' using errcode = '23514';
      end if;
      if p.join_date is not null and p.join_date > (app.kathmandu_date(now()) - make_interval(months => pol.min_service_months))::date then
        raise exception 'Loan policy requires % months of service', pol.min_service_months using errcode = '23514';
      end if;
      select count(*) into active_n from public.employee_loans
       where user_id = old.user_id and id <> old.id and status in ('approved', 'active');
      if active_n >= pol.max_active_loans then
        raise exception 'Loan policy allows at most % active loan(s) per person', pol.max_active_loans using errcode = '23514';
      end if;
    end if;
    return new;
  end if;

  if new.status = 'active' then
    if old.status <> 'approved' then raise exception 'A loan becomes active only after approval' using errcode = '23514'; end if;
    if not is_system and not app.is_hr() then raise exception 'Only HR records a disbursement' using errcode = '42501'; end if;
    return new;
  end if;

  if new.status = 'written_off' then
    if old.status <> 'active' then raise exception 'Only an active loan can be written off' using errcode = '23514'; end if;
    if not is_system and not app.is_admin() then raise exception 'Only an admin can write off a loan' using errcode = '42501'; end if;
    return new;
  end if;

  if new.status = 'closed' then
    if (select outstanding_paisa from public.loan_balances where loan_id = old.id) <> 0 then
      raise exception 'A loan can only be closed when nothing is outstanding' using errcode = '23514';
    end if;
    new.closed_at := now();
    return new;
  end if;

  raise exception 'Invalid loan status change % → %', old.status, new.status using errcode = '23514';
end $$;
create trigger employee_loans_guard before insert or update on public.employee_loans
  for each row execute function app.guard_loan();

-- After approval: build the schedule. After activation: post disbursement (+ interest) to the ledger.
create or replace function app.after_loan_change() returns trigger
language plpgsql security definer set search_path = public as $$
declare total bigint; i bigint;
begin
  if new.status = 'approved' and old.status = 'requested' then
    total := app.generate_loan_schedule(new.id);
    update public.employee_loans set total_repayable_paisa = total where id = new.id;
  elsif new.status = 'active' and old.status = 'approved' then
    insert into public.loan_ledger (loan_id, entry_ad, kind, amount_paisa, reason, created_by)
    values (new.id, new.disbursed_on, 'disbursement', new.principal_paisa, new.disbursement_ref, auth.uid());
    i := coalesce(new.total_repayable_paisa, new.principal_paisa) - new.principal_paisa;
    if i > 0 then
      insert into public.loan_ledger (loan_id, entry_ad, kind, amount_paisa, reason, created_by)
      values (new.id, new.disbursed_on, 'interest', i, 'Scheduled interest', auth.uid());
    end if;
  elsif new.status = 'written_off' and old.status = 'active' then
    i := (select outstanding_paisa from public.loan_balances where loan_id = new.id);
    if i > 0 then
      insert into public.loan_ledger (loan_id, kind, amount_paisa, reason, created_by)
      values (new.id, 'write_off', -i, coalesce(new.decision_note, 'Written off by admin'), auth.uid());
    end if;
    update public.loan_schedule set status = 'waived', note = 'Loan written off' where loan_id = new.id and status = 'planned';
  elsif new.status = 'cancelled' and old.status = 'approved' then
    delete from public.loan_schedule where loan_id = new.id and status = 'planned';
  end if;
  return null;
end $$;
create trigger employee_loans_after after update on public.employee_loans
  for each row execute function app.after_loan_change();

-- Close the loan automatically when the balance reaches zero.
create or replace function app.close_paid_loan() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if (select outstanding_paisa from public.loan_balances where loan_id = new.loan_id) = 0 then
    update public.employee_loans set status = 'closed' where id = new.loan_id and status = 'active';
  elsif (select outstanding_paisa from public.loan_balances where loan_id = new.loan_id) < 0 then
    raise exception 'Repayment would make the loan balance negative' using errcode = '23514';
  end if;
  return null;
end $$;
create trigger loan_ledger_close after insert on public.loan_ledger
  for each row execute function app.close_paid_loan();

-- Deferring an instalment moves it to the first free month after the last instalment.
create or replace function app.defer_instalment() returns trigger
language plpgsql security definer set search_path = public as $$
declare nxt record; last record;
begin
  if new.status = 'deferred' and old.status = 'planned' then
    if auth.uid() is not null and not app.is_hr() then raise exception 'Only HR can defer an instalment' using errcode = '42501'; end if;
    select bs_year, bs_month, seq into last from public.loan_schedule
     where loan_id = new.loan_id order by bs_year desc, bs_month desc limit 1;
    select bs_year, bs_month into nxt from public.bs_calendar_months
     where (bs_year, bs_month) > (last.bs_year, last.bs_month) order by bs_year, bs_month limit 1;
    insert into public.loan_schedule (loan_id, seq, bs_year, bs_month, principal_paisa, interest_paisa, due_paisa, note)
    values (new.loan_id, (select max(seq) + 1 from public.loan_schedule where loan_id = new.loan_id),
            nxt.bs_year, nxt.bs_month, old.principal_paisa, old.interest_paisa, old.due_paisa,
            'Deferred from ' || old.bs_year || '-' || lpad(old.bs_month::text, 2, '0'));
  end if;
  return new;
end $$;
create trigger loan_schedule_defer before update of status on public.loan_schedule
  for each row execute function app.defer_instalment();

-- -----------------------------------------------------------------------------
-- Payroll approval: instalments linked to the run must match each line's loan
-- deduction, must respect the policy cap, and are then posted to the ledger.
-- -----------------------------------------------------------------------------
create or replace function app.post_loan_repayments() returns trigger
language plpgsql security definer set search_path = public as $$
declare x record; cap_bp int := (select max_deduction_bp_of_gross from public.loan_policy);
begin
  if not (new.status = 'approved' and old.status <> 'approved') then return null; end if;

  for x in
    select pl.user_id, pl.loan_deduction_paisa, pl.gross_paisa,
           coalesce((select sum(s.due_paisa) from public.loan_schedule s join public.employee_loans l on l.id = s.loan_id
                      where s.payroll_run_id = new.id and l.user_id = pl.user_id and s.status = 'planned'), 0) as scheduled
      from public.payroll_lines pl where pl.run_id = new.id
  loop
    if x.loan_deduction_paisa <> x.scheduled then
      raise exception 'Loan deduction for an employee (%) does not match the instalments linked to this run (%)',
        x.loan_deduction_paisa, x.scheduled using errcode = '23514';
    end if;
    if x.loan_deduction_paisa > x.gross_paisa * cap_bp / 10000 then
      raise exception 'Loan deductions exceed the policy limit of % %% of gross; defer an instalment', cap_bp / 100.0
        using errcode = '23514';
    end if;
  end loop;

  -- Instalments linked to the run but for someone without a payroll line.
  if exists (select 1 from public.loan_schedule s join public.employee_loans l on l.id = s.loan_id
              where s.payroll_run_id = new.id and s.status = 'planned'
                and not exists (select 1 from public.payroll_lines pl where pl.run_id = new.id and pl.user_id = l.user_id)) then
    raise exception 'An instalment is linked to this run for an employee with no payroll line' using errcode = '23514';
  end if;

  insert into public.loan_ledger (loan_id, entry_ad, kind, amount_paisa, schedule_id, payroll_run_id, created_by)
  select s.loan_id, new.period_end_ad, 'repayment_payroll', -s.due_paisa, s.id, new.id, auth.uid()
    from public.loan_schedule s where s.payroll_run_id = new.id and s.status = 'planned';
  update public.loan_schedule set status = 'deducted' where payroll_run_id = new.id and status = 'planned';
  return null;
end $$;
create trigger payroll_runs_post_loans after update of status on public.payroll_runs
  for each row execute function app.post_loan_repayments();

-- What would be recovered from final settlement at exit.
create or replace function app.outstanding_loans_paisa(p_user uuid) returns bigint
language sql stable security definer set search_path = public as $$
  select coalesce(sum(outstanding_paisa), 0)::bigint from public.loan_balances
   where user_id = p_user and status = 'active'
$$;

-- -----------------------------------------------------------------------------
-- Audit and access
-- -----------------------------------------------------------------------------
create trigger employee_loans_audit after insert or update or delete on public.employee_loans
  for each row execute function app.audit_row();
create trigger loan_schedule_audit after update or delete on public.loan_schedule
  for each row execute function app.audit_row();
create trigger loan_ledger_audit after insert on public.loan_ledger
  for each row execute function app.audit_row();
create trigger loan_policy_audit after update on public.loan_policy
  for each row execute function app.audit_row();
create trigger loan_types_audit after insert or update or delete on public.loan_types
  for each row execute function app.audit_row();
create trigger loan_policy_touch before update on public.loan_policy
  for each row execute function app.touch_updated_at();

create or replace function app.loan_owner(p_loan uuid) returns uuid
language sql stable security definer set search_path = public as $$
  select user_id from public.employee_loans where id = p_loan
$$;

alter table public.loan_policy    enable row level security;
alter table public.loan_types     enable row level security;
alter table public.employee_loans enable row level security;
alter table public.loan_schedule  enable row level security;
alter table public.loan_ledger    enable row level security;

-- Everyone may read the policy and loan types (they need to know the rules to apply).
create policy loan_policy_read  on public.loan_policy for select to authenticated using (true);
create policy loan_policy_write on public.loan_policy for update to authenticated using (app.is_admin()) with check (app.is_admin());
create policy loan_types_read   on public.loan_types for select to authenticated using (true);
create policy loan_types_write  on public.loan_types for all to authenticated using (app.is_hr()) with check (app.is_hr());

create policy loans_read   on public.employee_loans for select to authenticated using (app.can_see_pay(user_id));
create policy loans_insert on public.employee_loans for insert to authenticated with check (user_id = auth.uid() or app.is_hr());
create policy loans_update on public.employee_loans for update to authenticated
  using (user_id = auth.uid() or app.is_hr()) with check (user_id = auth.uid() or app.is_hr());   -- transitions guarded by trigger

create policy schedule_read  on public.loan_schedule for select to authenticated using (app.can_see_pay(app.loan_owner(loan_id)));
create policy schedule_write on public.loan_schedule for update to authenticated using (app.is_hr()) with check (app.is_hr());

create policy loan_ledger_read   on public.loan_ledger for select to authenticated using (app.can_see_pay(app.loan_owner(loan_id)));
create policy loan_ledger_insert on public.loan_ledger for insert to authenticated
  with check (app.is_hr() and kind in ('repayment_manual', 'adjustment'));

revoke execute on all functions in schema app from public, anon;
grant execute on all functions in schema app to authenticated, service_role;
