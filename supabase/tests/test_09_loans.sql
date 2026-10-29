-- Employee loans: limits, approval, exact schedules, payroll repayment, deferral, write-off, privacy.
begin;
select tst.mk_user('admin@t.test', 'admin')            as admin \gset
select tst.mk_user('hr@t.test', 'hr')                  as hr \gset
select tst.mk_user('mgr@t.test', 'manager', :'admin')  as mgr \gset
select tst.mk_user('emp@t.test', 'employee', :'mgr')   as emp \gset
select tst.mk_user('emp2@t.test', 'employee', :'mgr')  as emp2 \gset
insert into salary_records (user_id, effective_from_ad, basic_paisa, reason) values (:'emp',  '2026-07-17', 5000000, 'opening') returning id as sal \gset
insert into salary_records (user_id, effective_from_ad, basic_paisa, reason) values (:'emp2', '2026-07-17', 4000000, 'opening');
select id as advance  from loan_types where code = 'salary_advance' \gset
select id as personal from loan_types where code = 'personal_loan' \gset

-- ------------------------------------------------------------ requests and limits
select tst.claims(:'emp', false);
set local role authenticated;
-- Salary advance is capped at 1 month of basic (NPR 50,000).
select tst.fails(format($q$insert into employee_loans (user_id, loan_type_id, principal_paisa, instalments, first_bs_year, first_bs_month, purpose)
                           values (%L, %L, 6000000, 2, 2083, 8, 'Rent deposit')$q$, :'emp', :'advance'), 'exceeds');
select tst.fails(format($q$insert into employee_loans (user_id, loan_type_id, principal_paisa, instalments, first_bs_year, first_bs_month, purpose)
                           values (%L, %L, 1000000, 5, 2083, 8, 'Too many instalments')$q$, :'emp', :'advance'), 'at most 3 instalments');
-- Not for someone else.
select tst.fails(format($q$insert into employee_loans (user_id, loan_type_id, principal_paisa, instalments, first_bs_year, first_bs_month, purpose)
                           values (%L, %L, 1000000, 2, 2083, 8, 'x')$q$, :'emp2', :'advance'), 'only request a loan for yourself');
-- A valid personal loan: NPR 1,20,000 over 12 months from Mangsir 2083.
insert into employee_loans (user_id, loan_type_id, principal_paisa, instalments, first_bs_year, first_bs_month, purpose)
values (:'emp', :'personal', 12000000, 12, 2083, 8, 'Motorbike') returning id as loan \gset
select tst.fails(format('update employee_loans set status = %L where id = %L', 'approved', :'loan'), 'only an admin');
reset role;

-- Managers never see loans.
select tst.claims(:'mgr', false);
set local role authenticated;
select tst.ok(tst.n('select * from employee_loans') = 0 and tst.n('select * from loan_schedule') = 0, 'manager sees no loans');
reset role;

-- HR cannot approve.
select tst.claims(:'hr', true);
set local role authenticated;
select tst.fails(format('update employee_loans set status = %L where id = %L', 'approved', :'loan'), 'only an admin');
reset role;

-- ------------------------------------------------------------ approval builds an exact schedule
select tst.claims(:'admin', true);
set local role authenticated;
update employee_loans set status = 'approved', decision_note = 'OK' where id = :'loan';
select tst.ok((select count(*) from loan_schedule where loan_id = :'loan') = 12, '12 instalments');
select tst.ok((select sum(principal_paisa) from loan_schedule where loan_id = :'loan') = 12000000, 'schedule sums to principal');
select tst.ok((select total_repayable_paisa from employee_loans where id = :'loan') = 12000000, 'interest-free: repay principal only');
select tst.ok((select bs_year || '-' || bs_month from loan_schedule where loan_id = :'loan' and seq = 12) = '2084-7', 'last instalment Kartik 2084');
select tst.fails(format('update employee_loans set principal_paisa = 1 where id = %L', :'loan'), 'cannot change after a decision');
reset role;

-- Policy: only one active loan at a time.
select tst.claims(:'emp', false);
set local role authenticated;
insert into employee_loans (user_id, loan_type_id, principal_paisa, instalments, first_bs_year, first_bs_month, purpose)
values (:'emp', :'advance', 1000000, 1, 2083, 8, 'Second loan') returning id as loan2 \gset
reset role;
select tst.claims(:'admin', true);
set local role authenticated;
select tst.fails(format('update employee_loans set status = %L where id = %L', 'approved', :'loan2'), 'at most 1 active loan');
reset role;
select tst.claims(:'emp', false);
set local role authenticated;
update employee_loans set status = 'cancelled' where id = :'loan2';
reset role;

-- ------------------------------------------------------------ disbursement
select tst.claims(:'hr', true);
set local role authenticated;
select tst.fails(format('update employee_loans set status = %L where id = %L', 'active', :'loan'), 'check constraint');  -- needs disbursed_on
update employee_loans set status = 'active', disbursed_on = '2026-11-01', disbursement_ref = 'NIC Asia txn 123' where id = :'loan';
select tst.ok((select outstanding_paisa from loan_balances where loan_id = :'loan') = 12000000, 'outstanding = principal after disbursement');
reset role;

-- ------------------------------------------------------------ interest methods are exact to the paisa
-- Flat 12% p.a. on NPR 1,20,000 for 12 months = NPR 14,400 interest.
insert into employee_loans (user_id, loan_type_id, principal_paisa, interest_bp, interest_method, instalments, first_bs_year, first_bs_month, purpose, status)
values (:'emp2', :'personal', 12000000, 1200, 'flat', 12, 2083, 8, 'flat test', 'requested') returning id as flat \gset
select tst.claims(:'admin', true);
update employee_loans set status = 'approved' where id = :'flat';
select tst.ok((select total_repayable_paisa from employee_loans where id = :'flat') = 12000000 + 1440000, 'flat interest NPR 14,400');
select tst.ok((select sum(interest_paisa) from loan_schedule where loan_id = :'flat') = 1440000, 'flat interest spread exactly');
-- Approved but never paid out: cancelled, and its schedule removed (frees emp2's one-loan slot).
select tst.fails(format('update employee_loans set status = %L where id = %L', 'written_off', :'flat'), 'only an active loan');
update employee_loans set status = 'cancelled' where id = :'flat';
select tst.ok((select count(*) from loan_schedule where loan_id = :'flat') = 0, 'cancelled loan has no schedule');
-- Reducing balance 10% p.a. on an awkward amount, 7 months: last instalment clears the balance exactly.
insert into employee_loans (user_id, loan_type_id, principal_paisa, interest_bp, interest_method, instalments, first_bs_year, first_bs_month, purpose)
values (:'emp2', :'personal', 10000001, 1000, 'reducing', 7, 2083, 8, 'reducing test') returning id as red \gset
update employee_loans set status = 'approved' where id = :'red';
select tst.ok((select sum(principal_paisa) from loan_schedule where loan_id = :'red') = 10000001, 'reducing: principal exact');
select tst.ok((select bool_and(interest_paisa > 0) from loan_schedule where loan_id = :'red'), 'reducing: interest every month');
select tst.ok((select interest_paisa from loan_schedule where loan_id = :'red' and seq = 1)
               > (select interest_paisa from loan_schedule where loan_id = :'red' and seq = 7), 'reducing: interest declines');
select tst.ok((select max(due_paisa) - min(due_paisa) from loan_schedule where loan_id = :'red' and seq < 7) <= 1, 'reducing: equal EMIs');
select set_config('request.jwt.claims', '', true);

-- ------------------------------------------------------------ payroll repayment
select tst.claims(:'hr', true);
set local role authenticated;
insert into payroll_runs (bs_year, bs_month) values (2083, 8) returning id as run \gset
select due_paisa as due from loan_schedule where loan_id = :'loan' and seq = 1 \gset
update loan_schedule set payroll_run_id = :'run' where loan_id = :'loan' and seq = 1;
insert into payroll_lines (run_id, user_id, salary_record_id, basic_paisa, gross_paisa, ssf_employee_paisa, loan_deduction_paisa, net_paisa)
values (:'run', :'emp', :'sal', 5000000, 5000000, 550000, :'due', 5000000 - 550000 - :'due');
update payroll_runs set status = 'review' where id = :'run';
reset role;

select tst.claims(:'admin', true);
set local role authenticated;
-- Mismatch between line and instalments blocks approval.
savepoint s1;
reset role; update loan_schedule set payroll_run_id = null where loan_id = :'loan' and seq = 1; set local role authenticated;
select tst.fails(format('update payroll_runs set status = %L where id = %L', 'approved', :'run'), 'does not match');
rollback to savepoint s1;
-- Deductions over the policy cap block approval.
savepoint s2;
reset role; update loan_policy set max_deduction_bp_of_gross = 100; set local role authenticated;
select tst.fails(format('update payroll_runs set status = %L where id = %L', 'approved', :'run'), 'policy limit');
rollback to savepoint s2;
-- Matching: approval posts the repayment.
update payroll_runs set status = 'approved' where id = :'run';
select tst.ok((select status from loan_schedule where loan_id = :'loan' and seq = 1) = 'deducted', 'instalment marked deducted');
select tst.ok((select outstanding_paisa from loan_balances where loan_id = :'loan') = 12000000 - :'due', 'balance reduced by payroll');
reset role;

-- ------------------------------------------------------------ deferral
select tst.claims(:'hr', true);
set local role authenticated;
select tst.fails(format('update loan_schedule set status = %L where loan_id = %L and seq = 2', 'deferred', :'loan'), 'check constraint'); -- needs a note
update loan_schedule set status = 'deferred', note = 'Festival month, employee request' where loan_id = :'loan' and seq = 2;
select tst.ok((select bs_year || '-' || bs_month from loan_schedule where loan_id = :'loan' and seq = 13) = '2084-8', 'deferred instalment moved to the end');
select tst.ok((select sum(principal_paisa) from loan_schedule where loan_id = :'loan' and status in ('planned', 'deducted')) = 12000000,
              'still repays exactly the principal');
-- Employee can't be paid back into negative.
select tst.fails(format('insert into loan_ledger (loan_id, kind, amount_paisa, reason) values (%L, %L, -99999999, %L)',
                        :'loan', 'repayment_manual', 'cash'), 'negative');
reset role;

-- ------------------------------------------------------------ auto-close and privacy
select tst.claims(:'emp2', false);
set local role authenticated;
select tst.ok(tst.n('select * from employee_loans') = 2, 'emp2 sees own loans only');
select tst.ok(tst.n(format('select * from employee_loans where id = %L', :'loan')) = 0, 'emp2 cannot see emp''s loan');
reset role;

select tst.claims(:'emp', false);
set local role authenticated;
select tst.ok(tst.n('select * from loan_schedule') = 13, 'employee sees own schedule');
select tst.ok(tst.n('select * from loan_balances') = 2, 'employee sees own balances');
reset role;

select tst.ok(app.outstanding_loans_paisa(:'emp') = 12000000 - :'due', 'outstanding for final settlement');
select tst.fails(format('delete from loan_ledger where loan_id = %L', :'loan'), 'append-only');

-- Full manual repayment closes the loan.
select tst.claims(:'hr', true);
set local role authenticated;
insert into loan_ledger (loan_id, kind, amount_paisa, reason)
values (:'loan', 'repayment_manual', -(12000000 - :'due'), 'Settled in cash, receipt 45');
select tst.ok((select status from employee_loans where id = :'loan') = 'closed', 'loan closes at zero');
reset role;
rollback;
