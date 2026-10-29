#!/usr/bin/env bash
# End-to-end browser tests: fresh database with demo data → next dev on :3200 → tests → stop.
#   bash scripts/e2e.sh            (needs local PostgreSQL; see supabase/tests/run.sh)
#   E2E_SHOTS=/path bash scripts/e2e.sh   to save screenshots
set -euo pipefail
cd "$(dirname "$0")/.."
DB=${TP_E2E_DB:-tp_e2e}
PSQL=${PSQL:-"runuser -u postgres -- psql"}
URL=${TP_E2E_URL:-"postgresql://postgres:postgres@127.0.0.1:5432/$DB"}

TP_TEST_DB=$DB PSQL="$PSQL" bash supabase/tests/run.sh --no-tests >/dev/null
cat supabase/demo/demo_load.sql | $PSQL -X -q -v ON_ERROR_STOP=1 -d "$DB" >/dev/null
echo "== database $DB ready"

cd web
DATABASE_URL="$URL" TP_DEV_AUTH=1 TP_DEV_AUTH_SECRET=$(openssl rand -hex 32) \
  NEXT_PUBLIC_SUPABASE_URL= NEXT_PUBLIC_SUPABASE_ANON_KEY= \
  setsid npx next dev -p 3200 > /tmp/tp-e2e-server.log 2>&1 &
SERVER=$!
# Stop the whole process group (npx and the next-server child).
trap 'kill -- -$SERVER 2>/dev/null || true' EXIT
for i in $(seq 1 60); do curl -sf -o /dev/null http://localhost:3200/sign-in && break; sleep 1; done
# Warm up the main routes so first-compile time doesn't count against test timeouts.
for p in /dev-login /today /consent /settings /timesheet /approvals /projects /people /people/new; do curl -s -o /dev/null "http://localhost:3200$p"; done
echo "== server up"
node --test --test-concurrency=1 --test-timeout=120000 e2e/*.test.ts
