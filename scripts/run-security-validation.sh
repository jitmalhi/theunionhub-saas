#!/usr/bin/env bash
# =============================================================================
# run-security-validation.sh — tenant isolation validation (YOU run this)
# =============================================================================
# Runs the tenant-isolation gate against YOUR staging Supabase project and prints
# credential-free results for docs/TENANT_SECURITY_VALIDATION.md.
#
# Credential handling (by design):
#   · Reads DATABASE_URL + PROJECT_REF from the ENVIRONMENT. Nothing hardcoded.
#   · NEVER prints, logs, or stores the connection string — every logged command
#     shows the URL as ***REDACTED***.
#   · Refuses to run against the known production project ref.
#   · Requires CONFIRM_STAGING=1 so a production URL can't be used by accident.
#
# Requirements on YOUR machine:
#   · The project-local supabase CLI (run from steward-system): it will use
#     `npx --no-install supabase db query --db-url …` (no psql/Docker needed).
#   · A **direct** staging connection string (postgres role, port 5432) — the
#     tests do SET ROLE + fixture inserts, which the pooled role cannot do.
#   · An EMPTY staging database (fresh project). The script verifies this.
#
# Usage:
#   cd steward-system
#   export PROJECT_REF='your-staging-ref'
#   export DATABASE_URL='postgresql://postgres:[PW]@db.your-staging-ref.supabase.co:5432/postgres'
#   export CONFIRM_STAGING=1
#   ./scripts/run-security-validation.sh
#
# Then paste validation-results/summary.md back so the report can be updated.
# =============================================================================
set -uo pipefail

PROD_REF="frdvhmzbsmczknqtexvx"     # production project — NEVER validate against this
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root="$(cd "$here/.." && pwd)"      # steward-system
migdir="$root/supabase/migrations"
isodir="$root/tests/tenant-isolation"
legacydir="$root/supabase/tests"
out="$root/validation-results"
utc() { date -u +"%Y-%m-%dT%H:%M:%SZ"; }

# ── 1 · preconditions ───────────────────────────────────────────────────────
: "${DATABASE_URL:?Set DATABASE_URL to your STAGING direct connection string (never production).}"
: "${PROJECT_REF:?Set PROJECT_REF to your staging project ref (never the production ref).}"

if [[ "$PROJECT_REF" == "$PROD_REF" || "$DATABASE_URL" == *"$PROD_REF"* ]]; then
  echo "ABORT: target matches the PRODUCTION project ref ($PROD_REF). This script refuses production." >&2
  exit 2
fi
if [[ "${CONFIRM_STAGING:-}" != "1" ]]; then
  echo "ABORT: set CONFIRM_STAGING=1 to attest this is a disposable STAGING project." >&2
  exit 2
fi

# supabase query wrapper — the ONLY place DATABASE_URL is used; never printed.
sbq() { npx --no-install supabase db query --db-url "$DATABASE_URL" "$@"; }

# empty-DB guard
if sbq "select 1 from information_schema.tables where table_schema='public' and table_name='tenants'" 2>/dev/null | grep -q 1; then
  echo "ABORT: target already has public.tenants — not an empty database. Use a fresh staging project." >&2
  exit 2
fi

mkdir -p "$out"
CMDLOG="$out/command-log.txt"; : > "$CMDLOG"
logcmd() { echo "[$(utc)] $*" >> "$CMDLOG"; }
say()    { echo "$*"; echo "[$(utc)] $*" >> "$CMDLOG"; }

PG_VER="$(sbq 'select version()' 2>/dev/null | tr -d '\r' | grep -io 'PostgreSQL [0-9.]*' | head -1)"
COMMIT="$(git -C "$root" rev-parse --short HEAD 2>/dev/null)"
say "=== Tenant Isolation Validation ==="
say "PROJECT_REF: $PROJECT_REF (staging)   DATABASE_URL: ***REDACTED***"
say "Postgres: ${PG_VER:-unknown}   Suite commit: ${COMMIT:-unknown}   Started: $(utc)"

# ── helpers ─────────────────────────────────────────────────────────────────
apply_migrations() {           # $@ = migration files, applied in order
  for m in "$@"; do
    logcmd "supabase db query --db-url *** -f $(basename "$m")"
    if ! sbq -f "$m" >>"$out/migrate.log" 2>&1; then
      echo "ABORT: migration failed: $(basename "$m") (see validation-results/migrate.log)" >&2
      exit 1
    fi
  done
}

run_suite() {                  # $1 = phase label ; echoes "PASS FAIL" ; appends to $out/<phase>.log + RESULTS
  local phase="$1"; local ofile="$out/${phase}.log"; : > "$ofile"
  local pass=0 fail=0 name status
  sbq -f "$isodir/00_fixtures.sql" >>"$ofile" 2>&1     # setup
  local files=( "$isodir"/0[1-8]_*.sql \
    "$legacydir/member_verify_isolation_test.sql" \
    "$legacydir/steward_lookup_isolation_test.sql" \
    "$legacydir/document_pipeline_isolation_test.sql" \
    "$legacydir/grievance_tenant_isolation_test.sql" )
  for f in "${files[@]}"; do
    [ -f "$f" ] || continue
    name="$(basename "$f")"
    logcmd "supabase db query --db-url *** -f $name"
    echo "----- $name -----" >>"$ofile"
    if sbq -f "$f" >>"$ofile" 2>&1; then status="PASS"; ((pass++)); else status="FAIL"; ((fail++)); fi
    printf '%s\t%s\t%s\n' "$phase" "$name" "$status" >> "$out/results.tsv"
  done
  sbq "DROP SCHEMA IF EXISTS iso_test CASCADE;" >>"$ofile" 2>&1   # cleanup
  echo "$pass $fail"
}

: > "$out/results.tsv"

# ── 2 · BASELINE (0001–0040): prove the vulnerability is DETECTED ────────────
say ""; say "--- BASELINE: applying migrations 0001-0040 (excluding 0041) @ $(utc) ---"
baseline_migs=(); for m in "$migdir"/*.sql; do [[ "$m" == *"0041_"* ]] || baseline_migs+=("$m"); done
apply_migrations "${baseline_migs[@]}"
say "Running suite against baseline (expect 01/02/05/06/07/08 to FAIL = gap detected)…"
read base_pass base_fail < <(run_suite baseline)
say "BASELINE result: PASS=$base_pass FAIL=$base_fail"

# ── 3 · REMEDIATE (apply 0041) ───────────────────────────────────────────────
say ""; say "--- REMEDIATION: applying 0041_tenant_scope_admin_policies.sql @ $(utc) ---"
apply_migrations "$migdir/0041_tenant_scope_admin_policies.sql"

# ── 4 · FIXED (0001–0041): full validation, expect ALL PASS ──────────────────
say "Running suite against 0001-0041 (expect ALL PASS)…"
read fix_pass fix_fail < <(run_suite fixed)
say "FIXED result: PASS=$fix_pass FAIL=$fix_fail"

# ── 5 · summary.md (paste this into TENANT_SECURITY_VALIDATION.md) ────────────
SUM="$out/summary.md"
{
  echo "### Observed validation results"
  echo "- Environment: PROJECT_REF \`$PROJECT_REF\` (staging, non-production) · Postgres ${PG_VER:-?} · suite commit \`${COMMIT:-?}\`"
  echo "- Baseline migrations: 0001–0040 · Remediated: 0001–0041 · Run (UTC): $(utc)"
  echo ""
  echo "| Test | Observed @0040 | Observed @0041 |"
  echo "|---|---|---|"
  awk -F'\t' '{r[$1"|"$2]=$3; if(!seen[$2]++) order[++n]=$2} END{for(i=1;i<=n;i++){t=order[i]; printf("| %s | %s | %s |\n", t, r["baseline|"t], r["fixed|"t])}}' "$out/results.tsv"
  echo ""
  echo "- Baseline detected the gap (expected-fail tests FAILED @0040): $([ "$base_fail" -gt 0 ] && echo YES || echo NO)"
  echo "- All tests PASS @0041: $([ "$fix_fail" -eq 0 ] && echo YES || echo NO)"
  echo ""
  if [ "$fix_fail" -eq 0 ] && [ "$base_fail" -gt 0 ]; then
    echo "**GATE RESULT: PASS** — the vulnerability was detected at baseline and closed by 0041."
  else
    echo "**GATE RESULT: NOT PASSED** — investigate (baseline should FAIL the vulnerable tests; 0041 should make ALL pass). See validation-results/fixed.log."
  fi
} > "$SUM"

echo ""
echo "================================================================"
cat "$SUM"
echo "================================================================"
echo "Full logs: validation-results/{baseline.log,fixed.log,command-log.txt,migrate.log}"
echo "Paste validation-results/summary.md back to record it in TENANT_SECURITY_VALIDATION.md."
echo ""
echo "NOTE: this staging DB is now at 0001-0041. Drop/recreate the staging project when done,"
echo "and rotate the credential you used. This script never stored it."

[ "$fix_fail" -eq 0 ] && [ "$base_fail" -gt 0 ] && exit 0 || exit 1
