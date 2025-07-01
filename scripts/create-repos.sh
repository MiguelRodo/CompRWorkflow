#!/usr/bin/env bash
# create-repos.sh — create GitHub repos (with branches) from a list
# Requires: bash 3.2+, curl

set -euo pipefail

# ── CONFIG & USAGE ─────────────────────────────────────────────────────────────
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

PRIVATE_FLAG=true
while [ $# -gt 0 ]; do
  case $1 in
    -f)           shift; REPOS_FILE="$1"; shift ;;
    -p|--public)  PRIVATE_FLAG=false; shift ;;
    -h|--help)    usage ;;
    *)            echo "Unknown argument: $1" >&2; usage ;;
  esac
done

[ -f "$REPOS_FILE" ] || { echo "Error: '$REPOS_FILE' not found." >&2; exit 1; }

# ── CREDENTIALS ────────────────────────────────────────────────────────────────
if [ -z "${GH_TOKEN-}" ]; then
  creds=$( printf 'protocol=https\nhost=api.github.com\n\n' | git credential fill )
  if ! printf '%s\n' "$creds" | grep -q '^password='; then
    creds=$( printf 'protocol=https\nhost=github.com\n\n' | git credential fill )
  fi
  GH_USER=$(printf '%s\n' "$creds" | awk -F= '/^username=/ {print $2}')
  GH_TOKEN=$(printf '%s\n' "$creds" | awk -F= '/^password=/ {print $2}')
  : "${GH_TOKEN:?Could not retrieve GitHub token from credential helper}"
fi

API_URL="https://api.github.com"
AUTH_HDR="Authorization: token $GH_TOKEN"

# JSON literal for private field
if $PRIVATE_FLAG; then JSON_PRIVATE=true; else JSON_PRIVATE=false; fi

# ── FUNCTIONS ──────────────────────────────────────────────────────────────────
# Fetch a repo field via the API
api_get_field() {
  local url=$1 field=$2
  # simple grep+sed extractor; expects '"field": "value"'
  curl -s -H "$AUTH_HDR" "$url" \
    | grep -m1 "\"$field\"" \
    | sed -E "s/.*\"$field\": *\"([^\"]+)\".*/\1/"
}

# Create a branch called $2 on $1/$repo using default-branch sha
create_branch() {
  local owner=$1 repo=$2 newbr=$3
  # get default branch name
  local defbr defsha
  defbr=$( api_get_field "$API_URL/repos/$owner/$repo" default_branch )
  defsha=$( curl -s -H "$AUTH_HDR" \
    "$API_URL/repos/$owner/$repo/git/ref/heads/$defbr" \
    | grep -m1 '"sha"' \
    | sed -E 's/.*"sha": *"([^"]+)".*/\1/' )
  # create new ref
  curl -s -o /dev/null -w "%{http_code}" -X POST \
    -H "$AUTH_HDR" -H "Content-Type: application/json" \
    -d "{\"ref\":\"refs/heads/$newbr\",\"sha\":\"$defsha\"}" \
    "$API_URL/repos/$owner/$repo/git/refs"
}

# ── MAIN LOOP ─────────────────────────────────────────────────────────────────
while IFS= read -r line || [ -n "$line" ]; do
  # skip blanks/comments
  case "$line" in ''|\#*) continue ;; esac

  # parse owner/repo[@branch]
  repo_spec=${line%%[[:space:]]*}
  repo_path=${repo_spec%@*}
  owner=${repo_path%%/*}
  repo=${repo_path##*/}
  # detect branch if present
  if [[ "$repo_spec" == *@* ]]; then
    branch=${repo_spec##*@}
  else
    branch=""
  fi

  # ── REPO EXISTENCE CHECK ─────────────────────────────────────────────────────
  status=$( curl -s -o /dev/null -w "%{http_code}" \
              -H "$AUTH_HDR" \
              "$API_URL/repos/$owner/$repo" )
  if [ "$status" -eq 200 ]; then
    echo "Exists: $owner/$repo"
  elif [ "$status" -eq 404 ]; then
    # choose create endpoint
    if [ "$owner" = "$GH_USER" ]; then
      create_url="$API_URL/user/repos"
    else
      create_url="$API_URL/orgs/$owner/repos"
    fi
    # build payload (auto_init only if we need to push a branch later)
    if [ -n "$branch" ]; then
      payload="{\"name\":\"$repo\",\"private\":$JSON_PRIVATE,\"auto_init\":true}"
    else
      payload="{\"name\":\"$repo\",\"private\":$JSON_PRIVATE}"
    fi
    # create repo
    printf "Creating repo %s/%s ... " "$owner" "$repo"
    http_code=$( curl -s -w "%{http_code}" -H "$AUTH_HDR" \
                   -H "Content-Type: application/json" \
                   -d "$payload" \
                   "$create_url" \
                   -o /dev/null )
    if [ "$http_code" -eq 201 ]; then
      echo "done."
    else
      echo "failed (HTTP $http_code)."
      continue
    fi
  else
    echo "Error checking $owner/$repo (HTTP $status)."
    continue
  fi

  # ── BRANCH CHECK / CREATION ─────────────────────────────────────────────────
  if [ -n "$branch" ]; then
    # see if branch exists
    ref_status=$( curl -s -o /dev/null -w "%{http_code}" \
                   -H "$AUTH_HDR" \
                   "$API_URL/repos/$owner/$repo/git/refs/heads/$branch" )
    if [ "$ref_status" -eq 200 ]; then
      echo "Branch exists: $branch"
    elif [ "$ref_status" -eq 404 ]; then
      printf "Creating branch %s ... " "$branch"
      code=$( create_branch "$owner" "$repo" "$branch" )
      if [ "$code" -eq 201 ]; then
        echo "done."
      else
        echo "failed (HTTP $code)."
      fi
    else
      echo "Error checking branch $branch (HTTP $ref_status)."
    fi
  fi

done < "$REPOS_FILE"
