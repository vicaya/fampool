#!/usr/bin/env bash
# Shared helpers for the Actions minute pool. Sourced by allocate.sh and
# sync.sh; runs on GitHub-hosted runners, where curl and jq are already
# installed.
#
# Credentials: POOL_PAT, one token that can reach every participating
# account. The pool_token seam below is where a GitHub App installation
# token would be swapped in for a larger deployment (see README §Scaling).
set -euo pipefail

GH_API="${GH_API:-https://api.github.com}"

GH_API_VERSION="${GH_API_VERSION:-2022-11-28}"

# api <token> <method> <path> [json-body] [api-version] — prints the
# response body, non-zero exit on HTTP >= 400.
#
# The version argument is for endpoints that are not on the pinned
# default: the billing usage summary the allocator ranks accounts with
# only answers under 2026-03-10 (see allocate.sh remaining()).
api() {
  local token="$1" method="$2" path="$3" body="${4:-}" version="${5:-$GH_API_VERSION}"
  local args=(-sS --fail-with-body -X "$method"
    -H "Authorization: Bearer $token"
    -H "Accept: application/vnd.github+json"
    -H "X-GitHub-Api-Version: $version")
  [[ -n "$body" ]] && args+=(-d "$body")
  curl "${args[@]}" "$GH_API$path"
}

have_pool_creds() {
  [[ -n "${POOL_PAT:-}" ]]
}

# pool_token <owner/repo> — a token that can reach the given repository.
# The argument is unused with a PAT (one token reaches everything); it is
# the seam an App-based deployment mints a per-installation token from.
pool_token() {
  [[ -n "${POOL_PAT:-}" ]] || return 1
  printf '%s' "$POOL_PAT"
}
