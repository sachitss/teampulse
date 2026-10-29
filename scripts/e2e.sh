#!/usr/bin/env bash
# End-to-end browser tests: fresh database with demo data → next dev on :3200 → tests → stop.
#   bash scripts/e2e.sh            (needs local PostgreSQL; see db/tests/run.sh)
#   E2E_SHOTS=/path bash scripts/e2e.sh   to save screenshots
set -euo pipefail
cd "$(dirname "$0")/.."
DB=${TP_E2E_DB:-tp_e2e}
PSQL=${PSQL:-"runuser -u postgres -- psql"}
# The app connects with its own restricted login, exactly as in production.
APP_PW=e2e-app-login-password-not-secret
URL=${TP_E2E_URL:-"postgresql://teampulse_app:$APP_PW@127.0.0.1:5432/$DB"}

# E2E_EXTERNAL=1 E2E_BASE=http://host:port  → test an already-running server (e.g. the Docker
# containers in CI) whose database already has the demo data; nothing is started here.
if [[ "${E2E_EXTERNAL:-}" == "1" ]]; then
  : "${E2E_BASE:?set E2E_BASE}"
  for i in $(seq 1 60); do curl -sf -o /dev/null "$E2E_BASE/sign-in" && break; sleep 2; done
  cd web && exec node --test --test-concurrency=1 --test-timeout=120000 e2e/*.test.ts
fi

TP_TEST_DB=$DB PSQL="$PSQL" bash db/tests/run.sh --no-tests >/dev/null
cat db/demo/demo_load.sql | $PSQL -X -q -v ON_ERROR_STOP=1 -d "$DB" >/dev/null
echo "alter role teampulse_app with login password '$APP_PW';" | $PSQL -X -q -d "$DB" >/dev/null
echo "== database $DB ready"

cd web
# No SMTP settings on purpose: invitation links are shown to the admin, as on a NAS without email.
DATABASE_URL="$URL" ENCRYPTION_KEY=$(openssl rand -base64 32) APP_BASE_URL=http://localhost:3200 \
  SMTP_HOST= MAIL_FROM= \
  setsid npx next dev -p 3200 > /tmp/tp-e2e-server.log 2>&1 &
SERVER=$!
# Stop the whole process group (npx and the next-server child).
trap 'kill -- -$SERVER 2>/dev/null || true' EXIT
for i in $(seq 1 60); do curl -sf -o /dev/null http://localhost:3200/sign-in && break; sleep 1; done
# Warm up the main routes so first-compile time doesn't count against test timeouts.
for p in /sign-in /mfa /set-password /forgot-password /today /consent /settings /timesheet /approvals /projects /people /people/new; do curl -s -o /dev/null "http://localhost:3200$p"; done
echo "== server up"
node --test --test-concurrency=1 --test-timeout=120000 e2e/*.test.ts
