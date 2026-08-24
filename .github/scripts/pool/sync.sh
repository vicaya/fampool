#!/usr/bin/env bash
# Mirror sync + hygiene. Force-pushes this repo's HEAD to every donor
# mirror, then re-asserts each mirror's workflow state: host-runner.yml
# enabled (forks start with all workflows off), everything else disabled
# so a sync push never launches duplicate CI on donor minutes.
#
# Both API calls are idempotent, so re-running is always safe.
#
# Inputs (env): POOL_CONFIG, POOL_PAT, POOL_LIB — see allocate.sh.
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
  slug="$owner/$repo"

  tok=$(pool_token "$slug") || {
    echo "::warning::no pool token for $slug — skipping"
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
    api "$tok" PUT "/repos/$slug/actions/workflows/$host_id/enable" >/dev/null || true
    echo "$slug: host-runner.yml enabled"
  else
    # The workflows index can lag a just-pushed file; the next run heals it.
    echo "::warning::$slug does not list $HOST_WF yet — re-run pool-sync later"
  fi

  jq -r --arg p "$HOST_WF" \
    '.workflows[] | select(.path != $p) | select(.state == "active") | [.id, .path] | @tsv' \
    <<<"$wfs" |
    while IFS=$'\t' read -r id path; do
      api "$tok" PUT "/repos/$slug/actions/workflows/$id/disable" >/dev/null || true
      echo "$slug: disabled $path"
    done
done < <(jq -c '.donors[]' "$CONFIG")

exit "$fail"
