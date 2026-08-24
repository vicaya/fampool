#!/usr/bin/env bash
# Pool allocator. Picks the account with the most remaining included
# minutes, mints a single-use JIT runner config against this repo,
# dispatches the donor mirror's host-runner.yml, waits for the runner to
# register, and emits a `runs_on` value for downstream jobs to consume.
#
# Every shortfall degrades to "ubuntu-latest" on the home account rather
# than failing: no credentials (fork PRs see no secrets), no config, a
# missing or drifted host-runner.yml, every donor below the reserve
# floor, or runners that never come online. CI never breaks because the
# pool is empty.
#
# Inputs (env):
#   COUNT               runners to provision (default 1)
#   POOL_CONFIG         config path (default .github/pool.json)
#   POOL_PAT            credentials, see lib.sh
#   POOL_POLL_SECONDS   runner poll interval (default 10; 0 in tests)
#   POOL_LIB            helper library path (default: sibling lib.sh)
#   GITHUB_*            standard Actions variables
set -euo pipefail

# shellcheck disable=SC1090,SC1091  # sibling lib.sh; POOL_LIB redirects it in selftest.sh
source "${POOL_LIB:-$(dirname "$0")/lib.sh}"

CONFIG="${POOL_CONFIG:-.github/pool.json}"
CONSUMER="$GITHUB_REPOSITORY"
HOME_OWNER="${CONSUMER%%/*}"
COUNT="${COUNT:-1}"
POLL="${POOL_POLL_SECONDS:-10}"
LABEL="pool-run-${GITHUB_RUN_ID}-${GITHUB_RUN_ATTEMPT:-1}"
HOST_WF=".github/workflows/host-runner.yml"

emit() { # <runs-on JSON> <reason>
  echo "runs_on=$1" >>"$GITHUB_OUTPUT"
  echo "**Pool allocator:** $2 → \`$1\`" >>"$GITHUB_STEP_SUMMARY"
  echo "pool-allocate: $2 -> $1"
}

fallback() {
  emit '"ubuntu-latest"' "$1"
  exit 0
}

have_pool_creds ||
  fallback "no pool credentials in this run (fork PR or unconfigured) — home runners"
[[ -f "$CONFIG" ]] || fallback "no $CONFIG — home runners"

RESERVE=$(jq -r '.reserve_floor_minutes // 500' "$CONFIG")
WAIT=$(jq -r '.runner_wait_seconds // 240' "$CONFIG")

CONSUMER_TOK=$(pool_token "$CONSUMER") ||
  fallback "cannot mint a token for $CONSUMER"

# The mirrors serve runner code from their own copy of host-runner.yml,
# so the allocator compares theirs against this repo's before trusting
# them. No copy upstream means the pool is not live yet.
UPSTREAM_SHA=$(api "$CONSUMER_TOK" GET "/repos/$CONSUMER/contents/$HOST_WF" 2>/dev/null |
  jq -er .sha) || fallback "$HOST_WF missing on the default branch"

# remaining <token> <owner> <user|org> — remaining included minutes;
# -1 (unknown) when the endpoint is unreadable, which happens on
# enhanced-billing accounts and with tokens lacking the plan scope.
remaining() {
  local path out
  if [[ "$3" == "user" ]]; then
    path="/users/$2/settings/billing/actions"
  else
    path="/orgs/$2/settings/billing/actions"
  fi
  out=$(api "$1" GET "$path" 2>/dev/null) || {
    echo -1
    return
  }
  jq -r 'if .included_minutes != null
         then ((.included_minutes - .total_minutes_used) | floor)
         else -1 end' <<<"$out" 2>/dev/null || echo -1
}

blob_sha() { # <token> <owner/repo> — sha of host-runner.yml, or "absent"
  local out
  out=$(api "$1" GET "/repos/$2/contents/$HOST_WF" 2>/dev/null) || {
    echo absent
    return
  }
  jq -r '.sha // "absent"' <<<"$out"
}

# Candidate order: every donor at or above the reserve floor, plus the
# home account, sorted by remaining minutes descending. Unknown (-1)
# sorts last, and the home entry simply means "use ubuntu-latest" — so
# when home leads, the pool stands down.
declare -a ORDER=()
while read -r d; do
  owner=$(jq -r .owner <<<"$d")
  repo=$(jq -r .repo <<<"$d")
  type=$(jq -r '.account_type // "org"' <<<"$d")
  slug="$owner/$repo"
  tok=$(pool_token "$slug" 2>/dev/null) || {
    echo "::warning::no pool token for $slug — skipping"
    continue
  }
  rem=$(remaining "$tok" "$owner" "$type")
  if ((rem >= 0 && rem < RESERVE)); then
    echo "$slug below the reserve floor ($rem < $RESERVE min) — skipping"
    continue
  fi
  ORDER+=("$rem"$'\t'"$slug")
done < <(jq -c '.donors[]' "$CONFIG")

HOME_TYPE=$(jq -r '.home_account_type // "org"' "$CONFIG")
HOME_REM=$(remaining "$CONSUMER_TOK" "$HOME_OWNER" "$HOME_TYPE")
ORDER+=("$HOME_REM"$'\t'"HOME")
mapfile -t SORTED < <(printf '%s\n' "${ORDER[@]}" | sort -s -t$'\t' -k1,1nr)

# Deregister runners carrying this run's label so an abandoned donor job
# stops waiting for work instead of idling on the donor's minutes.
cleanup_label() {
  api "$CONSUMER_TOK" GET "/repos/$CONSUMER/actions/runners?per_page=100" 2>/dev/null |
    jq -r --arg l "$LABEL" \
      '.runners[] | select(any(.labels[]; .name == $l)) | .id' |
    while read -r id; do
      api "$CONSUMER_TOK" DELETE "/repos/$CONSUMER/actions/runners/$id" >/dev/null || true
    done
}

for entry in "${SORTED[@]}"; do
  rem="${entry%%$'\t'*}"
  slug="${entry#*$'\t'}"
  if [[ "$slug" == "HOME" ]]; then
    fallback "home account $HOME_OWNER leads the pool (remaining: $rem min)"
  fi
  echo "trying donor $slug (remaining: $rem min)"
  tok=$(pool_token "$slug")

  # Refuse a mirror whose host-runner.yml differs from this repo's: it
  # would serve runner code nobody here reviewed. The sync job heals it.
  mirror_sha=$(blob_sha "$tok" "$slug")
  if [[ "$mirror_sha" != "$UPSTREAM_SHA" ]]; then
    echo "::warning::$slug host-runner.yml drifted or absent (sync pending?) — skipping"
    continue
  fi

  ref=$(api "$tok" GET "/repos/$slug" | jq -er .default_branch) || continue
  ok=true
  for i in $(seq 1 "$COUNT"); do
    jit=$(api "$CONSUMER_TOK" POST \
      "/repos/$CONSUMER/actions/runners/generate-jitconfig" \
      "$(jq -nc \
        --arg n "pool-$GITHUB_RUN_ID-${GITHUB_RUN_ATTEMPT:-1}-$i" \
        --arg l "$LABEL" \
        '{name: $n, runner_group_id: 1, labels: ["fampool", $l]}')" |
      jq -er .encoded_jit_config) || {
      ok=false
      break
    }
    api "$tok" POST "/repos/$slug/actions/workflows/host-runner.yml/dispatches" \
      "$(jq -nc --arg r "$ref" --arg j "$jit" \
        '{ref: $r, inputs: {jit_config: $j}}')" || {
      ok=false
      break
    }
  done

  if $ok; then
    deadline=$((SECONDS + WAIT))
    online=0
    while ((SECONDS < deadline)); do
      online=$(api "$CONSUMER_TOK" GET \
        "/repos/$CONSUMER/actions/runners?per_page=100" 2>/dev/null |
        jq --arg l "$LABEL" \
          '[.runners[]
            | select(any(.labels[]; .name == $l))
            | select(.status == "online")] | length') || online=0
      ((online >= COUNT)) && break
      sleep "$POLL"
    done
    if ((online >= COUNT)); then
      emit "[\"$LABEL\"]" "$COUNT runner(s) lent by $slug (remaining before run: $rem min)"
      exit 0
    fi
  fi

  echo "::warning::donor $slug did not produce $COUNT online runner(s) within ${WAIT}s"
  cleanup_label
done

fallback "no donor could provision runners — home runners"
