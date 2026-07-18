#!/usr/bin/env bash
# =============================================================================
# run_isolation_tests.sh — permanent tenant-isolation security gate
# =============================================================================
# Runs every isolation test against a DB with migrations 0001-0040 applied.
# Flow: SETUP (00_fixtures.sql) → TESTS (each self-contained BEGIN…ROLLBACK) →
# CLEANUP (drop the iso_test fixture schema). Each test RAISEs NOTICE 'PASS: …'
# on success or an ASSERT exception on failure (aborts that file, non-zero).
#
# USAGE:
#   DATABASE_URL='postgres://…scratch-or-staging…' ./run_isolation_tests.sh
#
# HARD RULE: point at a LOCAL, SCRATCH, or STAGING database — NEVER production.
# =============================================================================
set -uo pipefail

: "${DATABASE_URL:?Set DATABASE_URL to a scratch/local/staging DB (never production).}"

if [[ "$DATABASE_URL" == *"frdvhmzbsmczknqtexvx"* && "${ISOLATION_ALLOW_PROD:-}" != "1" ]]; then
  echo "REFUSING: DATABASE_URL looks like the production project. Aborting." >&2
  exit 2
fi

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_tests="$here/../../supabase/tests"

echo "== Tenant Isolation Suite =="
echo "DB: ${DATABASE_URL%%\?*}"
echo "--------------------------------------------"

# ─── SETUP ───────────────────────────────────────────────────────────────
echo "  · setup: 00_fixtures.sql"
if ! psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -q -f "$here/00_fixtures.sql" >/dev/null 2>&1; then
  echo "  ❌ setup failed (00_fixtures.sql) — aborting" >&2
  exit 1
fi

# ─── TESTS ───────────────────────────────────────────────────────────────
# All NN_*.sql in this dir except the fixtures, plus the existing proven tests.
mapfile -t files < <(
  ls "$here"/*.sql 2>/dev/null | grep -v '/00_fixtures.sql$' | sort
  ls "$repo_tests"/member_verify_isolation_test.sql \
     "$repo_tests"/steward_lookup_isolation_test.sql \
     "$repo_tests"/document_pipeline_isolation_test.sql \
     "$repo_tests"/grievance_tenant_isolation_test.sql 2>/dev/null
)

pass=0; fail=0; failed_files=()
for f in "${files[@]}"; do
  name="$(basename "$f")"
  out="$(psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -q -f "$f" 2>&1)"
  if [[ $? -eq 0 ]]; then
    note="$(printf '%s\n' "$out" | grep -m1 'PASS:')"
    echo "  ✅ $name — ${note:-passed}"
    ((pass++))
  else
    echo "  ❌ $name"
    printf '%s\n' "$out" | grep -m1 -E 'FAIL:|ERROR:|ASSERT' | sed 's/^/       /'
    failed_files+=("$name"); ((fail++))
  fi
done

# ─── CLEANUP ─────────────────────────────────────────────────────────────
psql "$DATABASE_URL" -q -c 'DROP SCHEMA IF EXISTS iso_test CASCADE;' >/dev/null 2>&1
echo "  · cleanup: dropped iso_test schema"

echo "--------------------------------------------"
echo "PASS: $pass   FAIL: $fail"
if (( fail > 0 )); then
  echo "Failed: ${failed_files[*]}" >&2
  exit 1
fi
echo "All isolation tests passed — tenant boundaries hold."
