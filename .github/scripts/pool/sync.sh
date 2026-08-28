#!/usr/bin/env bash
# Mirror sync + hygiene. Force-pushes this repo's HEAD to every donor
# mirror, then re-asserts each mirror's workflow state: host-runner.yml
# enabled (forks start with all workflows off), everything else disabled
# so a sync push never launches duplicate CI on donor minutes.
#
# A donor marked `"bootstrap": true` whose repo does not exist yet is
# created first; see bootstrap_donor below.
#
# Both API calls are idempotent, so re-running is always safe. Any donor
# left in a state the pool cannot use — push rejected, workflow list
# unreadable, host-runner.yml not enabled, another workflow still active
# — exits non-zero, so the sync job goes red instead of reporting a pool
# that is quietly not there.
#
# It also reaps orphaned JIT runner registrations on the consumer repo;
# see reap_runners below.
#
# Inputs (env): POOL_CONFIG, POOL_PAT, POOL_LIB, POOL_POLL_SECONDS,
# POOL_BOOTSTRAP_WAIT, GITHUB_REPOSITORY — see allocate.sh.
set -euo pipefail

# shellcheck disable=SC1090,SC1091  # sibling lib.sh; POOL_LIB redirects it in the selftests
source "${POOL_LIB:-$(dirname "$0")/lib.sh}"

CONFIG="${POOL_CONFIG:-.github/pool.json}"
HOST_WF=".github/workflows/host-runner.yml"
CONSUMER="${GITHUB_REPOSITORY:-}"
POLL="${POOL_POLL_SECONDS:-10}"
BOOTSTRAP_WAIT="${POOL_BOOTSTRAP_WAIT:-60}"

have_pool_creds || {
  echo "no pool credentials — nothing to sync"
  exit 0
}

# actions_enabled <token> <owner/repo> <true|false> — repository-wide
# Actions switch, the coarse one above per-workflow state.
actions_enabled() {
  api "$1" PUT "/repos/$2/actions/permissions" \
    "$(jq -nc --argjson e "$3" '{enabled: $e}')" >/dev/null && return 0
  echo "::warning::$2: could not set repository Actions enabled=$3"
  return 1
}

# bootstrap_donor <token> <owner/repo> <user|org> <token-var> <true|false>
# — make sure the donor repo exists, creating it when the donor opted in.
# Sets BOOTSTRAP to "" (it was already there), "fork", or "create"; the
# caller has to bracket the first push for "create", see below. Returns
# non-zero when this donor cannot be used at all.
#
# Which path is possible is decided by the credential, not by taste.
# Forking needs ONE token that can both read the private consumer repo
# and create in the donor account: only the classic POOL_PAT spans
# owners that way. A fine-grained PAT is bound to a single resource
# owner, so a donor's token cannot see the consumer repo at all and no
# grant width changes that. Creating touches only the donor side, and
# the content arrives through the force-push below, so that path works
# with either credential — at the cost of a wider grant ("All
# repositories" plus Administration: write, since a repo that does not
# exist yet cannot be in a selected-repositories list).
#
# Everything here is gated on the repo being absent or still empty, so
# re-running a sync never re-creates anything.
bootstrap_donor() {
  local tok="$1" slug="$2" type="$3" var="$4" want="$5"
  local owner="${slug%%/*}" name="${slug#*/}" out login path deadline
  BOOTSTRAP=""

  out=$(api "$tok" GET "/repos/$slug" 2>/dev/null) && {
    # Existing does not mean bootstrapped: a create whose first push
    # failed leaves an empty repo, and the retry is still a
    # first-content push into a repo whose Actions are on — unbracketed
    # it would fire test.yml on the donor's minutes. An empty repo has
    # no commits (the endpoint errors), so that is the test. Gated on
    # the donor's opt-in: an empty mirror made by hand, bootstrap off,
    # stays on the plain path its narrower token may require. A
    # transient error here merely brackets a push that needed no
    # bracket, which is harmless.
    if [[ "$want" == true ]] &&
      ! api "$tok" GET "/repos/$slug/commits?per_page=1" >/dev/null 2>&1; then
      echo "$slug: repo exists but is empty — finishing an interrupted bootstrap"
      BOOTSTRAP=create
    fi
    return 0
  }
  # A repo that exists but is invisible to this token also answers 404,
  # in which case the create below fails on the name and says so.
  if [[ "$(jq -r '.message // ""' <<<"$out" 2>/dev/null)" != "Not Found" ]]; then
    echo "::warning::$slug: cannot read the repo, and the error is not a 404 — skipping"
    return 1
  fi
  if [[ "$want" != true ]]; then
    echo "::warning::$slug: donor repo missing; set \"bootstrap\": true to auto-create"
    return 1
  fi

  if [[ "$var" == "POOL_PAT" && "$type" == "org" && -n "$CONSUMER" ]]; then
    echo "$slug: forking $CONSUMER"
    # `name` because the donor's repo name need not match the
    # consumer's; default_branch_only because mirrors serve one branch.
    api "$tok" POST "/repos/$CONSUMER/forks" \
      "$(jq -nc --arg o "$owner" --arg n "$name" \
        '{organization: $o, name: $n, default_branch_only: true}')" >/dev/null || {
      echo "::warning::$slug: fork request rejected"
      return 1
    }
    # Forking is asynchronous — the 202 above only means it was queued.
    deadline=$((SECONDS + BOOTSTRAP_WAIT))
    until api "$tok" GET "/repos/$slug" >/dev/null 2>&1; do
      ((SECONDS < deadline)) || {
        echo "::warning::$slug: fork did not appear within ${BOOTSTRAP_WAIT}s — re-run pool-sync"
        return 1
      }
      sleep "$POLL"
    done
    BOOTSTRAP=fork
    return 0
  fi

  if [[ "$type" == "user" ]]; then
    # POST /user/repos creates under whoever the token authenticates as,
    # so a token pointed at the wrong account would silently put the
    # mirror there instead of failing.
    login=$(api "$tok" GET "/user" 2>/dev/null | jq -r '.login // ""') || login=""
    if [[ "${login,,}" != "${owner,,}" ]]; then
      echo "::warning::$slug: \$$var authenticates as ${login:-unknown}, not $owner — refusing to create the mirror in the wrong account"
      return 1
    fi
    path="/user/repos"
  else
    path="/orgs/$owner/repos"
  fi

  echo "$slug: creating the mirror ($path)"
  # private unconditionally: these are mirrors of a private repo.
  api "$tok" POST "$path" \
    "$(jq -nc --arg n "$name" '{name: $n, private: true, auto_init: false}')" >/dev/null || {
    echo "::warning::$slug: could not create the repo"
    return 1
  }
  BOOTSTRAP=create
  return 0
}

fail=0
while read -r d; do
  owner=$(jq -r .owner <<<"$d")
  repo=$(jq -r .repo <<<"$d")
  type=$(jq -r '.account_type // "org"' <<<"$d")
  token_var=$(jq -r '.token_var // "POOL_PAT"' <<<"$d")
  bootstrap=$(jq -r 'if .bootstrap == true then "true" else "false" end' <<<"$d")
  slug="$owner/$repo"

  tok=$(pool_token "$slug" "$token_var") || {
    echo "::warning::\$$token_var is empty — no token for $slug, skipping"
    fail=1
    continue
  }

  echo "== $slug"
  bootstrap_donor "$tok" "$slug" "$type" "$token_var" "$bootstrap" || {
    fail=1
    continue
  }

  # A repo created from scratch starts with Actions *enabled*, unlike a
  # fork. Its first-content push would therefore run test.yml —
  # deliberately not owner-guarded — and every other push-triggered
  # workflow, on the donor's minutes. A push made while Actions is off
  # queues no runs, so the repo-wide switch is turned off across that
  # one push; the unconditional re-enable after the push and the
  # per-workflow pass take over from there. (This disable failing has a
  # milder shape — one unbracketed push, self-limiting — hence the hard
  # stop and nothing more.)
  if [[ "$BOOTSTRAP" == create ]]; then
    actions_enabled "$tok" "$slug" false || {
      fail=1
      continue
    }
  fi

  if ! git push --force "https://x-access-token:$tok@github.com/$slug" "HEAD:refs/heads/main"; then
    # On a bracketed repo Actions deliberately stays off here: the repo
    # is still empty, so the next sync re-detects the interrupted
    # bootstrap and brackets the retry — re-enabling now is exactly what
    # would let that retry fire workflows unbracketed.
    echo "::warning::$slug: push failed"
    fail=1
    continue
  fi

  # Repo-wide Actions is asserted on every sync for every donor, not
  # only after a bootstrap. This is both the bracket's re-enable and the
  # healing for the states nothing else detects — a re-enable lost to a
  # transient failure, or a human toggling the switch off in the
  # mirror's settings — in which the per-workflow enable below would
  # "succeed" while the allocator's dispatches are refused and sync
  # keeps reporting a healthy pool.
  actions_enabled "$tok" "$slug" true || {
    fail=1
    continue
  }

  wfs=$(api "$tok" GET "/repos/$slug/actions/workflows?per_page=100") || {
    echo "::warning::$slug: cannot list workflows"
    fail=1
    continue
  }

  host_id=$(jq -r --arg p "$HOST_WF" \
    '.workflows[] | select(.path == $p) | .id' <<<"$wfs")
  if [[ -n "$host_id" ]]; then
    # A rejected enable (token permission, org policy, a transient 5xx)
    # leaves the mirror listed as a donor but unable to host anything, so
    # it has to be reported rather than swallowed.
    if api "$tok" PUT "/repos/$slug/actions/workflows/$host_id/enable" >/dev/null; then
      echo "$slug: host-runner.yml enabled"
    else
      echo "::warning::$slug: could not enable $HOST_WF — mirror cannot host runners"
      fail=1
    fi
  else
    # Usually the workflows index lagging a just-pushed file, which the
    # next run heals — but until then the mirror cannot host anything,
    # and that is the state this job exists to report.
    echo "::warning::$slug does not list $HOST_WF yet — re-run pool-sync"
    fail=1
  fi

  # Process substitution, not a pipe: a `while` on the right of a pipe
  # runs in a subshell, where fail=1 would be lost.
  while IFS=$'\t' read -r id path; do
    if api "$tok" PUT "/repos/$slug/actions/workflows/$id/disable" >/dev/null; then
      echo "$slug: disabled $path"
    else
      echo "::warning::$slug: could not disable $path — duplicate CI may run on donor minutes"
      fail=1
    fi
  done < <(jq -r --arg p "$HOST_WF" \
    '.workflows[] | select(.path != $p) | select(.state == "active") | [.id, .path] | @tsv' \
    <<<"$wfs")
done < <(jq -c '.donors[]' "$CONFIG")

# Reap orphaned JIT runner registrations on the consumer repo.
#
# The allocator does not wait for a dispatched runner to come online, so
# its cleanup cannot catch a registration that appears after it has
# moved on — a donor job killed before it picked up work, or one that
# registered against a run that has since finished. A JIT runner that
# actually served a job deregisters itself, so anything still listed
# offline whose allocating run is over never worked.
#
# The runners endpoint reports no creation time, which is why the run id
# is read back out of the name the allocator minted
# (pool-<run_id>-<attempt>-<n>) rather than inferred from age.
reap_runners() {
  local consumer="${GITHUB_REPOSITORY:-}" tok id name run_id out
  [[ -n "$consumer" ]] || {
    echo "no GITHUB_REPOSITORY — skipping orphaned-runner reap"
    return 0
  }
  tok=$(pool_token "$consumer") || {
    echo "::warning::no POOL_PAT — skipping orphaned-runner reap"
    fail=1
    return 0
  }

  echo "== $consumer (orphaned runners)"
  while IFS=$'\t' read -r id name; do
    [[ "$name" =~ ^pool-([0-9]+)-[0-9]+-[0-9]+$ ]] || continue
    run_id="${BASH_REMATCH[1]}"

    out=$(api "$tok" GET "/repos/$consumer/actions/runs/$run_id" 2>/dev/null) || {
      # A deleted run is an orphan; anything else is a transient error,
      # and deleting a runner whose run is still live would strand it.
      [[ "$(jq -r '.message // ""' <<<"$out" 2>/dev/null)" == "Not Found" ]] || continue
      out='{"status": "completed"}'
    }
    [[ "$(jq -r '.status // ""' <<<"$out")" == "completed" ]] || continue

    if api "$tok" DELETE "/repos/$consumer/actions/runners/$id" >/dev/null; then
      echo "$consumer: reaped orphaned runner $name (run $run_id is over)"
    else
      echo "::warning::$consumer: could not delete orphaned runner $name"
      fail=1
    fi
  done < <(api "$tok" GET "/repos/$consumer/actions/runners?per_page=100" 2>/dev/null |
    jq -r '.runners[]?
           | select(.status == "offline")
           | select(.busy != true)
           | [.id, .name] | @tsv' 2>/dev/null || true)
}

reap_runners

exit "$fail"
