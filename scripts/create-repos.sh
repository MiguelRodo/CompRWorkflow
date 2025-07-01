#!/usr/bin/env bash
# create-repos.sh — create GitHub repos from a list
# Requires: bash 3.2+, curl

set -euo pipefail

# ── CONFIG & ENV ────────────────────────────────────────────────────────────────
REPOS_FILE="repos-to-clone.list"

usage() {
  cat <<EOF
Usage: $0 [-f <repo-list>] [-p|--public]

  -f FILE         read lines from FILE (default: repos-to-clone.list)
  -p, --public    create repos as public (default: private)
  -h, --help      show this message and exit

Each non-blank, non-# line of <repo-list> should start with:
  owner/repo[@branch] [target_directory]
Branches and target directories are ignored.
EOF
  exit 1
}

# default: private repos
PRIVATE_FLAG=true

while [ $# -gt 0 ]; do
  case $1 in
    -f)           shift; REPOS_FILE="$1"; shift ;;
    -p|--public)  PRIVATE_FLAG=false; shift ;;
    -h|--help)    usage ;;
    *)            echo "Unknown argument: $1" >&2; usage ;;
  esac
done

[ -f "$REPOS_FILE" ] || { echo "Error: file '$REPOS_FILE' not found." >&2; exit 1; }

# ── CREDENTIALS WITH FALLBACK ────────────────────────────────────────────────────
if [ -z "${GH_TOKEN-}" ]; then
  creds=$(
    printf 'protocol=https\nhost=api.github.com\n\n' \
      | git credential fill
  )
  if ! printf '%s\n' "$creds" | grep -q '^password='; then
    creds=$(
      printf 'protocol=https\nhost=github.com\n\n' \
        | git credential fill
    )
  fi

  GH_USER=$(printf '%s\n' "$creds" | awk -F= '/^username=/ {print $2}')
  GH_TOKEN=$(printf '%s\n' "$creds" | awk -F= '/^password=/ {print $2}')
  : "${GH_TOKEN:?Could not retrieve GitHub token from credential helper}"
fi

API_URL="https://api.github.com"
AUTH_HDR="Authorization: token $GH_TOKEN"

# ── MAIN LOOP ─────────────────────────────────────────────────────────────────
while IFS= read -r line || [ -n "$line" ]; do
  # skip empty lines and comments
  case "$line" in
    ''|\#*) continue ;;
  esac

  # parse owner/repo (ignore @branch and any target-dir)
  repo_spec=${line%%[[:space:]]*}
  repo_path=${repo_spec%@*}
  owner=${repo_path%%/*}
  repo=${repo_path##*/}

  # ── EXISTENCE CHECK ──────────────────────────────────────────────────────────
  check_url="$API_URL/repos/$owner/$repo"
  status=$(curl -s -o /dev/null -w "%{http_code}" -H "$AUTH_HDR" "$check_url")
  if [ "$status" -eq 200 ]; then
    echo "Exists: $owner/$repo"
    continue
  elif [ "$status" -ne 404 ]; then
    echo "Error checking $owner/$repo (HTTP $status)"
    continue
  fi

  # ── DETERMINE CREATE ENDPOINT ────────────────────────────────────────────────
  if [ "$owner" = "$GH_USER" ]; then
    CREATE_URL="$API_URL/user/repos"
  else
    CREATE_URL="$API_URL/orgs/$owner/repos"
  fi

  # ── BUILD PAYLOAD & CREATE ───────────────────────────────────────────────────
  if $PRIVATE_FLAG; then
    payload="{\"name\":\"$repo\",\"private\":true}"
  else
    payload="{\"name\":\"$repo\",\"private\":false}"
  fi

  printf "Creating %s/%s ... " "$owner" "$repo"
  http_code=$(curl -s -w "%{http_code}" \
    -H "$AUTH_HDR" \
    -H "Content-Type: application/json" \
    -d "$payload" \
    "$CREATE_URL" \
    -o /dev/null)

  case "$http_code" in
    201) echo "done." ;;
    422) echo "already exists or invalid." ;;
    *)   echo "failed (HTTP $http_code)." ;;
  esac
done < "$REPOS_FILE"
