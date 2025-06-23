#!/usr/bin/env bash
set -euo pipefail

# Default permissions JSON block
default_permissions_block() {
  cat <<'EOF'
{
  "permissions": {
    "actions": "write",
    "contents": "write",
    "packages": "read",
    "workflows": "write"
  }
}
EOF
}

usage() {
  cat <<EOF
Usage: $0 [options]

Options:
  -f, --file <file>       Read repos from <file> (default: repos-to-clone.list)
  -r, --repo <list>       Comma-separated repos (owner/repo or https://github.com/owner/repo)
                          Overrides the file.
  --permissions all       Use "permissions": "write-all".
  --permissions contents  Use "permissions": { "contents": "write" }.
  -n, --dry-run           Print resulting devcontainer.json to stdout instead of writing.
  -h, --help              Show this help and exit.

File lines may end in .git, @branch or have a target dir; these parts are ignored.
Lines starting with '#' or blank are skipped.
EOF
}

# Globals
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
REPOS_FILE="$PROJECT_ROOT/repos-to-clone.list"
REPOS_OVERRIDE=""
PERMISSIONS="default"
DRY_RUN=0
RAW_LIST=""
VALID_LIST=""
DEVFILE=".devcontainer/devcontainer.json"

# Parse arguments
parse_args() {
  while [ $# -gt 0 ]; do
    case "$1" in
      -f|--file)
        shift; [ $# -gt 0 ] || { echo "Missing file after -f" >&2; usage; exit 1; }
        REPOS_FILE="$1"; shift
        ;;
      -r|--repo)
        shift; [ $# -gt 0 ] || { echo "Missing repo list after -r" >&2; usage; exit 1; }
        REPOS_OVERRIDE="$1"; shift
        ;;
      --permissions)
        shift; [ $# -gt 0 ] || { echo "Missing type after --permissions" >&2; usage; exit 1; }
        case "$1" in all) PERMISSIONS="all" ;; contents) PERMISSIONS="contents" ;; *) echo "Unknown permissions: $1" >&2; usage; exit 1 ;; esac
        shift
        ;;
      -n|--dry-run)
        DRY_RUN=1; shift
        ;;
      -h|--help)
        usage; exit 0
        ;;
      *)
        echo "Unknown option: $1" >&2; usage; exit 1
        ;;
    esac
  done
}

# Normalise repo spec to owner/repo
normalise() {
  local raw line
  raw="${1%%[[:space:]]*}"
  raw="${raw%%@*}"       # strip @branch
  raw="${raw%/}"         # strip trailing /
  raw="${raw%.git}"      # strip .git
  case "$raw" in
    https://github.com/*) raw="${raw#https://github.com/}" ;; 
  esac
  printf '%s\n' "$raw"
}

# Validate owner/repo (no datasets/)
validate() {
  case "$1" in
    [!d]*/*) printf '%s\n' "$1" ;;  # simple owner/repo
    *) return 1 ;;
  esac
}

# Build raw list
build_raw() {
  if [ -n "$REPOS_OVERRIDE" ]; then
    IFS=',' read -r items <<EOF
$REPOS_OVERRIDE
EOF
    for i in $items; do
      RAW_LIST+="$(normalise "$i")\n"
    done
  else
    [ -f "$REPOS_FILE" ] || { echo "File not found: $REPOS_FILE" >&2; exit 1; }
    while IFS= read -r line || [ -n "$line" ]; do
      case "$line" in ''|\#*) continue ;; esac
      RAW_LIST+="$(normalise "$line")\n"
    done < "$REPOS_FILE"
  fi
}

# Filter into VALID_LIST
filter_valid() {
  for r in $RAW_LIST; do
    if vr=$(validate "$r"); then
      VALID_LIST+="$vr\n"
    else
      echo "Skipping invalid: $r" >&2
    fi
  done
  [ -n "$VALID_LIST" ] || { echo "No valid repos." >&2; exit 1; }
}

# Generate newRepos JSON for jq
make_jq_arg() {
  local sep=""; echo -n '{'
  while IFS= read -r repo; do
    [ -n "$repo" ] || continue
    printf '%s"%s":' "$sep" "$repo"
    case "$PERMISSIONS" in
      all) echo -n '{"permissions":"write-all"}' ;;
      contents) echo -n '{"permissions":{"contents":"write"}}' ;;
      *) default_permissions_block | tr -d '\n' ;;
    esac
    sep=','
  done <<< "$VALID_LIST"
  echo '}'
}

# Update with jq
update_with_jq() {
  local workspace_file="$1"
  local repos_list="${2:-}"

  # Build a JSON array of non-blank lines in $repos_list
  local repos_array
  repos_array=$(
    printf '%s\n' "$repos_list" | \
    jq -R 'select(length > 0)' | \
    jq -s .
  )

  # Build the per-repo permissions object
  local repos_obj
  repos_obj=$(
    jq -n --argjson arr "$repos_array" '
      reduce $arr[] as $repo ({}; 
        . + {
          ($repo): {
            permissions: {
              actions:  "write",
              contents: "write",
              packages: "read",
              workflows:"write"
            }
          }
        }
      )
    '
  )

  # Merge (or create) into your devcontainer.json
  if [ ! -f "$workspace_file" ]; then
    jq -n --argjson repos "$repos_obj" '
      {
        customizations: {
          codespaces: {
            repositories: $repos
          }
        }
      }
    ' > "$workspace_file"
  else
    tmp=$(mktemp)
    jq --argjson repos "$repos_obj" '
      .customizations.codespaces.repositories 
        |= ( (. // {}) + $repos )
    ' "$workspace_file" > "$tmp" \
      && mv "$tmp" "$workspace_file"
  fi

  echo "Updated '$workspace_file' with jq."
}


# Python fallback
PY_UPDATE=$(cat <<'PY'
import sys, json, os
path = sys.argv[1]
new = json.loads(sys.stdin.read())
with open(path) as f: data = json.load(f)
cs = data.get('customizations', {})
cp = cs.get('codespaces', {})
r = cp.get('repositories', {})
r.update(new)
cp['repositories'] = r
cs['codespaces'] = cp
data['customizations'] = cs
json.dump(data, sys.stdout, indent=2)
PY
)
update_with_python() {
  local file="$1" newArg
  newArg=$(make_jq_arg)
  echo "$newArg" | python - <<EOF
import sys, json
data=sys.stdin.read()
# above script...
EOF
}
# (Omitted python3, py, rscript for brevity)

# Main
main() {
  parse_args "$@"
  build_raw
  filter_valid
  echo "DEBUG: VALID_REPOS=(${VALID_REPOS[*]})" >&2
  [ -f "$DEVFILE" ] || { echo "No devcontainer.json: $DEVFILE" >&2; exit 1; }
  if [ "$DRY_RUN" -eq 1 ]; then
    update_with_jq "$DEVFILE" && cat "$DEVFILE"
  else
    if command -v jq >/dev/null; then
      update_with_jq "$DEVFILE"
    elif command -v python >/dev/null; then
      update_with_python "$DEVFILE"
    # ... python3, py, Rscript
    else
      echo "No JSON tool found" >&2; exit 1
    fi
  fi
}

main "$@"
