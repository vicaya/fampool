#!/usr/bin/env bash
# Offline tests for allocate.sh.
#
# The allocator's whole job is deciding which account should run a job,
# and every one of those decisions is a GitHub API round trip — so on a
# real repo the only way to test it is to push and watch CI. Instead,
# POOL_LIB redirects the helper library to a stub that answers those
# calls from environment variables, and every branch becomes a case you
# can run on a laptop with no network, no credentials, and no repo.
#
#   .github/scripts/pool/selftest.sh
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ALLOC="$HERE/allocate.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

CONSUMER="home-acct/fampool"
DONOR="donor-acct/fampool"

# The stub: same three entry points lib.sh exposes, canned answers keyed
# off STUB_* variables. Single-quoted heredoc — it is expanded at run
# time by allocate.sh, not now.
cat >"$TMP/stub-lib.sh" <<'STUB'
have_pool_creds() { [[ -n "${POOL_PAT:-}" ]]; }
pool_token() { [[ -n "${POOL_PAT:-}" ]] || return 1; printf 'stub-token'; }

_mins() { # <remaining-minutes|unknown> — a billing payload
  if [[ "$1" == unknown ]]; then
    echo '{}' # no included_minutes: what enhanced-billing accounts return
    return
  fi
  jq -nc --argjson i 2000 --argjson u "$((2000 - $1))" \
    '{included_minutes: $i, total_minutes_used: $u}'
}

api() { # <token> <method> <path> [body]
  local path="$3" sha
  case "$path" in
    */settings/billing/actions)
      case "$path" in
        *"${STUB_DONOR%%/*}"*) _mins "$STUB_DONOR_MIN" ;;
        *) _mins "$STUB_HOME_MIN" ;;
      esac
      ;;
    */actions/runners/generate-jitconfig)
      jq -nc '{encoded_jit_config: "JIT-CONFIG-BLOB"}'
      ;;
    */actions/workflows/*/dispatches)
      echo '{}'
      ;;
    */actions/runners*)
      jq -nc --argjson n "$STUB_ONLINE" --arg l "$STUB_LABEL" \
        '{runners: [range($n) | {id: (. + 1), status: "online", labels: [{name: $l}]}]}'
      ;;
    */contents/*)
      case "$path" in
        *"$STUB_DONOR"*) sha="$STUB_DONOR_SHA" ;;
        *) sha="$STUB_CONSUMER_SHA" ;;
      esac
      [[ "$sha" == absent ]] && return 22
      jq -nc --arg s "$sha" '{sha: $s}'
      ;;
    *)
      jq -nc '{default_branch: "main"}'
      ;;
  esac
}
STUB

write_config() { # <runner_wait_seconds> <with-donor|no-donors>
  local donors='[]'
  [[ "$2" == with-donor ]] &&
    donors='[{"owner": "donor-acct", "repo": "fampool", "account_type": "org"}]'
  jq -n --argjson w "$1" --argjson d "$donors" \
    '{reserve_floor_minutes: 500, runner_wait_seconds: $w,
      home_account_type: "user", donors: $d}' >"$TMP/pool.json"
}

defaults() {
  export POOL_PAT=stub POOL_LIB="$TMP/stub-lib.sh" POOL_CONFIG="$TMP/pool.json"
  export POOL_POLL_SECONDS=1
  export GITHUB_REPOSITORY="$CONSUMER" GITHUB_RUN_ID=12345 GITHUB_RUN_ATTEMPT=1
  export STUB_DONOR="$DONOR" STUB_LABEL="pool-run-12345-1"
  export STUB_CONSUMER_SHA=abc123 STUB_DONOR_SHA=abc123
  export STUB_DONOR_MIN=1500 STUB_HOME_MIN=100 STUB_ONLINE=1
  write_config 240 with-donor
}

pass=0
fail=0

indent() { # quote a captured log under the failing case
  local s="$1"
  printf '      | %s\n' "${s//$'\n'/$'\n'      | }"
}

check() { # <case name> <expected runs_on>
  local name="$1" expected="$2" out rc got
  export GITHUB_OUTPUT="$TMP/output" GITHUB_STEP_SUMMARY="$TMP/summary"
  : >"$GITHUB_OUTPUT"
  : >"$GITHUB_STEP_SUMMARY"

  rc=0
  out=$("$ALLOC" 2>&1) || rc=$?
  got=$(sed -n 's/^runs_on=//p' "$GITHUB_OUTPUT")

  if ((rc != 0)); then
    printf 'FAIL  %s\n      allocator exited %d (it must always exit 0)\n%s' \
      "$name" "$rc" "$(indent "$out")"
    ((++fail))
  elif [[ "$got" != "$expected" ]]; then
    printf 'FAIL  %s\n      expected runs_on=%s\n      got      runs_on=%s\n%s' \
      "$name" "$expected" "${got:-<none>}" "$(indent "$out")"
    ((++fail))
  else
    printf 'ok    %-46s %s\n' "$name" "$got"
    ((++pass))
  fi
}

HOME_RUNNER='"ubuntu-latest"'
POOLED='["pool-run-12345-1"]'

# --- degradation: every shortfall must land on home runners ------------
defaults
unset POOL_PAT
check "no credentials (fork PR)" "$HOME_RUNNER"

defaults
export POOL_CONFIG="$TMP/does-not-exist.json"
check "no pool config" "$HOME_RUNNER"

defaults
export STUB_CONSUMER_SHA=absent
check "host-runner.yml absent upstream" "$HOME_RUNNER"

defaults
write_config 240 no-donors
check "no donors configured" "$HOME_RUNNER"

# The donor still leads on raw minutes here, so only the floor check can
# keep this from lending — otherwise the case would pass for the wrong
# reason (home simply outranking the donor).
defaults
export STUB_DONOR_MIN=100 STUB_HOME_MIN=50
check "donor below the reserve floor" "$HOME_RUNNER"

defaults
export STUB_DONOR_SHA=deadbeef
check "mirror host-runner.yml drifted" "$HOME_RUNNER"

defaults
export STUB_DONOR_MIN=600 STUB_HOME_MIN=1900
check "home account has the most minutes" "$HOME_RUNNER"

defaults
write_config 1 with-donor
export STUB_ONLINE=0
check "runner never comes online" "$HOME_RUNNER"

# --- lending: the pool actually hands over a runner ---------------------
defaults
check "donor leads, runner is borrowed" "$POOLED"

defaults
export STUB_DONOR_MIN=unknown STUB_HOME_MIN=unknown
check "unreadable billing still lends" "$POOLED"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
((fail == 0))
