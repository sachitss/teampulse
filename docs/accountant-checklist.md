# Accountant's checklist — confirm before the first live payroll

Every value below is seeded with status **`to_confirm`**. Payroll will calculate with it, but each run carries a **"parallel run"** badge until the accountant has confirmed the rules and switched that badge off. Confirming a rule records who confirmed it and when.

Sources were checked on 29 Oct 2026 and are recorded on each row in the database (`source_note`). They are practice guides and law-firm summaries, not the gazette. **Check each against the Act, the Finance Act 2083 and the IRD rate sheet.**

## 1. Social Security Fund (both FY 2082/83 and 2083/84)

| Rule | Seeded value | Confirm |
|---|---|---|
| SSF employee contribution | 11% of basic | ☐ |
| SSF employer contribution (on top) | 20% of basic | ☐ |
| 1% Social Security Tax waived for SSF contributors | yes | ☐ |
| SSF deposit deadline | 15th of the following BS month | ☐ |

Also confirm **what counts as "basic"** for each allowance type (`part_of_basic` flag), because SSF is calculated on basic only.

## 2. Income tax — FY 2083/84 (one table for all resident individuals)

| Band | Annual taxable income (NPR) | Rate | Confirm |
|---|---|---|---|
| 1 | up to 10,00,000 | 1% (SST band) | ☐ |
| 2 | 10,00,001 – 15,00,000 | 10% | ☐ |
| 3 | 15,00,001 – 25,00,000 | 20% | ☐ |
| 4 | 25,00,001 – 40,00,000 | 27% | ☐ |
| 5 | above 40,00,000 | 29% | ☐ |

Two independent sources agreed on these bands; one cites the IRD rate sheet for income year 2083/084.

## 3. Income tax — FY 2082/83 (only needed for back months)

Seeded with the **single-person** schedule: 1% to 5 lakh · 10% to 7 lakh · 20% to 10 lakh · 30% to 20 lakh · 36% to 50 lakh · 39% above.
☐ Confirm. ☐ Add the **couple** schedule if any employee was assessed as a couple that year (the system has no couple schedule yet).

## 4. Other payroll rules

| Rule | Seeded value | Note | Confirm |
|---|---|---|---|
| TDS deposit deadline | 25th of the following BS month | from payroll guides | ☐ |
| Festival (Dashain) allowance | 1 month of basic per year | Labour Act 2074 | ☐ |
| Month the festival allowance is paid | Ashwin (BS month 6) | set to the month PEACE actually pays | ☐ |
| Overtime multiplier | 1.5 × hourly basic | **not verified** | ☐ |
| Daily hours before overtime | 8 | **not verified** | ☐ |
| Weekly hours before overtime | 48 | **not verified** | ☐ |
| Work on a holiday | substitute leave (not overtime pay) | PEACE policy choice | ☐ |

## 5. Tax deductions (empty — must be entered)

Deductions that reduce taxable income (retirement fund, life and health insurance, and so on) are a list in `tax_deduction_rules`. **It is empty.** Enter each deduction PEACE's staff can claim, with its annual cap and/or percentage limit.

## 6. Leave rules (Labour Act 2074, effective 4 Sept 2017)

| Leave | Seeded rule | Confirm |
|---|---|---|
| Home leave | 1 day per 20 days worked · carry up to 90 · encash excess at year end and balance at exit | ☐ |
| Sick leave | 12 days/year · carry up to 45 · encash excess and at exit · certificate above 3 consecutive days | ☐ |
| Maternity | 98 days, 60 fully paid | ☐ |
| Paternity | 15 days paid | ☐ |
| Mourning | 13 days paid | ☐ |
| Substitute leave | 1 day per approved holiday worked | ☐ |
| Unpaid leave | deducted at (basic + fixed allowances) ÷ days in BS month × unpaid days | ☐ |

Confirm in particular: **is year-end encashment of excess sick leave correct for PEACE?** And: **is the 3-day certificate threshold PEACE's policy?** The second comes from a practice guide, not the Act.

## 7. Calendar and holidays

- ☐ **Legal minimum for the holiday policy.** Seeded: **13** paid public holidays, plus **1 more for women**. Confirm against the Labour Act 2074. Admin approval is refused below this.
- ☐ **Import the government (gazetted) list** for the fiscal year. It is a reference only: decide **observe / skip / move** for each holiday, add company-only days, list any optional holidays, set the optional quota, then ask the admin to approve the year's policy. **No public holiday counts as a day off until the policy is approved.**
- ☐ The database holds only labelled **demo** holidays; remove them with the demo removal script.
- ☐ **BS 2084 month lengths are provisional.** Baisakh–Asar 2084 fall inside FY 2083/84. When the official 2084 calendar is published (Nepal Panchanga Nirnayak Vikas Samiti), compare it with the provisional table. Any difference changes those payroll months. Seeded provisional 2084: 31 · 31 · 32 · 31 · 31 · 30 · 30 · 30 · 29 · 30 · 30 · 30.

## 8. Loans and advances (PEACE policy)

| Setting | Seeded value | Confirm |
|---|---|---|
| Salary advance | up to 1 month of basic, 3 instalments, 0% | ☐ |
| Personal loan | up to 6 months of basic, 24 instalments, 0% | ☐ |
| Emergency loan | up to 3 months of basic, 12 instalments, 0% | ☐ |
| Maximum loan deductions in a month | 50% of gross | ☐ |
| Active loans per person | 1 | ☐ |
| Service before borrowing / during probation | 6 months / not allowed | ☐ |
| Recover outstanding balance at exit | yes | ☐ |

- ☐ **Tax:** confirm whether an interest-free or low-interest employee loan creates a taxable benefit under the Income Tax Act 2058. If it does, a rule for valuing that benefit must be added before such loans are approved.

## 9. Pay scheme and benefits

- ☐ Enter PEACE's **pay grades**: ranges, annual increment, and standard allowances per grade. None are seeded except demo grades.
- ☐ For each **benefit type** (group medical/accident insurance, lunch, phone, training), confirm whether it is **taxable** for the employee. The seeded flags are a first guess.
- ☐ For each **allowance type**, confirm `part_of_basic` (counts for SSF) and `taxable`.

## 10. Before switching off the parallel-run badge

- ☐ At least two monthly runs match PEACE's current payroll to the paisa for every employee.
- ☐ The SSF sheet and bank file totals equal the register totals.
- ☐ The bank transfer file layout matches PEACE's bank.
