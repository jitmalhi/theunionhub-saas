#!/usr/bin/env bash
# =============================================================================
# run_isolation_tests.sh — permanent tenant-isolation security gate
# =============================================================================
# Runs every isolation test against a DB with migrations 0001-0040 applied.
# Each test is self-contained (BEGIN…ROLLBACK) and RAISEs NOTICE 'PASS: …' on
# success or an ASSERT exception on failure (which aborts that file, non-zero).
#
# USAGE:
#   DATABASE_URL='postgres://…scratch-or-staging…' ./run_isolation_tests.sh
#
# HARD RULE: point this at a LOCAL, SCRATCH, or STAGING database — NEVER
# production. The tests INSERT fixtures (rolled back) and SET ROLE; run them
# only where that is safe. The guard below refuses obvious prod URLs but you
# are the last line of defence.
# =============================================================================
set -uo pipefail

: "${DATABASE_URL:?Set DATABASE_URL to a scratch/local/staging DB (never production).}"

# Best-effort prod guard: refuse the known production project ref unless forced.
if [[ "$DATABASE_URL" == *"frdvhmzbsmczknqtexvx"* && "${ISOLATION_ALLOW_PROD:-}" != "1" ]]; then
  echo "REFUSING: DATABASE_URL looks like the production project. Aborting." >&2
  echo "(Isolation tests are for scratch/staging. Set ISOLATION_ALLOW_PROD=1 only if you are certain.)" >&2
  exit 2
fi

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_tests="$here/../../supabase/tests"

# The suite = the new tenant-isolation tests + the existing proven isolation
# tests (member verify / steward lookup / documents / grievances).
mapfile -t files < <(
  ls "$here"/*.sql 2>/dev/null | sort
  ls "$repo_tests"/member_verify_isolation_test.sql \
     "$repo_tests"/steward_lookup_isolation_test.sql \
     "$repo_tests"/document_pipeline_isolation_test.sql \
     "$repo_tests"/grievance_tenant_isolation_test.sql 2>/dev/null
)

pass=0; fail=0; failed_files=()
echo "== Tenant Isolation Suite =="
echo "DB: ${DATABASE_URL%%\?*}"
echo "--------------------------------------------"
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
    failed_files+=("$name")
    ((fail++))
  fi
done
echo "--------------------------------------------"
echo "PASS: $pass   FAIL: $fail"
if (( fail > 0 )); then
  echo "Failed: ${failed_files[*]}" >&2
  exit 1
fi
echo "All isolation tests passed — tenant boundaries hold."
