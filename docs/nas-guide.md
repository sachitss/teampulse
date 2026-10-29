# Running TeamPulse on PEACE's Synology NAS

TeamPulse runs entirely on the office **Synology DS918+**. No Supabase or Vercel account is needed. Staff reach it from anywhere at an https address such as `https://teampulse.peace.com.np`, through a **Cloudflare Tunnel**. No ports are opened on the office router.

```
 Laptops / phones ──https──▶ Cloudflare ──tunnel (outbound from NAS)──▶ cloudflared ─▶ app ─▶ PostgreSQL
                                                                        (all on the NAS, private network)
```

| On the NAS | What it does |
|---|---|
| `db` | PostgreSQL 16, which holds all of TeamPulse's data. It is never reachable from outside. |
| `migrate` | Runs for a few seconds at every start to update the database, then stops. |
| `app` | The TeamPulse web app. |
| `backup` | Takes a database backup every night at 02:00 Nepal time and keeps 30 days. |
| `cloudflared` | The tunnel: the only way in. |

Expect about 1 hour for the first setup.

---

## 0. Before you start

- **DSM 7.2 or newer** with **Container Manager**. Check the DSM version under Control Panel → Info Center. The DS918+ is a 2018 model. Look it up on Synology's [product support status](https://www.synology.com/en-global/products/status) page and keep DSM updated (Control Panel → Update & Restore).
- **RAM:** 4 GB is enough for TeamPulse with 25 people. **8 GB** is recommended if the NAS also runs other things such as Surveillance Station or Photos. The DS918+ takes one extra SO-DIMM (DDR3L-1866); Synology's own module is the D3NS1866L-4G.
- **A domain on Cloudflare.** Cloudflare's free plan is enough. If PEACE already has a domain such as `peace.com.np`, you can move its DNS to Cloudflare (a `.com.np` domain's name servers are changed at register.com.np), or buy a cheap separate domain just for TeamPulse.
- **A UPS** is strongly recommended. Connect it by USB and turn on Control Panel → Hardware & Power → UPS → **Enable UPS support** (safe shutdown). A sudden power cut is the most common way to damage a database.
- The office line already has a real public IP (we checked: the router's PPPoE address matches what the internet sees). The tunnel doesn't need it, and keeps working if the address changes.

## 1. Create the folders

1. **File Station** → `docker` shared folder → create the folder **`teampulse`**. Container Manager creates the `docker` shared folder if it doesn't exist.
2. Inside `teampulse`, create three empty folders: **`postgres`**, **`backups`**, **`files`**.
3. Download `docker-compose.yml` and `.env.example` from https://github.com/sachitss/teampulse and upload both into `teampulse`.

## 2. Make the secrets

On any computer with a terminal (Mac, Linux, or Windows with Git Bash), run these three commands and keep the outputs:

```bash
openssl rand -hex 32        # → DB_ADMIN_PASSWORD
openssl rand -hex 32        # → APP_DB_PASSWORD
openssl rand -base64 32     # → ENCRYPTION_KEY
```

No terminal? Use a password manager to generate 64-character passwords from **letters and digits only** for the first two. For ENCRYPTION_KEY, ask whoever set up GitHub to run the third command.

Rename `.env.example` to **`.env`** (File Station → right-click → Rename) and fill in `APP_BASE_URL` and the three secrets. You'll add `TUNNEL_TOKEN` in step 3.

> **Print the `.env` file and keep it with the director, or store it in PEACE's password manager.** If the NAS dies, you need these values to restore the backups. Losing `ENCRYPTION_KEY` means everyone has to set up two-factor again. In later phases, encrypted PAN and bank numbers can't be read back at all without it.

## 3. Create the Cloudflare Tunnel

1. Go to https://one.dash.cloudflare.com → **Networks → Tunnels → Create a tunnel** → **Cloudflared** → name it `peace-nas`.
2. On "Install and run a connector", choose **Docker** and copy the long token after `--token`. Put it in `.env` as **`TUNNEL_TOKEN=`**. Don't run the command it shows; Container Manager does that.
3. **Public hostname:**
   - subdomain `teampulse`, domain `peace.com.np` (yours)
   - Service **HTTP**, URL **`app:3000`**
   - Save.

   `APP_BASE_URL` in `.env` must be exactly this address with `https://`, for example `https://teampulse.peace.com.np`.
4. Recommended: **SSL/TLS → Edge Certificates → Always Use HTTPS: On** and **Minimum TLS version 1.2**.

Optional extra lock: **Zero Trust → Access → Applications** can require a one-time email code from @peace.com.np addresses before the sign-in page even shows. This is a second gate in front of TeamPulse's own password and two-factor. It adds a step for staff every 30 days.

## 4. Start TeamPulse in Container Manager

The TeamPulse image is on GitHub's registry as `ghcr.io/sachitss/teampulse`. **One-time check:** open https://github.com/sachitss/teampulse/pkgs/container/teampulse. If it says *Private*, go to **Package settings → Danger Zone → Change visibility → Public**. The code is already public and the image contains no secrets. After that, the NAS needs no GitHub login to download it.

1. **Container Manager → Project → Create**
   - Project name: `teampulse`
   - Path: `/docker/teampulse`
   - Source: **Use existing docker-compose.yml**
2. Next → Next → **Done**. The NAS downloads the images (about 400 MB) and starts everything.
3. Wait until `teampulse-app-1` shows **healthy**. In Container → `teampulse-migrate-1` → **Log**, you should see `✔ database up to date`. It is normal for this container to show "stopped" afterwards.

If the project page shows "permission denied" on `postgres`: File Station → `docker/teampulse/postgres` → Properties → Permission → give **Everyone** read/write. The container sets its own permissions on first start.

## 5. Create the first admin

**Container Manager → Container → `teampulse-app-1` → Details → Terminal → Create**. This opens a command line inside the app. Then run:

```sh
node db/manage.mjs create-admin director@peace.com.np "Your Full Name"
```

It prints an invitation link. Open it, choose a password, sign in, and scan the two-factor QR code with an authenticator app. Admin rights need two-factor.

Then, in TeamPulse:
1. **Settings:** fill in and publish the monitoring notice (English and Nepali). Then confirm it was issued to staff. Nothing is recorded from anyone's computer until you do this **and** each person has consented.
2. **People → Add employee** for each person. Each person gets a single-use invitation link:
   - **with email set up (step 6):** the link is emailed to them.
   - **without email:** click **Create invitation link** on their page and give it to them in person or by private message. Links work once, and expire after 72 hours.
3. Give everyone the [install guide](install-guide.md).

## 6. Email (optional, recommended)

Without email, invitation and reset links are shown to the admin, and **Forgot password** tells people to ask the admin. To send email, fill in `SMTP_*` and `MAIL_FROM` in `.env`, then use **Project → teampulse → Action → Build**. That restarts the project with the new settings; the data is kept.

| Provider | SMTP_HOST | SMTP_PORT | Notes |
|---|---|---|---|
| Google Workspace / Gmail | `smtp.gmail.com` | 587 | Needs an **app password** (Google account → Security → 2-Step Verification → App passwords) |
| Microsoft 365 | `smtp.office365.com` | 587 | SMTP AUTH must be enabled for that mailbox |
| Zoho Mail | `smtp.zoho.com` | 587 | |

`MAIL_FROM` should be an address on PEACE's domain with SPF/DKIM set up, or messages will land in spam.

## 7. Backups: three copies, one off-site

1. **Nightly database dumps** go to `docker/teampulse/backups`, kept for 30 days. Check the folder now and then. Container → `teampulse-backup-1` → Log shows `backup ok` every night.
2. **Hyper Backup** (Package Center): back up the shared folder `docker/teampulse/backups`, `files` and `.env` to:
   - **off-site:** Synology C2, another NAS, Google Drive or Backblaze B2. Schedule daily at 03:00 with version rotation. Turn on client-side encryption, and store that password with the `.env` copy.
   - and a **USB disk** kept outside the office, rotated weekly if possible.

   Don't back up the `postgres` folder itself while it's running; use the dumps.
3. **Test a restore once a quarter** (below). A backup you never restored is a hope, not a backup.

### Restore a backup

For example onto a new or repaired NAS:

1. Do steps 1–4 with the **same `.env`**. Then stop the `teampulse-app-1` container.
2. Put the chosen `teampulse-YYYYMMDD-HHMM.dump` into `docker/teampulse/backups`, from Hyper Backup or the USB disk.
3. Container → `teampulse-backup-1` → Details → Terminal → Create, then run:
   ```sh
   pg_restore --clean --if-exists --no-owner -d teampulse /backups/teampulse-YYYYMMDD-HHMM.dump
   ```
4. Start `teampulse-app-1` again. In its terminal run `node db/manage.mjs migrate`, which brings an older backup up to the current version and resets the app's database password.

## 8. Updates

When a new version is ready, it is published automatically from GitHub as `ghcr.io/sachitss/teampulse:latest`. To install it:

- **Container Manager → Project → teampulse → Action → Stop**, then **Image → ghcr.io/sachitss/teampulse → Update** (or Registry → pull `latest`), then **Project → Start**. The `migrate` step updates the database by itself before the app starts.

To stay on a tested version, set `TEAMPULSE_VERSION=2026.10.29` (the date tag) in `.env` and change it on purpose. Take a manual Hyper Backup before larger updates.

## 9. Help commands

All run in **Container → `teampulse-app-1` → Details → Terminal → Create**:

| Command | When |
|---|---|
| `node db/manage.mjs status` | how many migrations and people |
| `node db/manage.mjs reset-link name@peace.com.np` | a password link for anyone, e.g. the only admin is locked out |
| `node db/manage.mjs reset-mfa name@peace.com.np` | someone lost their phone and no other admin can reset it |
| `node db/manage.mjs create-admin …` | first admin, or a second admin as a spare |

Inside TeamPulse, an admin (signed in with two-factor) can do the same from **People → person → Sign-in**: password reset link, reset two-factor, unlock. **Keep two admins** so one can always help the other.

## 10. Security notes

- No router port forwarding. If you once opened ports for DSM (5000/5001), close them. The tunnel doesn't need them.
- DSM: turn on 2-step verification for NAS admin accounts. Turn off the default `admin` account. Turn on Auto Block (Control Panel → Security → Protection).
- The containers talk to each other on a private network. PostgreSQL has no published port.
- Sign-in: passwords are stored as bcrypt hashes. An account locks for 15 minutes after 5 wrong passwords. Sessions are stored only as hashes and end after 3 days unused (12 hours for two-factor sessions). Two-factor secrets are encrypted with `ENCRYPTION_KEY`. Every sign-in is written to the audit log.

## Trouble

| Symptom | Check |
|---|---|
| Site shows a Cloudflare error 1033/502 | Is `teampulse-cloudflared-1` running? Is the tunnel hostname service exactly `http://app:3000`? |
| `migrate` stopped with an error and `app` didn't start | Read `teampulse-migrate-1` → Log. Usually a wrong `DB_ADMIN_PASSWORD` after the database was already created with another one |
| Sign-in works but you're sent back to sign-in | `APP_BASE_URL` must be the https address people actually use |
| "This link has expired" | Invitation links last 72 hours, reset links 1 hour. Create a new one |
| NAS feels slow | Container Manager → Container shows memory use. Consider the 8 GB upgrade |
