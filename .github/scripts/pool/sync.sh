#!/usr/bin/env bash
# Mirror sync + hygiene. Force-pushes this repo's HEAD to every donor
# mirror, then re-asserts each mirror's workflow state: host-runner.yml
# enabled (forks start with all workflows off), everything else disabled
# so a sync push never launches duplicate CI on donor minutes.
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
# Inputs (env): POOL_CONFIG, POOL_PAT, POOL_LIB, GITHUB_REPOSITORY — see
# allocate.sh.
set -euo pipefail

# shellcheck disable=SC1090,SC1091  # sibling lib.sh; POOL_LIB redirects it in selftest.sh
source "${POOL_LIB:-$(dirname "$0")/lib.sh}"

CONFIG="${POOL_CONFIG:-.github/pool.json}"
HOST_WF=".github/workflows/host-runner.yml"

have_pool_creds || {
  echo "no pool credentials — nothing to sync"
  exit 0
}

fail=0
while read -r d; do
  owner=$(jq -r .owner <<<"$d")
  repo=$(jq -r .repo <<<"$d")
  token_var=$(jq -r '.token_var // "POOL_PAT"' <<<"$d")
  slug="$owner/$repo"

  tok=$(pool_token "$slug" "$token_var") || {
    echo "::warning::\$$token_var is empty — no token for $slug, skipping"
    fail=1
    continue
  }

  echo "== $slug"
  if ! git push --force "https://x-access-token:$tok@github.com/$slug" "HEAD:refs/heads/main"; then
    echo "::warning::$slug: push failed"
    fail=1
    continue
  fi

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
