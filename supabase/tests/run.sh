#!/usr/bin/env bash
# Rebuilds a throw-away database from scratch and runs every SQL test.
#
#   supabase/tests/run.sh            # migrations + seeds + tests
#   supabase/tests/run.sh --no-tests # just build the database
#
# Needs a local PostgreSQL 15+ superuser. Set PSQL to override the command, e.g.
#   PSQL="psql -h localhost -U postgres" supabase/tests/run.sh
set -euo pipefail
cd "$(dirname "$0")/.."
DB=${TP_TEST_DB:-tp_test}
PSQL=${PSQL:-"runuser -u postgres -- psql"}

run_sql() {   # run_sql <db> <file...>  — each file in its own transaction, stop on first error
  local db=$1; shift
  for f in "$@"; do
    if ! cat "$f" | $PSQL -X -q -v ON_ERROR_STOP=1 -1 -d "$db" >/dev/null 2>/tmp/tp_sql_err; then
      echo "FAILED in $f"; cat /tmp/tp_sql_err; exit 1
    fi
  done
}

echo "== rebuilding $DB"
echo "drop database if exists $DB; create database $DB;" | $PSQL -X -q -d postgres >/dev/null

run_sql "$DB" tests/supabase_shim.sql
run_sql "$DB" migrations/*.sql
run_sql "$DB" seed/*.sql
echo "== migrations and seeds applied"

[[ "${1:-}" == "--no-tests" ]] && exit 0
run_sql "$DB" tests/_helpers.sql

pass=0; fail=0
for t in tests/test_*.sql; do
  if out=$(cat "$t" | $PSQL -X -q -v ON_ERROR_STOP=1 -d "$DB" 2>&1); then
    echo "PASS  $(basename "$t")"; pass=$((pass+1))
  else
    echo "FAIL  $(basename "$t")"; echo "$out" | sed 's/^/      /' | tail -15; fail=$((fail+1))
  fi
done
# Demo data round trip: loads cleanly, then removes completely.
run_sql "$DB" demo/demo_load.sql
run_sql "$DB" demo/demo_remove.sql
left=$(echo "select (select count(*) from public.profiles where is_demo) + (select count(*) from auth.users where email like '%@demo.invalid') + (select count(*) from public.holiday_calendar where is_demo);" \
       | $PSQL -X -q -At -d "$DB")
if [[ "$left" == "0" ]]; then echo "PASS  demo load + remove round trip"; pass=$((pass+1));
else echo "FAIL  demo removal left $left rows"; fail=$((fail+1)); fi

echo "== $pass passed, $fail failed"
[[ $fail -eq 0 ]]
