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
INCLUDED=2000 # the allowance every stubbed account is configured with

# The stub: same three entry points lib.sh exposes, canned answers keyed
# off STUB_* variables. Single-quoted heredoc — it is expanded at run
# time by allocate.sh, not now.
cat >"$TMP/stub-lib.sh" <<'STUB'
have_pool_creds() { [[ -n "${POOL_PAT:-}" ]]; }
pool_token() { [[ -n "${POOL_PAT:-}" ]] || return 1; printf 'stub-token'; }

_usage() { # <remaining-minutes|unknown> — a billing usage-summary payload
  if [[ "$1" == unknown ]]; then
    # What an account whose billing the token cannot read returns: an
    # error status, which api() turns into a non-zero exit.
    return 22
  fi
  jq -nc --argjson g "$((STUB_INCLUDED - $1))" \
    '{usageItems: [{product: "Actions", sku: "actions_linux",
                    unitType: "Minutes", grossQuantity: $g}]}'
}

api() { # <token> <method> <path> [body] [api-version]
  local path="$3" sha
  case "$path" in
    */settings/billing/usage/summary*)
      case "$path" in
        *"${STUB_CONSUMER%%/*}"*) _usage "$STUB_HOME_MIN" ;;
        *) _usage "$STUB_DONOR_MIN" ;;
      esac
      ;;
    */actions/runners/generate-jitconfig)
      jq -nc '{encoded_jit_config: "JIT-CONFIG-BLOB"}'
      ;;
    */actions/workflows/*/dispatches)
      echo '{}'
      ;;
    */actions/workflows/*/runs*)
      # One dispatched run per donor, still queued: what the allocator
      # has to cancel when it gives up before a runner registers.
      jq -nc --arg t "host-runner $STUB_LABEL" \
        '{workflow_runs: [{id: 777, display_title: $t, status: "queued"}]}'
      ;;
    */actions/runs/*/cancel)
      echo "STUB-CANCELLED ${path}" >>"$STUB_CANCEL_LOG"
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

donor_json() { # <owner> [included_minutes] — one donor entry
  if [[ -n "${2:-}" ]]; then
    jq -nc --arg o "$1" --argjson i "$2" \
      '{owner: $o, repo: "fampool", account_type: "org", included_minutes: $i}'
  else
    jq -nc --arg o "$1" '{owner: $o, repo: "fampool", account_type: "org"}'
  fi
}

write_config() { # <runner_wait_seconds> <donors-json-array>
  jq -n --argjson w "$1" --argjson d "$2" --argjson i "$INCLUDED" \
    '{reserve_floor_minutes: 500, runner_wait_seconds: $w,
      home_account_type: "user", home_included_minutes: $i,
      donors: $d}' >"$TMP/pool.json"
}

defaults() {
  export POOL_PAT=stub POOL_LIB="$TMP/stub-lib.sh" POOL_CONFIG="$TMP/pool.json"
  export POOL_POLL_SECONDS=1
  export GITHUB_REPOSITORY="$CONSUMER" GITHUB_RUN_ID=12345 GITHUB_RUN_ATTEMPT=1
  export STUB_CONSUMER="$CONSUMER" STUB_DONOR="$DONOR" STUB_LABEL="pool-run-12345-1"
  export STUB_CONSUMER_SHA=abc123 STUB_DONOR_SHA=abc123
  export STUB_DONOR_MIN=1500 STUB_HOME_MIN=100 STUB_ONLINE=1
  export STUB_INCLUDED="$INCLUDED" STUB_CANCEL_LOG="$TMP/cancelled"
  : >"$STUB_CANCEL_LOG"
  write_config 240 "[$(donor_json donor-acct "$INCLUDED")]"
}

pass=0
fail=0

indent() { # quote a captured log under the failing case
  local s="$1"
  printf '      | %s\n' "${s//$'\n'/$'\n'      | }"
}

# run — executes the allocator, leaving the result in RC/OUT/GOT/ELAPSED.
run() {
  export GITHUB_OUTPUT="$TMP/output" GITHUB_STEP_SUMMARY="$TMP/summary"
  : >"$GITHUB_OUTPUT"
  : >"$GITHUB_STEP_SUMMARY"
  local start=$SECONDS
  RC=0
  OUT=$("$ALLOC" 2>&1) || RC=$?
  ELAPSED=$((SECONDS - start))
  GOT=$(sed -n 's/^runs_on=//p' "$GITHUB_OUTPUT")
}

report() { # <case name> <ok|message>
  local name="$1" problem="$2"
  if [[ -z "$problem" ]]; then
    printf 'ok    %-46s %s\n' "$name" "$GOT"
    ((++pass))
  else
    printf 'FAIL  %s\n%s%s' "$name" "$problem" "$(indent "$OUT")"
    ((++fail))
  fi
}

verdict() { # <expected runs_on> — "" when the run decided correctly
  if ((RC != 0)); then
    printf '      allocator exited %d (it must always exit 0)\n' "$RC"
  elif [[ "$GOT" != "$1" ]]; then
    printf '      expected runs_on=%s\n      got      runs_on=%s\n' \
      "$1" "${GOT:-<none>}"
  fi
}

check() { # <case name> <expected runs_on>
  run
  report "$1" "$(verdict "$2")"
}

check_within() { # <case name> <expected runs_on> <max seconds>
  run
  local problem
  problem="$(verdict "$2")"
  if [[ -z "$problem" ]] && ((ELAPSED > $3)); then
    problem=$(printf '      took %ds; the whole allocation must fit in %ds\n' \
      "$ELAPSED" "$3")
  fi
  report "$1" "$problem"
}

check_cancelled() { # <case name> <expected runs_on> <expected cancel count>
  run
  local problem seen
  problem="$(verdict "$2")"
  seen=$(grep -c . "$STUB_CANCEL_LOG" || true)
  if [[ -z "$problem" ]] && ((seen != $3)); then
    problem=$(printf '      cancelled %d dispatched donor run(s), expected %d\n' \
      "$seen" "$3")
  fi
  report "$1" "$problem"
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
write_config 240 '[]'
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

# An unknown donor is a gamble; a home account with minutes to spare is
# not, so home still wins when it is comfortably above the floor.
defaults
export STUB_DONOR_MIN=unknown STUB_HOME_MIN=1900
check "unknown donor loses to a healthy home" "$HOME_RUNNER"

defaults
write_config 1 "[$(donor_json donor-acct "$INCLUDED")]"
export STUB_ONLINE=0
check "runner never comes online" "$HOME_RUNNER"

# --- lending: the pool actually hands over a runner ---------------------
defaults
check "donor leads, runner is borrowed" "$POOLED"

defaults
export STUB_DONOR_MIN=unknown STUB_HOME_MIN=unknown
check "unreadable billing still lends" "$POOLED"

# The case the ranking exists for: home is nearly out — which is the
# whole reason to pool — and the only donor's billing is unreadable.
# Ranking on raw minutes would hand this to home at any value.
defaults
export STUB_DONOR_MIN=unknown STUB_HOME_MIN=100
check "unknown donor beats an exhausted home" "$POOLED"

# Same, with the allowance simply left out of pool.json rather than the
# endpoint failing: both read as unknown and neither may strand a job.
defaults
write_config 240 "[$(donor_json donor-acct)]"
export STUB_HOME_MIN=100
check "donor with no configured allowance still lends" "$POOLED"

# --- budgets and cleanup ------------------------------------------------
# runner_wait_seconds is the budget for the whole allocation, not per
# donor: three dead donors at 3s must still fall back in about 3s, not
# 9s. Left per-donor it scales with the donor count and can outlive the
# allocator job's own timeout — which skips every `needs: allocate` job
# instead of degrading to home runners.
defaults
write_config 3 "[$(donor_json d1 "$INCLUDED"),$(donor_json d2 "$INCLUDED"),$(donor_json d3 "$INCLUDED")]"
export STUB_ONLINE=0
check_within "three dead donors share one wait budget" "$HOME_RUNNER" 6

# A donor that never registers a runner may still have a queued job
# holding its minutes, so giving up on it has to cancel the dispatch.
defaults
write_config 1 "[$(donor_json donor-acct "$INCLUDED")]"
export STUB_ONLINE=0
check_cancelled "abandoned dispatch is cancelled" "$HOME_RUNNER" 1

printf '\n%d passed, %d failed\n' "$pass" "$fail"
((fail == 0))
