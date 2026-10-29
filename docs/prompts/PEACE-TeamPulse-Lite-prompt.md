# BUILD PROMPT — TEAMPULSE LITE + HR (PEACE Consultancy, 25 users, Nepal)

## What this is

A **single-organization** work-management and HR system for **one team of 25 people in Nepal**. It joins five modules on one shared employee record:

1. **Time and activity:** Windows agent, timers, screenshots, timesheets.
2. **Leave and holidays:** home leave, sick leave, other statutory leave, public holidays.
3. **Attendance → payroll:** approved timesheets and leave feed a monthly payroll run.
4. **Administration:** employee records, onboarding and offboarding, compliance calendar, assets, announcements.
5. **Reports:** email and dashboards across all modules.

It is not a SaaS product. There is no multi-tenancy, no billing and no customer onboarding.

**Recommended builder:** one code-first AI agent (Claude Code or Cursor) building **one repository** with three parts: `/web` (Next.js app + API), `/agent` (Windows agent) and `/supabase` (database).

**Shared contract:** use `agent-api-contract.md` as the agent↔backend source of truth, **limited to the sections listed under "Windows agent" below**. Ignore the file-activity and command-channel parts.

**Golden rule for HR and payroll:** every legal number (leave days, SSF rates, tax slabs, deadlines, holidays) lives in a **versioned, admin-editable rules table**, never in code. Seed values are listed below. **PEACE's accountant must confirm them before the first live payroll.** The app computes from the rules; it does not decide the rules.

---

## Fixed parameters

| Item | Value |
|---|---|
| Organization | PEACE Consultancy (single tenant; no tenant tables) |
| Users | 25 employees + up to 3 admin/HR/manager accounts |
| Jurisdiction | **Nepal.** Labour Act 2074 + Labour Rules 2075 · Contribution-Based Social Security Act 2074 · Income Tax Act 2058 + Finance Act 2083 · Individual Privacy Act 2075 + Regulation 2077. GDPR does not apply. |
| Calendar | **Bikram Sambat (BS) is primary** for payroll months, leave years and holidays; AD is shown alongside. Use a BS↔AD conversion library with **year-specific month-length tables** (BS month lengths vary by year; never compute them with a formula). |
| Fiscal year | 1 Shrawan – end of Ashadh (FY 2083/84 = mid-July 2026 to mid-July 2027) |
| Time zone | **Asia/Kathmandu (UTC+05:45)**. Store UTC, display local; handle the 45-minute offset correctly. |
| Work week | 6 days, **Saturday weekly holiday** by default (configurable, in case PEACE uses a 5-day week) |
| Currency | NPR |
| Screenshot interval / retention | 10 minutes / 14 days |
| Activity data retention | 12 months · Payroll and HR records: retained per accountant's advice (default 7 years) |
| Report recipient | peace.consultancy@gmail.com (configurable list) |

---

## Roles

| Role | Can do |
|---|---|
| **Employee** | Own timer, timesheet, leave requests and balances, own payslips, own documents, announcements |
| **Manager** | Everything about their team's work and time; approve timesheets and leave. **Cannot see salaries.** |
| **HR / Accountant** | Employee records, leave rules, holiday calendar, payroll runs, payslips, statutory exports. Cannot view screenshots. |
| **Admin** | All settings, users, roles, monitoring policy, final payroll approval |

Salary and payroll data are visible **only** to HR/Accountant, Admin and the employee concerned. Screenshot evidence is visible only to Manager and Admin. Enforce both with Row Level Security, not just the UI.

---

## Stack

- **Web:** Next.js (TypeScript) on a managed host.
- **Database, auth and storage:** Supabase (PostgreSQL, Auth with MFA for Admin and HR, private Storage buckets for screenshots, documents and payslips, Row Level Security).
- **Scheduled jobs:** Supabase cron or host cron, for reports, leave accrual, compliance reminders and retention.
- **Email:** Resend or Postmark from **your own domain with SPF and DKIM**. Gmail is only a recipient.
- **PDF:** server-side generation for payslips and reports.
- **Agent:** C#/.NET 8 tray application, local SQLite queue protected by DPAPI.
- **Secrets:** environment variables only; provide `.env.example`.

---

# MODULE 1 — TIME AND ACTIVITY

### 1.1 People and work
- Admin/HR create, edit and deactivate employees.
- Simple **teams**, **projects** and **tasks** (name, estimate, deadline, status, assignee).

### 1.2 Time tracking and timesheets
- Start work, break, resume and stop, from the agent tray and the web app.
- The employee picks a task at start; switching tasks closes one timer and opens the next.
- **One running timer per employee**, enforced on the server.
- Idle detection (default 5 minutes) → employee chooses keep, discard or reassign.
- Manual entries and corrections need a reason. Keep the original value, new value, editor and reason. Manager approves.
- Timesheets: daily, weekly and **monthly by BS month**. Manager approval locks a period. Locked periods feed payroll (Module 3).

### 1.3 Windows agent (contract §2–§7 and §9; no file activity, no commands)
- One-time enrollment code from the web app (contract §3).
- Fetches policy; every feature is off until policy enables it (contract §4).
- Always-visible tray icon: Monitoring / Paused / Break / **On leave** / **Holiday** / Off, the current task, and a "What's being collected" panel.
- **The agent collects nothing on approved leave days, public holidays or weekly holidays**, unless the employee starts a session manually (counted as holiday work, see 3.3).
- Privacy pause (default maximum 30 minutes).
- During an active session inside the schedule, collects:
  - screenshots (contract §7)
  - foreground application name
  - browser domain only
  - keyboard and mouse event counts per 60 seconds (never content)
  - idle periods
- Exclusions are applied before capture.
- Offline queue and sync (contract §9). Heartbeat with capability status (contract §5.2, §8).
- MSI installer, code-signed, clean uninstall.

### 1.4 Screenshots, apps and websites
- Private bucket, short-lived signed links, timeline by employee, day and task.
- Every view and delete is audited. Nightly deletion after 14 days.
- App and domain usage with manager-editable categories (Productive / Neutral / Distracting / Unclassified). Default is Unclassified; nothing is pre-labelled distracting.

---

# MODULE 2 — LEAVE AND HOLIDAYS

### 2.1 Leave types (seed values, all editable in the rules table)

| Leave type | Seed entitlement | Paid | Carry-forward cap | Notes |
|---|---|---|---|---|
| Home leave (Ghar bida) | 1 day per 20 days worked | Full | 90 days | Excess over cap encashed; balance encashed at exit |
| Sick leave | 12 days/year | Full | 45 days | Medical certificate required above 3 consecutive days; encashed at exit |
| Maternity | 98 days (14 weeks) | 60 days full, rest unpaid | — | |
| Paternity | 15 days | Full | — | |
| Mourning (Kiriya) | 13 days | Full | — | |
| Public holidays | 13 days/year (14 for women) | Full | — | From holiday calendar (2.3) |
| Substitute leave | 1 day per approved holiday worked | Full | Configurable | Created automatically from holiday work |
| Unpaid leave | As approved | No | — | Deducted in payroll |

- Rules carry an **effective-from date** (BS), so a change never rewrites past balances.
- Probation: entitlements accrue pro rata.
- Sick, mourning and maternity leave are rights under the Labour Act. The system must not let a manager *reject* them, only request supporting documents. Other leave types can be approved or rejected.

### 2.2 Requests and approvals
- Employee requests leave (type, dates, half-day option, reason, optional attachment such as a medical certificate).
- The request shows the **projected balance** before submission and warns on overlap with holidays or other requests.
- Manager approves or rejects with a comment; HR can override with a logged reason.
- Approved leave automatically:
  - blocks timers and agent collection for those days
  - appears on the team calendar
  - flows into the monthly attendance summary (Module 3)
- Cancellation of approved leave restores the balance (audited).

### 2.3 Holidays: government list and company holiday policy
Nepal's public holidays are **gazetted each year and follow the lunar calendar**, so dates change annually. As a private company, PEACE sets its **own holiday provision** on top of that list:

- **Government list (reference only).** HR imports the gazetted holidays for the year (manually or by CSV). On its own the list gives nobody a day off.
- **Company decision per government holiday:** **observe** it, **skip** it (office open), or **move** it (observe on another date). Each decision is recorded with who made it and why.
- **Company-only holidays**, e.g. the company's foundation day.
- **Optional (floating) holidays.** HR lists the optional days; each employee picks up to the yearly quota, in advance.
- **Scope:** all staff, women only (e.g. Teej), or a named group.
- **Holiday policy per fiscal year:** legal minimums (seed: 13 paid public holidays, plus 1 more for women; accountant to confirm), the optional quota, notes.
- **Admin approves the policy.** Approval is refused while any government holiday is undecided, or if the policy falls below the legal minimum (fixed holidays + optional quota, counted separately for women).
- **Only an approved policy gives days off.** After approval the year's calendar is frozen; an admin must reopen it to change it (audited).
- The weekly holiday (Saturday by default) stays a separate company setting.
- **Do not hard-code holiday dates.** Seed demo data, clearly labelled, for HR to replace.

### 2.4 Accrual job
- Monthly, at BS month end: home leave accrues from days actually worked (from approved timesheets).
- Fiscal-year end: applies carry-forward caps, flags encashable excess for payroll, and starts a new leave year.

### 2.5 Views
- **Employee:** balances, history, request form, upcoming holidays.
- **Manager:** team calendar (who's off when), pending approvals.
- **HR:** all balances, adjustments with reason, leave liability report (encashable days × daily basic).

---

# MODULE 3 — ATTENDANCE → PAYROLL

**Scope:** the app **calculates and documents** payroll. It **does not move money**. Output is a payroll register, payslips and export files that the accountant uses for bank transfers, SSF deposits and TDS filing.

### 3.1 Salary records (HR only)
- Per employee:
  - **basic salary**
  - allowances (each named, each flagged as part of basic or not)
  - SSF-enrolled yes/no
  - PAN
  - bank name and account for the transfer file
  - join date, probation end, exit date
- Salary changes are versioned with an effective date. Past payroll never changes.
- Bank account numbers and PAN are stored **encrypted at column level**, visible only to HR and Admin.

### 3.2 Monthly attendance summary (per BS month, per employee)
Built automatically from locked timesheets + approved leave + holiday calendar:
- working days in month
- days worked
- paid leave days (by type)
- unpaid leave days
- public and weekly holidays
- holiday days worked
- overtime hours (hours above the configured daily/weekly limit, **only if approved by a manager**)

HR reviews the summary and can correct it with a reason. Corrections are audited.

### 3.3 Payroll rules (rules table, seed values; accountant must confirm)

| Rule | Seed value |
|---|---|
| SSF employee contribution | 11% of basic |
| SSF employer contribution | 20% of basic (on top of gross) |
| Social Security Tax (1%) | Waived for SSF-enrolled employees |
| Income tax (FY 2083/84, single table for all residents) | Up to NPR 10,00,000 → 1%; 10,00,001–15,00,000 → 10%; … top rate 29%. **Intermediate bands to be entered by the accountant from the IRD schedule.** |
| TDS method | Projected annual taxable income ÷ remaining months, recalculated each month |
| Festival allowance (Dashain) | One month's basic per year, month configurable |
| Overtime rate | Configurable multiplier of hourly basic (accountant to confirm) |
| Unpaid leave deduction | (Basic + fixed allowances) ÷ days in BS month × unpaid days |
| Holiday work | Substitute leave by default, or overtime pay (configurable) |
| SSF deposit deadline | 15th of the following BS month |
| TDS deposit deadline | 25th of the following BS month |

- Tax slabs and SSF rates are stored **per fiscal year**. Selecting a payroll month picks the correct year's rules.
- Deductions that reduce taxable income (retirement contribution, insurance, etc.) are a configurable list for the accountant to maintain.

### 3.4 Payroll run workflow
1. **Draft:** HR opens a BS month; the system pulls attendance summaries and calculates gross, deductions, SSF, TDS and net for each employee.
2. **Review:** a line-by-line register with variance against the last month. Anything changed by more than a configurable % is flagged, along with missing data (no PAN, no bank account, unapproved timesheets).
3. **Adjust:** one-off additions and deductions (bonus, advance recovery), each with a reason.
4. **Approve:** Admin approves. The run is **locked**. Corrections after locking happen only as an adjustment in the next run.
5. **Publish:** payslips (PDF, English, optionally Nepali) go to each employee's dashboard; an email notifies them with a **link, not the payslip attached**.

### 3.5 Payroll outputs
- payroll register (PDF and CSV)
- payslips
- **SSF contribution sheet** (per employee: basic, 11%, 20%, total) laid out for upload to the SSF portal
- **TDS summary** for IRD filing
- **bank transfer CSV** (configurable column layout for PEACE's bank)
- leave encashment statement at exit and year end
- final settlement on exit: last salary, encashed home and sick leave, pro-rata festival allowance

### 3.6 Safety rules
- **Parallel run:** for the first two months, run payroll in the app alongside PEACE's current method and compare. Show a "parallel run" badge until the accountant switches it off.
- Every calculation shows its working (inputs → rule → result) on the register.
- If any rule is missing for the selected fiscal year, the system refuses to calculate rather than guessing.

### 3.7 Employee loans and salary advances
- **Loan types** (company policy, HR-editable): salary advance, personal loan, emergency loan. Each type has a cap (fixed amount and/or months of basic, whichever is lower), a maximum number of instalments, and an interest rate and method (**none**, **flat**, or **reducing balance**). Seed: 0% interest.
- **Loan policy** (admin-editable): maximum share of monthly gross that loan deductions may take (seed 50%), maximum active loans per person (seed 1), minimum service before borrowing (seed 6 months), whether probation staff may borrow, and recovery at exit.
- **Workflow:** employee requests (or HR enters on their behalf) → **admin approves or rejects** (MFA; never their own) → repayment schedule generated by BS month → HR records the disbursement date and bank reference after paying it out → loan active. The app never moves money.
- **Schedule** is exact to the paisa: instalments always sum to the principal; the last one absorbs rounding. HR can **defer** an instalment with a reason (it moves to the end) or record a **manual repayment**.
- **Payroll:** each month's instalment is linked to the run and shown as its own **loan deduction** line on the register and payslip. On payroll approval the database checks the amounts match and respect the policy cap, then posts the repayment.
- **Balance** = sum of an append-only loan ledger (disbursement, interest, repayments, adjustments, write-off). The loan closes automatically at zero. Only an admin can write off an active loan.
- **Exit:** outstanding balances appear in the final settlement and on the offboarding checklist.
- **Privacy:** loans are pay data — the employee, HR and admin only. Never managers.
- **Tax:** the accountant must confirm whether interest-free or low-interest loans create a taxable benefit.

### 3.8 Pay scheme and pay package overview
- **Pay grades (salary scales):** code, name, basic salary range (min–max), annual increment (fixed amount or %), standard allowances for the grade, versioned by effective date. A salary version may be linked to a grade; salaries outside the range are allowed but flagged.
- **Non-cash benefits** (group medical and accident insurance, lunch, phone, training…) valued per year per employee, each flagged taxable or not (accountant to confirm).
- **Package overview per employee:** monthly basic, allowances and gross; SSF employee and employer amounts; yearly festival allowance; benefits; **annual cash pay**; **annual cost to company**; position within the grade range. Shows a warning when payroll rules are missing or not yet confirmed. Pre-tax estimate only; payroll does the actual tax.
- **Grade overview:** per grade — range, standard allowances, headcount, lowest/average/highest basic, how many are outside the range, total annual cost.
- **Visibility:** employees see their own package; HR and admin see everything; the grade structure itself is HR/admin only; managers see none of it.

---

# MODULE 4 — ADMINISTRATION

### 4.1 Employee records
- Profile: personal details, emergency contact, job title, team, manager, employment type (regular / probation / contract), join and exit dates.
- **Documents:** contract, citizenship copy, PAN card, certificates. Private bucket; access limited to HR, Admin and the employee; every view is audited. Expiry reminders for documents with an end date (e.g. contracts).

### 4.2 Onboarding and offboarding checklists
- Template checklists, editable by HR, each item with an owner and due date.
  - **Onboarding:** contract signed, documents collected, SSF enrollment, PAN recorded, bank details, device enrolled, monitoring notice consented.
  - **Offboarding:** device returned, agent revoked, access removed, final settlement run, experience letter.
- Starting an offboarding checklist automatically schedules agent revocation for the exit date.

### 4.3 Compliance and admin task calendar
- Recurring admin tasks with owner, due date (BS) and reminder emails. Seed tasks:
  - SSF deposit (by the 15th)
  - TDS deposit (by the 25th)
  - monthly payroll run
  - fiscal-year leave close
  - holiday calendar update for the new year
  - annual tax return support
- Overdue items appear on the Admin dashboard and in the daily report.

### 4.4 Assets register
- Company laptops and PCs: tag, model, serial, assigned employee, issue and return dates, **linked to the enrolled agent device**.

### 4.5 Announcements
- HR/Admin post notices (policy changes, holiday reminders). Employees see them on their dashboard and can acknowledge where required.

---

# MODULE 5 — DASHBOARDS AND REPORTS

### Dashboards
- **Employee:** my timer, my day, timesheet, leave balances and requests, payslips, documents, announcements, monitoring notice.
- **Manager:** team status today (working / break / on leave / holiday / offline), timesheet and leave approvals, team calendar, per-employee day view, projects (estimate vs actual), agent health.
- **HR/Accountant:** pending payroll steps, attendance summaries, leave liability, missing employee data, compliance calendar.
- **Admin:** all of the above, plus settings and audit log.

### Email reports (links to dashboard, never screenshots or payslips attached)
- **Daily:** tracked hours, breaks, idle, tasks, agent problems, who is on leave today, pending approvals, overdue admin tasks.
- **Weekly:** team totals vs last week, project hours vs estimates, overdue tasks, upcoming leave and holidays.
- **Monthly (after payroll lock):** payroll totals (to Admin/HR only), SSF and TDS amounts due with deadlines, leave taken by type.
- Delivery log and one automatic retry.

---

## Transparency and consent (Nepal Privacy Act 2075)
- Each employee sees the **monitoring and HR data notice** on first login and in the agent, and gives consent. The notice states:
  - purpose
  - what is collected and when
  - who can see it
  - retention
- Consent is stored with a timestamp and notice version. Without consent, the agent collects nothing for that employee.
- Employees can view their own data (time, leave, payslips, documents) and request corrections.
- Monitoring stays disabled until an Admin confirms the notice has been issued (logged).
- MFA for Admin and HR. HTTPS everywhere. Encrypted at rest. Audit log covers admin actions, screenshot views, document views, salary changes, leave overrides and payroll approvals.

---

## OUT OF SCOPE (do not build now)

Multi-tenancy, billing · auditor role · file-activity monitoring · manager-triggered screenshots · window titles and full URLs · productivity scores · macOS, Linux and mobile agents · **sending money, SSF portal or IRD integration (exports only)** · expense claims and reimbursements · recruitment · performance reviews.

Keep module boundaries clean so these can be added later.

---

## Database (single tenant)

**Time:** `users`, `teams`, `projects`, `tasks`, `devices`, `enrollment_codes`, `policies`, `work_sessions`, `breaks`, `time_entries`, `time_corrections`, `timesheet_periods`, `idle_events`, `app_events`, `web_events`, `input_metrics`, `screenshots`, `app_categories`

**Leave:** `leave_types`, `leave_rules` (versioned), `leave_balances`, `leave_ledger` (every accrual, use, adjustment and encashment as a row), `leave_requests`, `government_holidays` (reference list + company decision), `holiday_calendar` (company calendar), `holiday_policies` (per fiscal year), `employee_optional_holidays`, `substitute_leave`

**Payroll:** `salary_records` (versioned), `allowance_types`, `payroll_rules` (versioned by fiscal year: SSF, tax slabs, deductions), `attendance_summaries`, `payroll_runs`, `payroll_lines`, `payroll_adjustments`, `payslips`, `exports`

**Loans:** `loan_policy`, `loan_types`, `employee_loans`, `loan_schedule`, `loan_ledger` (append-only), view `loan_balances`

**Pay scheme:** `pay_grades` (versioned), `pay_grade_allowances`, `benefit_types`, `employee_benefits`, views `pay_package_overview`, `pay_grade_overview`

**Admin:** `employee_profiles`, `documents`, `checklist_templates`, `checklists`, `checklist_items`, `admin_tasks`, `assets`, `announcements`, `acknowledgements`

**Shared:** `report_schedules`, `email_log`, `audit_log`, `notice_consents`

Rules:
- UUID keys and UTC timestamps; store a **BS date alongside AD** for leave, holidays and payroll periods.
- Money as integer paisa (never floating point).
- Leave balances are derived from `leave_ledger`, never edited directly.
- Unique `event_id` for agent dedup.
- Row Level Security per the roles table.

---

## Acceptance tests (pilot-ready when all pass)

**Time and activity**
1. Admin creates 25 employees, projects and tasks; employees see only their own data.
2. Start, break, resume and stop produce correct, non-overlapping entries; a second timer is refused.
3. The agent captures a **real** screenshot every 10 minutes during a session. It collects **zero** data on break, pause, leave days, holidays, outside schedule, or in excluded apps.
4. 30 minutes offline → events sync exactly once.
5. Daily and weekly reports arrive (not in spam), and totals match the dashboard in Kathmandu time.

**Leave and holidays**
6. Home leave accrues 1 day per 20 days worked; balances respect the 90-day and 45-day caps; excess is flagged for encashment at year end.
7. A sick-leave request over 3 days asks for a certificate. A manager cannot reject sick, mourning or maternity leave.
8. Approved leave blocks timers and agent collection on those days.
9. A holiday imported for the year shows on all calendars; working on it creates substitute leave.

**Payroll**
10. A month's payroll for a test employee matches a **hand calculation provided by PEACE's accountant**: gross, unpaid-leave deduction, SSF 11% and 20%, TDS and net.
11. Changing a tax slab for next year does not change any locked past payroll.
12. A missing fiscal-year rule blocks calculation with a clear message.
13. Payslips are visible only to the employee, HR and Admin; managers get "access denied".
14. The SSF sheet and bank CSV totals equal the payroll register totals.
15. Exit settlement includes encashed home and sick leave balances.

**Admin and security**
16. Offboarding revokes the agent on the exit date.
17. The compliance calendar sends SSF and TDS reminders before the 15th and 25th.
18. Every screenshot view, document view, salary change and payroll approval appears in the audit log.

**Loans, pay scheme, holiday policy**
19. A loan over the type's cap, or with too many instalments, is refused. HR and the borrower cannot approve; an admin can. A second loan beyond the policy limit is refused.
20. Every schedule (none, flat, reducing) sums exactly to the principal; flat 12% on NPR 1,20,000 over 12 months gives NPR 14,400 interest.
21. Payroll approval refuses a loan deduction that doesn't match the linked instalment or exceeds the policy cap; on approval the balance falls by exactly the instalment.
22. The package overview matches a hand calculation (gross, SSF on basic incl. part-of-basic allowances, festival allowance, benefits, annual cost to company); managers see no packages.
23. A government holiday gives no day off until the company observes it and an admin approves the year's policy; a skipped one is a working day; a moved one uses the new date.
24. Approval is refused below the legal minimum (counted separately for women) or with undecided government holidays; an employee cannot choose more optional holidays than the quota.

---

## Deliverables

1. One repo: `/web`, `/agent`, `/supabase` (migrations + RLS).
2. BS calendar utility with tests covering at least FY 2082/83–2084/85 month lengths.
3. Seed script: **clearly labelled demo data** (employees, holidays, salaries), removable with one command.
4. Rules-table seed (leave, SSF, tax) with a **"to be confirmed by accountant"** flag on every row.
5. Automated tests for time logic, leave accrual, payroll calculation, RLS and dedup.
6. `README`: setup, deploy, sign and enroll the agent, run the first payroll.
7. `.env.example`.
8. **Monitoring and HR data notice and consent template**, English and Nepali.
9. **Accountant's checklist:** every rule and value they must confirm before the first live payroll.
10. Monthly running-cost estimate.

---

## Cost guide (approximate; verify)

HR and payroll add negligible storage and compute. The estimate stays at **about US$30–50/month plus a code-signing certificate (about US$200–400/year)**, roughly **US$1.50–2 per user/month**.

---

## Execution order (each phase usable on its own)

1. **Foundation:** repo, Supabase schema, RLS, roles, MFA, BS calendar utility.
2. **Time:** users, projects, tasks, timers, timesheets with monthly lock.
3. **Agent:** enrollment, policy, tray, real screenshots end to end, collectors, offline sync.
4. **Leave and holidays:** rules, requests, approvals, holiday calendar, accrual job; agent respects leave and holidays.
5. **Payroll:** salary records, attendance summary, rules, payroll run, payslips, exports. **Start the two-month parallel run.**
6. **Admin:** records, documents, checklists, compliance calendar, assets, announcements.
7. **Reports and dashboards** across all modules; retention jobs.
8. Pilot on 3 consenting employees → fix → roll out to all 25.

At the end of each phase, report what works end to end, what is stubbed, and any blocker. Do not mark a feature complete until it has run end to end, and for payroll, until it matches the accountant's hand calculation.
