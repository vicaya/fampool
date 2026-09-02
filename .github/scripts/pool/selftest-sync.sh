#!/usr/bin/env bash
# Offline tests for sync.sh, specifically donor bootstrap.
#
# Same trick as selftest.sh — POOL_LIB redirects the helper library to a
# stub — plus a fake `git` on PATH, because the whole point of the
# create path is what happens *around* the first push. Every stubbed
# call is appended to one log, so a case can assert not just that a
# request was made but that it came before the push.
#
#   .github/scripts/pool/selftest-sync.sh
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
SYNC="$HERE/sync.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

CONSUMER="home-acct/fampool"

# The stub: lib.sh's three entry points, with every call logged. Repo
# existence is a file in STUB_STATE so a fork can "appear" mid-run the
# way the real one does.
cat >"$TMP/stub-lib.sh" <<'STUB'
have_pool_creds() { [[ -n "${POOL_PAT:-}" ]]; }
pool_token() {
  local var="${2:-POOL_PAT}"
  [[ -n "${!var:-}" ]] || return 1
  printf 'stub-token-%s' "$var"
}

_donor_exists() {
  [[ "$STUB_DONOR_EXISTS" == 1 || -f "$STUB_STATE/created" ]]
}

api() { # <token> <method> <path> [body]
  local method="$2" path="$3" body="${4:-}" n
  echo "$method $path${body:+ $body}" >>"$STUB_LOG"

  case "$method $path" in
    "GET /repos/$STUB_DONOR/commits"*)
      # An empty repo has no commits; the endpoint errors, and that is
      # how sync.sh recognizes an interrupted bootstrap.
      [[ "$STUB_DONOR_EMPTY" == 1 ]] && return 22
      jq -nc '[{sha: "abc123"}]'
      ;;
    "GET /repos/$STUB_DONOR")
      # A queued fork becomes visible after STUB_FORK_DELAY polls; that
      # is the only reason sync.sh polls this at all.
      if [[ -f "$STUB_STATE/forking" ]]; then
        n=$(cat "$STUB_STATE/forking")
        if ((n <= 0)); then
          rm -f "$STUB_STATE/forking"
          touch "$STUB_STATE/created"
        else
          echo $((n - 1)) >"$STUB_STATE/forking"
        fi
      fi
      _donor_exists || {
        jq -nc '{message: "Not Found"}'
        return 22
      }
      jq -nc --arg n "$STUB_DONOR" '{full_name: $n}'
      ;;
    *"/forks")
      [[ "$STUB_FORK_FAILS" == 1 ]] && return 22
      echo "$STUB_FORK_DELAY" >"$STUB_STATE/forking"
      jq -nc '{}'
      ;;
    "POST /user/repos" | "POST /orgs/"*)
      [[ "$STUB_CREATE_FAILS" == 1 ]] && return 22
      touch "$STUB_STATE/created"
      jq -nc '{}'
      ;;
    "GET /user")
      jq -nc --arg l "$STUB_LOGIN" '{login: $l}'
      ;;
    *"/actions/workflows?"*)
      jq -nc '{workflows: [
        {id: 1, path: ".github/workflows/host-runner.yml", state: "disabled_manually"},
        {id: 2, path: ".github/workflows/test.yml", state: "active"}]}'
      ;;
    *"/actions/runners"*)
      jq -nc '{runners: []}'
      ;;
    *)
      jq -nc '{}'
      ;;
  esac
}
STUB

# Fake git: logs the push into the same stream as the API calls, so
# ordering assertions work across both.
mkdir -p "$TMP/bin"
cat >"$TMP/bin/git" <<'GIT'
#!/usr/bin/env bash
echo "GIT $1 ${*: -1}" >>"$STUB_LOG"
[[ "${STUB_PUSH_FAILS:-0}" == 1 ]] && exit 1
exit 0
GIT
chmod +x "$TMP/bin/git"
PATH="$TMP/bin:$PATH"
export PATH

donor_json() { # <owner> <account_type> <token_var|-> <bootstrap>
  jq -nc --arg o "$1" --arg a "$2" --arg t "$3" --argjson b "$4" \
    '{owner: $o, repo: "fampool", account_type: $a, bootstrap: $b}
     + (if $t == "-" then {} else {token_var: $t} end)'
}

write_config() { # <donor-json>
  jq -n --argjson d "$1" \
    '{reserve_floor_minutes: 500, dispatch_confirm_seconds: 30,
      home_account_type: "user", home_included_minutes: 2000,
      donors: [$d]}' >"$TMP/pool.json"
}

defaults() {
  export POOL_PAT=stub POOL_LIB="$TMP/stub-lib.sh" POOL_CONFIG="$TMP/pool.json"
  export POOL_POLL_SECONDS=0 POOL_BOOTSTRAP_WAIT=60
  export GITHUB_REPOSITORY="$CONSUMER"
  export STUB_DONOR="donor-acct/fampool" STUB_LOGIN=donor-acct
  export STUB_DONOR_EXISTS=0 STUB_DONOR_EMPTY=0 STUB_FORK_DELAY=0
  export STUB_FORK_FAILS=0 STUB_CREATE_FAILS=0 STUB_PUSH_FAILS=0
  export STUB_LOG="$TMP/calls" STUB_STATE="$TMP/state"
  rm -rf "$STUB_STATE"
  mkdir -p "$STUB_STATE"
  : >"$STUB_LOG"
  unset DONOR_PAT
  write_config "$(donor_json donor-acct org - false)"
}

pass=0
fail=0
PROBLEM=""

note() { [[ -n "$PROBLEM" ]] || PROBLEM="$1"; }

run_sync() {
  RC=0
  OUT=$("$SYNC" 2>&1) || RC=$?
  PROBLEM=""
}

want_rc() { # <expected exit status>
  ((RC == $1)) || note "expected exit $1, got $RC"
  return 0
}

want() { # <substring that must appear in the call log>
  grep -qF -- "$1" "$STUB_LOG" || note "expected call: $1"
  return 0
}

want_not() { # <substring that must not appear in the call log>
  if grep -qF -- "$1" "$STUB_LOG"; then note "unexpected call: $1"; fi
  return 0
}

want_before() { # <earlier call> <later call>
  # The `|| a=` matters: a missing call must fail this case, not abort
  # the suite on the failed pipeline under `set -e`.
  local a b
  a=$(grep -nF -- "$1" "$STUB_LOG" | head -1 | cut -d: -f1) || a=""
  b=$(grep -nF -- "$2" "$STUB_LOG" | head -1 | cut -d: -f1) || b=""
  if [[ -z "$a" || -z "$b" ]]; then
    note "cannot order missing calls: $1 / $2"
  elif ((a >= b)); then
    note "$1 must come before $2"
  fi
  return 0
}

want_log() { # <substring that must appear in the script's output>
  grep -qF -- "$1" <<<"$OUT" || note "expected output: $1"
  return 0
}

report() { # <case name>
  if [[ -z "$PROBLEM" ]]; then
    printf 'ok    %s\n' "$1"
    ((++pass))
  else
    printf 'FAIL  %s\n      %s\n%s\n' "$1" "$PROBLEM" \
      "$(printf '      | %s\n' "${OUT//$'\n'/$'\n'      | }")"
    ((++fail))
  fi
}

PUSH="GIT push HEAD:refs/heads/main"

ENABLE_ON='/actions/permissions {"enabled":true}'
ENABLE_OFF='/actions/permissions {"enabled":false}'

# --- steady state: no bootstrap, but repo-wide Actions is re-asserted ---
# The assert is what heals a mirror whose bootstrap re-enable was lost
# to a transient failure, or whose owner toggled Actions off by hand —
# states in which the per-workflow enable would "succeed" while every
# dispatch is refused.
defaults
export STUB_DONOR_EXISTS=1
run_sync
want_rc 0
want "$PUSH"
want_not "/forks"
want_not "POST /orgs/"
want_not "$ENABLE_OFF"
want_before "$PUSH" "$ENABLE_ON"
report "existing mirror re-asserts Actions, no bootstrap"

# --- opt-in: a missing repo is not created behind your back -------------
defaults
run_sync
want_rc 1
want_log 'set "bootstrap": true to auto-create'
want_not "$PUSH"
want_not "/forks"
want_not "POST /orgs/"
report "missing repo without bootstrap warns and fails"

# --- fork: the classic-PAT path ----------------------------------------
# Forking needs one token that reads the private consumer and creates in
# the donor account, which only POOL_PAT does.
defaults
write_config "$(donor_json donor-acct org - true)"
export STUB_FORK_DELAY=2
run_sync
want_rc 0
want "POST /repos/$CONSUMER/forks"
want "\"name\":\"fampool\""
want "\"default_branch_only\":true"
want_before "/forks" "$PUSH"
# A fork starts with every workflow off, so there is nothing to bracket
# — only the steady-state re-assert appears.
want_not "$ENABLE_OFF"
want "$ENABLE_ON"
report "org donor on POOL_PAT is forked, then pushed"

defaults
write_config "$(donor_json donor-acct org - true)"
export STUB_FORK_DELAY=99 POOL_BOOTSTRAP_WAIT=0
run_sync
want_rc 1
want_log "fork did not appear"
want_not "$PUSH"
report "fork that never appears is reported, not pushed"

# --- create: the fine-grained path -------------------------------------
# A fine-grained token cannot see the consumer repo, so it cannot fork —
# but creating touches only the donor side and the push carries the
# content.
defaults
write_config "$(donor_json donor-acct org DONOR_PAT true)"
export DONOR_PAT=stub
run_sync
want_rc 0
want_not "/forks"
want "POST /orgs/donor-acct/repos"
want "\"private\":true"
# A fresh repo starts with Actions ON, so the first push has to happen
# with the repo-wide switch off or test.yml runs on donor minutes.
want_before "$ENABLE_OFF" "$PUSH"
want_before "$PUSH" "$ENABLE_ON"
report "org donor on a fine-grained token is created, push bracketed"

defaults
write_config "$(donor_json donor-acct user DONOR_PAT true)"
export DONOR_PAT=stub
run_sync
want_rc 0
want "POST /user/repos"
report "personal donor is created under the matching account"

# POST /user/repos ignores the owner and creates under whoever the token
# is, so a mismatch has to stop rather than make a repo somewhere else.
defaults
write_config "$(donor_json donor-acct user DONOR_PAT true)"
export DONOR_PAT=stub STUB_LOGIN=someone-else
run_sync
want_rc 1
want_log "refusing to create the mirror in the wrong account"
want_not "POST /user/repos"
want_not "$PUSH"
report "personal donor whose token is another account is refused"

# --- failure handling ---------------------------------------------------
# A failed first push leaves Actions OFF on purpose. The repo is still
# empty, so the next sync re-brackets the retry — re-enabling here is
# what would let that retry fire test.yml on donor minutes.
defaults
write_config "$(donor_json donor-acct org DONOR_PAT true)"
export DONOR_PAT=stub STUB_PUSH_FAILS=1
run_sync
want_rc 1
want_log "push failed"
want "$ENABLE_OFF"
want_not "$ENABLE_ON"
report "failed first push leaves Actions off for the retry"

# The second half of that story: the repo now exists but is empty, and
# the retry must be bracketed exactly like the first attempt.
defaults
write_config "$(donor_json donor-acct org DONOR_PAT true)"
export DONOR_PAT=stub STUB_DONOR_EXISTS=1 STUB_DONOR_EMPTY=1
run_sync
want_rc 0
want_not "POST /orgs/"
want_not "/forks"
want_before "$ENABLE_OFF" "$PUSH"
want_before "$PUSH" "$ENABLE_ON"
report "interrupted bootstrap is re-bracketed on retry"

# Without the opt-in, an empty repo is just a mirror someone made by
# hand: plain push, no admin-level bracket its token may not have.
defaults
write_config "$(donor_json donor-acct org DONOR_PAT false)"
export DONOR_PAT=stub STUB_DONOR_EXISTS=1 STUB_DONOR_EMPTY=1
run_sync
want_rc 0
want "$PUSH"
want_not "$ENABLE_OFF"
report "empty mirror without bootstrap gets no bracket"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
((fail == 0))
