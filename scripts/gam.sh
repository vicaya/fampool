#!/usr/bin/env bash
set -euo pipefail

# Check GitHub Actions included-minute usage.
#
# Assumptions:
#   - private repositories only
#   - standard GitHub-hosted Linux runners only
#   - INCLUDED is known (typically 2000 or 3000)
#
# Examples:
#
#   GITHUB_TOKEN=github_pat_... \
#     ./github-actions-minutes.sh --user alice --included 3000
#
#   GITHUB_TOKEN=github_pat_... \
#     ./github-actions-minutes.sh --org acme --included 3000
#
# Test a specific token environment variable:
#
#   GH_TOKEN_TEST=github_pat_... \
#     ./github-actions-minutes.sh \
#       --org acme \
#       --included 3000 \
#       --token-env GH_TOKEN_TEST
#
# Query a different month:
#
#   ./github-actions-minutes.sh \
#     --user alice \
#     --included 3000 \
#     --year 2026 \
#     --month 7

API_VERSION="${API_VERSION:-2026-03-10}"
YEAR="$(date -u +%Y)"
MONTH="$((10#$(date -u +%m)))"
TOKEN_ENV="GITHUB_TOKEN"

ACCOUNT_TYPE=""
ACCOUNT=""
INCLUDED=""

usage() {
  cat <<EOF
Usage:
  $0 --org ORG --included MINUTES [options]
  $0 --user USER --included MINUTES [options]

Options:
  --org NAME          Organization account
  --user NAME         Personal account
  --included N        Known monthly included minutes
  --year YYYY         Billing year (default: current year)
  --month M           Billing month (default: current month)
  --token-env NAME    Environment variable containing token
                      (default: GITHUB_TOKEN)
  -h, --help          Show help

Examples:
  GITHUB_TOKEN=... $0 --user alice --included 3000
  GITHUB_TOKEN=... $0 --org acme --included 3000
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --org)
      ACCOUNT_TYPE="org"
      ACCOUNT="${2:?missing organization}"
      shift 2
      ;;
    --user)
      ACCOUNT_TYPE="user"
      ACCOUNT="${2:?missing username}"
      shift 2
      ;;
    --included)
      INCLUDED="${2:?missing included minutes}"
      shift 2
      ;;
    --year)
      YEAR="${2:?missing year}"
      shift 2
      ;;
    --month)
      MONTH="${2:?missing month}"
      shift 2
      ;;
    --token-env)
      TOKEN_ENV="${2:?missing environment variable name}"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

if [[ -z "$ACCOUNT_TYPE" || -z "$ACCOUNT" || -z "$INCLUDED" ]]; then
  usage >&2
  exit 2
fi

if ! [[ "$INCLUDED" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
  echo "error: --included must be a number" >&2
  exit 2
fi

if ! [[ "$MONTH" =~ ^[0-9]+$ ]] ||
   (( MONTH < 1 || MONTH > 12 )); then
  echo "error: invalid month: $MONTH" >&2
  exit 2
fi

for cmd in curl jq; do
  command -v "$cmd" >/dev/null 2>&1 || {
    echo "error: $cmd is required" >&2
    exit 1
  }
done

TOKEN="${!TOKEN_ENV:-}"

if [[ -z "$TOKEN" ]]; then
  echo "error: \$$TOKEN_ENV is not set" >&2
  exit 1
fi

case "$ACCOUNT_TYPE" in
  org)
    BASE_PATH="/organizations/$ACCOUNT"
    EXPECTED_PERMISSION="Organization Administration: read"
    ;;
  user)
    BASE_PATH="/users/$ACCOUNT"
    EXPECTED_PERMISSION="Account Plan: read"
    ;;
esac

# product=Actions + sku=actions_linux deliberately restricts the result
# to the standard Linux Actions meter under the assumptions above.
URL="https://api.github.com${BASE_PATH}/settings/billing/usage/summary"
URL+="?year=${YEAR}&month=${MONTH}"
URL+="&product=Actions&sku=actions_linux"

tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT

headers="$tmpdir/headers"
body="$tmpdir/body"

status="$(
  curl \
    --silent \
    --show-error \
    --location \
    --output "$body" \
    --dump-header "$headers" \
    --write-out '%{http_code}' \
    -H 'Accept: application/vnd.github+json' \
    -H "Authorization: Bearer $TOKEN" \
    -H "X-GitHub-Api-Version: $API_VERSION" \
    "$URL"
)"

if [[ "$status" != "200" ]]; then
  echo "GitHub billing API request failed" >&2
  echo >&2
  echo "Account:             $ACCOUNT_TYPE:$ACCOUNT" >&2
  echo "HTTP status:         $status" >&2
  echo "Expected permission: $EXPECTED_PERMISSION" >&2

  # These are especially useful when experimenting with token permissions.
  while IFS= read -r line; do
    line="${line%$'\r'}"
    case "${line,,}" in
      x-oauth-scopes:*|\
      x-accepted-oauth-scopes:*|\
      x-accepted-github-permissions:*)
        echo "$line" >&2
        ;;
    esac
  done < "$headers"

  echo >&2
  jq -r '.message // .' "$body" >&2 2>/dev/null || cat "$body" >&2
  exit 1
fi

# Sanity-check exactly what GitHub returned.
#
# We deliberately use grossQuantity:
#
#   grossQuantity = actual metered Linux runner minutes
#
# Under the assumptions:
#   private repos + standard Linux runners only
#
# those are exactly the minutes drawing against the included allowance.
used="$(
  jq '
    [
      .usageItems[]
      | select(
          (.product | ascii_downcase) == "actions"
          and (.sku | ascii_downcase) == "actions_linux"
          and (.unitType | ascii_downcase) == "minutes"
        )
      | .grossQuantity
    ]
    | add // 0
  ' "$body"
)"

jq -n \
  --arg accountType "$ACCOUNT_TYPE" \
  --arg account "$ACCOUNT" \
  --argjson year "$YEAR" \
  --argjson month "$MONTH" \
  --argjson included "$INCLUDED" \
  --argjson used "$used" \
  '
  {
    accountType: $accountType,
    account: $account,
    year: $year,
    month: $month,
    includedMinutes: $included,
    usedMinutes: $used,
    remainingMinutes: ([($included - $used), 0] | max),
    overageMinutes: ([($used - $included), 0] | max),
    percentUsed: (
      if $included > 0
      then (($used / $included) * 100)
      else null
      end
    )
  }
  '
