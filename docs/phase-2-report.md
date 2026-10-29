# Phase 2 report — Installable web app (29 Oct 2026)

## What you can install

One web app, `web/`, built with Next.js 16. It installs from the browser:

- **Windows and Mac laptops**: the install icon in Chrome or Edge; Safari → Add to Dock
- **Android**: Chrome → Install app
- **iPhone and iPad**: Safari → Share → Add to Home Screen

On a phone it shows bottom tabs; on a laptop it shows a top menu. Staff instructions are in `docs/install-guide.md`, and going live is covered in `docs/deploy-guide.md`.

## Screens

| Screen | Who | What it does |
|---|---|---|
| Sign-in, password reset, invitation | Everyone | Supabase email and password sign-in |
| Two-factor | HR and admin | Set up and verify an authenticator-app code. Without it, the database switches off HR and admin rights for that session |
| Consent | Everyone, first time and after each new notice | Shows the notice in English with the Nepali version. Nothing is recorded for a person until they consent |
| **Today** | Everyone | Start work on a task, switch task, take a break or privacy pause, resume, stop. Live clock. Add time without the timer (needs a reason and manager approval). Warns on holidays; blocked on approved leave |
| **Timesheet** | Everyone; managers for their team | BS month view on Kathmandu days, with holidays and leave shaded, totals, time waiting for approval, and submitting the month |
| **Approvals** | Managers (their team), HR and admin (everyone) | Approve or reject manual time; approve, send back or **lock** monthly timesheets for payroll |
| **Projects** | Managers, HR, admin | Projects and tasks with assignee, estimate against recorded time, due date, priority and status |
| **People** | HR and admin | Directory with consent status. An admin adds employees, which sends an invitation and starts their onboarding checklist. HR edits employment details; only an admin changes roles, managers or active status |
| **Settings** | Admin | Publish the notice (refused while [bracketed] placeholders remain), confirm it was issued (this is what switches monitoring on), weekly holiday, report recipients |

## How it is built

- **Every database query runs as the signed-in person**, inside a transaction using the `authenticated` role and that person's verified claims. The Phase 1 Row Level Security rules and triggers therefore apply unchanged. The app layer cannot see more than the person is allowed to.
- **Sign-in:** Supabase Auth. The server verifies the access token with `getClaims()`, and `proxy.ts` keeps the session fresh.
- **Installable app:** a web manifest, icons for every platform, and a service worker. **The service worker never stores pages or data**; it caches only icons, build files and an offline page, so nothing personal stays on a phone.
- **Dev-only sign-in** (`/dev-login`) for local testing. A production build returns 404 for it and rejects its tokens even if the dev variables are set. This was verified against a running production build with a forged token.

## Tests

| Suite | Result |
|---|---|
| Nepali calendar (14) | pass |
| Database rules (11 SQL files, 229 assertions, plus the demo round trip) | pass |
| Web timer and timesheet logic against a real database (4) | pass |
| **Real browser, end to end (9)**: admin publishes and confirms the notice; employee consents and works a full timer day; manual time and an overlap refusal; month submission; manager approves and locks; HR without two-factor is restricted; admin adds an employee; manager adds a project and task; phone layout; manifest, icons and service worker | pass |
| Production build | pass; every personal page renders per request |
| Production safety: `/dev-login` returns 404, forged dev token rejected, service worker served with strict headers | pass |

A GitHub Actions workflow (`.github/workflows/ci.yml`) runs all of these on every push.

## Found and fixed while testing

1. **Locking the current month** stopped everyone recording time for the rest of it. A new rule (migration 0010) allows locking only after the month ends, and the screen shows "Can be locked after the month ends".
2. **Pages could have been prerendered once for everyone** if the app was built without sign-in settings. The session check now always reads the request, so every personal page is rendered per person.
3. **Success messages disappeared.** After approving an item or publishing the notice, the confirmation vanished along with the form. Results now show as a banner at the top of the page.
4. **The timer clock lagged** by a few seconds after page load. It now corrects only for device clocks that are more than a minute wrong.

## Not done yet

- **Agent endpoints** (`/agent/v1/*`) and the **Windows agent**: Phase 3, next.
- **Leave requests, the holiday policy, payroll, loans and pay package screens.** Their database rules are done and tested; the screens come in Phases 4–5.
- **An employee "request a correction" screen.** Corrections exist in the database, but there is no form for them yet; employees can add manual time for now.
- **The 30-minute privacy-pause limit** is enforced by the agent policy, not yet by the web timer.
- **Nepali interface text.** The interface is in English; the notice is bilingual.
- **Not yet run against a hosted Supabase project.** This is step 7 of the deploy guide.
