#!/usr/bin/env bash
set -euo pipefail

# Default-permissions JSON block
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
  -f, --file <file>       Read repos from <file> (default: repos-to-clone.list).
  -r, --repo <list>       Comma-separated repos to add (owner/repo or https://github.com/owner/repo).
                          Overrides the file.
  --permissions all       Use "permissions": "write-all".
  --permissions contents  Use "permissions": { "contents": "write" }.
  -h, --help              Show this help.
  
File entries may end in .git or @branch and may have a target directory; these parts are ignored.
Lines starting with '#' or blank lines are skipped.
EOF
}

# Globals set by parse_args()
REPOS_FILE="repos-to-clone.list"
REPOS_OVERRIDE=""
PERMISSIONS="default"

parse_args() {
  while [ "$#" -gt 0 ]; do
    case "$1" in
      -f|--file)
        shift
        [ "$#" -gt 0 ] || { echo "Missing file after -f"; usage; exit 1; }
        REPOS_FILE="$1"
        shift
        ;;
      -r|--repo)
        shift
        [ "$#" -gt 0 ] || { echo "Missing repo list after -r"; usage; exit 1; }
        REPOS_OVERRIDE="$1"
        shift
        ;;
      --permissions)
        shift
        [ "$#" -gt 0 ] || { echo "Missing type after --permissions"; usage; exit 1; }
        case "$1" in
          all)      PERMISSIONS="all" ;;
          contents) PERMISSIONS="contents" ;;
          *) echo "Unknown permissions: $1"; usage; exit 1 ;;
        esac
        shift
        ;;
      -h|--help)
        usage; exit 0
        ;;
      *)
        echo "Unknown option: $1"
        usage; exit 1
        ;;
    esac
  done
}

# Strip .git, @branch, target directories; normalise to owner/repo
normalise_repo() {
  local raw="$1"
  # take first whitespace-separated token
  raw="${raw%%[[:space:]]*}"
  # strip @branch
  raw="${raw%%@*}"
  # strip trailing slash
  raw="${raw%/}"
  # if https://github.com/, remove prefix
  if [[ "$raw" == https://github.com/* ]]; then
    raw="${raw#https://github.com/}"
  fi
  # strip .git
  raw="${raw%.git}"
  printf '%s\n' "$raw"
}

# Validate the format and exclude datasets/
validate_repo() {
  local repo="$1"
  if [[ "$repo" =~ ^[^/]+/[^/]+$ && ! "$repo" =~ ^datasets/ ]]; then
    printf '%s\n' "$repo"
  else
    return 1
  fi
}

# Build REPOS_RAW array from override or file
build_raw_list() {
  REPOS_RAW=()

  if [ -n "$REPOS_OVERRIDE" ]; then
    IFS=',' read -r -a parts <<<"$REPOS_OVERRIDE"
    for p in "${parts[@]}"; do
      REPOS_RAW+=("$(normalise_repo "$p")")
    done
  else
    [ -f "$REPOS_FILE" ] || { echo "File not found: $REPOS_FILE"; exit 1; }
    while IFS= read -r line || [ -n "$line" ]; do
      case "$line" in ''|\#*) continue ;; esac
      norm="$(normalise_repo "$line")"
      REPOS_RAW+=("$norm")
    done <"$REPOS_FILE"
  fi
}

# Filter into VALID_REPOS
filter_valid_repos() {
  VALID_REPOS=()
  for raw in "${REPOS_RAW[@]}"; do
    if repo="$(validate_repo "$raw")"; then
      VALID_REPOS+=("$repo")
    else
      echo "Skipping invalid or disallowed repo: $raw" >&2
    fi
  done
  [ "${#VALID_REPOS[@]}" -gt 0 ] || { echo "No valid repos found."; exit 1; }
}

# Emit JSON for one repo
repo_json_block() {
  local repo="$1"
  case "$PERMISSIONS" in
    all)
      printf '    "%s": { "permissions": "write-all" }' "$repo"
      ;;
    contents)
      printf '    "%s": { "permissions": { "contents": "write" } }' "$repo"
      ;;
    *)
      # indent the default block by 4 spaces
      printf '    "%s": ' "$repo"
      default_permissions_block | sed 's/^/    /'
      ;;
  esac
}

# Print the final JSON structure
print_json() {
  echo "{"
  echo '  "customizations": {'
  echo '    "codespaces": {'
  echo '      "repositories": {'

  local comma=""
  for repo in "${VALID_REPOS[@]}"; do
    printf '%s\n' "$comma$(repo_json_block "$repo")"
    comma=","
  done

  echo
  echo "      }"
  echo "    }"
  echo "  }"
  echo "}"
}

main() {
  parse_args "$@"
  build_raw_list
  filter_valid_repos
  print_json
}

main "$@"
