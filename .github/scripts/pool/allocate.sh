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
#   POOL_BILLING_YEAR   billing month to query (default: current UTC)
#   POOL_BILLING_MONTH
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
# host-runner.yml sets `run-name: host-runner <pool_label>`, which is how
# cancel_dispatched() finds the runs this allocation started.
RUN_TITLE="host-runner $LABEL"

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

# --- included-minute accounting ---------------------------------------
#
# The billing usage summary is the endpoint that still answers on
# enhanced-billing accounts; the old /settings/billing/actions returns
# nothing there, which used to leave every account ranked "unknown". It
# reports consumption, not entitlement, so the allowance comes from the
# config — the same number scripts/gam.sh takes as --included, which is
# the reference implementation for this query.
#
# product=Actions + sku=actions_linux deliberately restricts the result
# to the standard Linux meter: private repos on standard hosted Linux
# runners are the minutes this pool is about.
BILLING_API_VERSION="${POOL_BILLING_API_VERSION:-2026-03-10}"
BILLING_YEAR="${POOL_BILLING_YEAR:-$(date -u +%Y)}"
BILLING_MONTH="${POOL_BILLING_MONTH:-$((10#$(date -u +%m)))}"

# used_minutes <token> <owner> <user|org> — metered actions_linux minutes
# so far this billing month; non-zero exit when the endpoint is
# unreadable (token without the billing permission, or a transient API
# failure).
used_minutes() {
  local base out
  if [[ "$3" == "user" ]]; then
    base="/users/$2"
  else
    base="/organizations/$2"
  fi
  out=$(api "$1" GET \
    "$base/settings/billing/usage/summary?year=$BILLING_YEAR&month=$BILLING_MONTH&product=Actions&sku=actions_linux" \
    "" "$BILLING_API_VERSION" 2>/dev/null) || return 1
  jq -e '[.usageItems[]?
          | select((.product | ascii_downcase) == "actions"
                   and (.sku | ascii_downcase) == "actions_linux"
                   and (.unitType | ascii_downcase) == "minutes")
          | .grossQuantity]
         | add // 0' <<<"$out" 2>/dev/null || return 1
}

# remaining <token> <owner> <user|org> <included-minutes> — remaining
# included minutes, or -1 (unknown) when the allowance is not configured
# or the usage endpoint is unreadable.
remaining() {
  local included="$4" used
  [[ "$included" =~ ^[0-9]+$ ]] || {
    echo -1
    return
  }
  used=$(used_minutes "$1" "$2" "$3") || {
    echo -1
    return
  }
  jq -n --argjson i "$included" --argjson u "$used" \
    '[($i - $u), 0] | max | floor' 2>/dev/null || echo -1
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
# home account, sorted by rank descending. Rank is remaining minutes,
# with two exceptions that decide the cases raw minutes get wrong:
#
#   -1  unknown — sorts below every account with a readable number, so a
#       donor whose allowance nobody configured is a last resort rather
#       than a first pick.
#   -2  home below the reserve floor — sorts below even unknown, because
#       a home account that is nearly out is the whole reason the pool
#       exists: an unknown donor is worth trying, home is not.
#
# Entries are "<rank>\t<slug>\t<remaining>"; the home entry simply means
# "use ubuntu-latest", so when home leads, the pool stands down.
declare -a ORDER=()
while read -r d; do
  owner=$(jq -r .owner <<<"$d")
  repo=$(jq -r .repo <<<"$d")
  type=$(jq -r '.account_type // "org"' <<<"$d")
  included=$(jq -r '.included_minutes // "unknown"' <<<"$d")
  slug="$owner/$repo"
  tok=$(pool_token "$slug" 2>/dev/null) || {
    echo "::warning::no pool token for $slug — skipping"
    continue
  }
  rem=$(remaining "$tok" "$owner" "$type" "$included")
  if ((rem >= 0 && rem < RESERVE)); then
    echo "$slug below the reserve floor ($rem < $RESERVE min) — skipping"
    continue
  fi
  ORDER+=("$rem"$'\t'"$slug"$'\t'"$rem")
done < <(jq -c '.donors[]' "$CONFIG")

HOME_TYPE=$(jq -r '.home_account_type // "org"' "$CONFIG")
HOME_INCLUDED=$(jq -r '.home_included_minutes // "unknown"' "$CONFIG")
HOME_REM=$(remaining "$CONSUMER_TOK" "$HOME_OWNER" "$HOME_TYPE" "$HOME_INCLUDED")
HOME_RANK="$HOME_REM"
((HOME_REM >= 0 && HOME_REM < RESERVE)) && HOME_RANK=-2
ORDER+=("$HOME_RANK"$'\t'"HOME"$'\t'"$HOME_REM")
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

# Cancel host-runner runs this allocation dispatched to <owner/repo>.
# A run still queued on the donor has registered no runner yet, so
# cleanup_label finds nothing to deregister — left alone it would come
# online after the allocator has already moved on and idle out the full
# host-runner.yml timeout on the donor's minutes.
cancel_dispatched() { # <token> <owner/repo>
  local id
  while read -r id; do
    [[ -n "$id" ]] || continue
    if api "$1" POST "/repos/$2/actions/runs/$id/cancel" >/dev/null 2>&1; then
      echo "$2: cancelled dispatched host-runner run $id"
    else
      echo "::warning::$2: could not cancel host-runner run $id"
    fi
  done < <(api "$1" GET \
    "/repos/$2/actions/workflows/host-runner.yml/runs?event=workflow_dispatch&per_page=50" 2>/dev/null |
    jq -r --arg t "$RUN_TITLE" \
      '.workflow_runs[]?
       | select(.display_title == $t)
       | select(.status != "completed")
       | .id' 2>/dev/null || true)
}

# One deadline for the whole allocation, not one per donor. Each
# candidate gets whatever is left, and once the budget is gone the
# allocator falls back instead of starting another donor's clock — a
# per-donor wait multiplies by the donor count and can outlive the
# allocator job's own timeout, which would skip every `needs: allocate`
# job instead of degrading to home runners.
DEADLINE=$((SECONDS + WAIT))

for entry in "${SORTED[@]}"; do
  IFS=$'\t' read -r _rank slug rem <<<"$entry"
  if [[ "$slug" == "HOME" ]]; then
    # Home sorts last when it is below the floor, so reaching it there
    # means no donor worked out — saying it "leads" would be backwards.
    if ((HOME_RANK == -2)); then
      fallback "home account $HOME_OWNER is below the reserve floor ($rem min) and no donor could lend — home runners"
    fi
    fallback "home account $HOME_OWNER leads the pool (remaining: $rem min)"
  fi
  if ((SECONDS >= DEADLINE)); then
    echo "::warning::allocation budget of ${WAIT}s spent — not trying $slug"
    break
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
      "$(jq -nc --arg r "$ref" --arg j "$jit" --arg l "$LABEL" \
        '{ref: $r, inputs: {jit_config: $j, pool_label: $l}}')" >/dev/null || {
      ok=false
      break
    }
  done

  if $ok; then
    online=0
    while ((SECONDS < DEADLINE)); do
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

  echo "::warning::donor $slug did not produce $COUNT online runner(s) within the allocation budget"
  cleanup_label
  cancel_dispatched "$tok" "$slug"
done

fallback "no donor could provision runners — home runners"
