# Deploying TeamPulse (web app)

This puts the web app online so PEACE's team can install it on their laptops and phones. It needs two free-to-start services:

- **Supabase**: the database, sign-in and file storage.
- **Vercel**: hosts the web app.

Do it first on a **staging** project and run the checks at the end, then repeat for production.

> **Not yet verified on a hosted Supabase project.** Everything has been tested on PostgreSQL 16 with a stand-in for Supabase's sign-in. The checks in step 7 are the first time it meets real Supabase.

## 1. Create the Supabase project

1. At supabase.com, create a project in an Asian region close to Nepal, such as Mumbai or Singapore.
2. Save the database password somewhere safe.
3. **Authentication → Sign In / Providers:** keep Email on. **Turn off "Allow new users to sign up".** Only admins add people.
4. **Authentication → Multi-Factor:** enable **TOTP (authenticator app)**.
5. **Authentication → URL Configuration:**
   - Site URL = your app address, e.g. `https://teampulse.peace.com.np`
   - Add the same address to Redirect URLs.
6. **Authentication → Email Templates.** For **Invite user** and **Reset password**, change the link to:
   - Invite: `{{ .SiteURL }}/auth/confirm?token_hash={{ .TokenHash }}&type=invite&next=/reset-password`
   - Reset: `{{ .SiteURL }}/auth/confirm?token_hash={{ .TokenHash }}&type=recovery&next=/reset-password`
7. **Authentication → SMTP:** set up sending from PEACE's own domain (Resend, Postmark, or similar, with SPF and DKIM). Supabase's built-in mailer is rate-limited and not meant for production.

## 2. Create the database

With the Supabase CLI, from the repository folder:

```bash
supabase link --project-ref <your-project-ref>
supabase db push                      # applies supabase/migrations/* in order
```

Or paste each file in `supabase/migrations/` into **SQL Editor**, in filename order.

Then load the reference data. Run these two files in the SQL Editor:

- `supabase/seed/00_bs_calendar.sql`: the Nepali calendar
- `supabase/seed/01_reference_rules.sql`: leave, SSF and tax rules, checklists, compliance tasks

**Staging only:** `supabase/demo/demo_load.sql` adds 25 labelled demo employees. Remove them with `supabase/demo/demo_remove.sql`. **Never load demo data in production.**

## 3. Create the first admin

1. **Authentication → Users → Add user:** your email and a strong password, with **auto-confirm** ticked.
2. In the **SQL Editor**, replace the name and email in this script, then run it:

```sql
insert into public.profiles (id, email, full_name, role, join_date)
select id, email, 'Your Full Name', 'admin', current_date from auth.users where email = 'you@peace.com.np';
insert into public.employee_profiles (user_id) select id from auth.users where email = 'you@peace.com.np';
```

Everyone else is added from the app, under **People → Add employee**. That sends them an invitation email.

## 4. Deploy the app on Vercel

1. At vercel.com, choose **Add New → Project** and import `sachitss/teampulse` from GitHub.
2. Set **Root Directory** to `web`. The framework is detected as Next.js; keep the default build command.
3. Add these **Environment Variables**:

| Name | Value | Where to find it |
|---|---|---|
| `NEXT_PUBLIC_SUPABASE_URL` | `https://<ref>.supabase.co` | Supabase → Project Settings → API |
| `NEXT_PUBLIC_SUPABASE_ANON_KEY` | the anon / publishable key | same page |
| `SUPABASE_SERVICE_ROLE_KEY` | the service_role / secret key. **Server-only; never share it.** | same page |
| `DATABASE_URL` | the **Transaction pooler** connection string (port 6543), with your password | Supabase → Connect |
| `APP_BASE_URL` | `https://teampulse.peace.com.np` | your address |

**Do not set** `TP_DEV_AUTH` or `TP_DEV_AUTH_SECRET` in Vercel. The developer sign-in refuses to run in production builds anyway, but don't set them.

4. Click **Deploy**. Then, under **Settings → Domains**, add PEACE's domain (for example `teampulse.peace.com.np`) and follow Vercel's DNS instructions. Installing the app needs HTTPS, which Vercel provides automatically.

## 5. First sign-in and switching monitoring on

1. Open the site, sign in as the admin, and set up two-factor when asked. HR and admin rights only work with two-factor.
2. **Settings → Monitoring and HR data notice:**
   - fill in the [bracketed] parts
   - have a fluent reader check the Nepali text
   - publish
3. You will be asked to consent, like everyone else.
4. Give the notice to the whole team, for example in a staff meeting or by email. Then tick **"I confirm the notice was issued to all employees"**.

Until both steps are done, the database refuses to store any activity data at all.

## 6. Add the team

- **People → Add employee** for each person. Set their manager, team and join date. Each person gets an invitation email to set a password.
- Send everyone `docs/install-guide.md` so they can install the app.

## 7. Checks on staging (do these before production)

| Check | Expected |
|---|---|
| Sign in as an employee | Asked to consent, then sees **Today** |
| Employee starts, breaks, resumes and stops the timer | Entries appear under Today's time |
| Sign in as HR **without** completing two-factor | Banner says HR rights are off; **People** is hidden |
| Manager opens Approvals | Sees only their own team's requests |
| Visit `/dev-login` on the deployed site | **404** |
| Install on a laptop (Chrome or Edge) and on a phone | Opens in its own window with the TeamPulse icon |
| Supabase → Table Editor → `audit_log` | Shows profile changes and approvals |

If `set role authenticated` fails on the pooler connection, check under **Database → Roles** that the `postgres` role is a member of `authenticated`. It is on standard Supabase projects.

## Costs (approximate; check current prices)

Both services have free tiers that may be enough to start with. For 25 people in production, plan on Supabase Pro (about US$25 per month: daily backups, no pausing) and Vercel Pro (about US$20 per month for commercial use).
