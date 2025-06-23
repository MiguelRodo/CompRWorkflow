#!/usr/bin/env bash
#
# scripts/codespaces-auth-add.sh
# Adds GitHub repo permissions into .devcontainer/devcontainer.json
# Compatible with Bash 3.2

set -euo pipefail

# ——— Defaults ———————————————————————————————————————————————
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
DEVFILE="$PROJECT_ROOT/.devcontainer/devcontainer.json"
REPOS_FILE="$PROJECT_ROOT/repos-to-clone.list"
REPOS_OVERRIDE=""
PERMISSIONS="default"    # default | all | contents
DRY_RUN=0
RAW_LIST=""
VALID_LIST=""

# ——— Usage ————————————————————————————————————————————————
usage(){
  cat <<EOF
Usage: $0 [options]

Options:
  -f, --file <path>       Read repos from <path> (default: repos-to-clone.list)
  -r, --repo <a,b,c…>     Comma-separated repos (owner/repo or https://github.com/owner/repo)
                          Overrides the file.
  --permissions all       Use "permissions":"write-all"
  --permissions contents  Use "permissions":{"contents":"write"}
  -n, --dry-run           Print resulting devcontainer.json to stdout
  -h, --help              Show this help and exit

File lines may end in .git, @branch or include a target directory; these parts are ignored.
Lines starting with ‘#’ or blank lines are skipped.
EOF
  exit 1
}

# ——— Default permissions block —————————————————————————————————
default_permissions_block(){
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

# ——— Parse CLI args ————————————————————————————————————————
parse_args(){
  while [ $# -gt 0 ]; do
    case "$1" in
      -f|--file)
        shift
        [ $# -gt 0 ] || { echo "Error: Missing file after -f" >&2; usage; }
        REPOS_FILE="$1"
        shift
        ;;
      -r|--repo)
        shift
        [ $# -gt 0 ] || { echo "Error: Missing repo list after -r" >&2; usage; }
        REPOS_OVERRIDE="$1"
        shift
        ;;
      --permissions)
        shift
        [ $# -gt 0 ] || { echo "Error: Missing type after --permissions" >&2; usage; }
        case "$1" in
          all)      PERMISSIONS="all" ;;
          contents) PERMISSIONS="contents" ;;
          *) echo "Error: Unknown permissions: $1" >&2; usage ;;
        esac
        shift
        ;;
      -n|--dry-run)
        DRY_RUN=1
        shift
        ;;
      -h|--help)
        usage
        ;;
      *)
        echo "Error: Unknown option: $1" >&2
        usage
        ;;
    esac
  done
}

# ——— Normalise a line to owner/repo —————————————————————————————
normalise(){
  local raw
  raw="${1%%[[:space:]]*}"    # drop everything after first whitespace
  raw="${raw%%@*}"            # strip @branch
  raw="${raw%/}"              # strip trailing slash
  raw="${raw%.git}"           # strip .git
  case "$raw" in
    https://github.com/*) raw="${raw#https://github.com/}" ;;
  esac
  printf '%s\n' "$raw"
}

# ——— Validate owner/repo (no datasets/) ——————————————————————————
validate(){
  case "$1" in
    [!d]*/*)    printf '%s\n' "$1" ;;  # any owner/repo not starting datasets/
    *)          return 1 ;;
  esac
}

# ——— Build RAW_LIST from override or file ————————————————————————
build_raw_list(){
  if [ -n "$REPOS_OVERRIDE" ]; then
    local IFS=','
    for repo in $REPOS_OVERRIDE; do
      RAW_LIST+=$(normalise "$repo")$'\n'
    done
  else
    [ -f "$REPOS_FILE" ] || { echo "Error: File not found: $REPOS_FILE" >&2; exit 1; }
    while IFS= read -r line || [ -n "$line" ]; do
      case "$line" in
        ''|\#*) continue ;;  # skip blank or comment
      esac
      RAW_LIST+=$(normalise "$line")$'\n'
    done <"$REPOS_FILE"
  fi
}

# ——— Filter RAW_LIST → VALID_LIST ——————————————————————————————
filter_valid_list(){
  while IFS= read -r repo; do
    [ -z "$repo" ] && continue
    if vr=$(validate "$repo"); then
      VALID_LIST+="$vr"$'\n'
    else
      echo "Skipping invalid or disallowed: $repo" >&2
    fi
  done <<<"$RAW_LIST"

  [ -n "$VALID_LIST" ] || { echo "Error: No valid repos found." >&2; exit 1; }
}

# ——— Build a newline-delimited JSON array for jq ———————————————
build_jq_array(){
  printf '%s\n' "$VALID_LIST" \
    | jq -R 'select(length>0)' \
    | jq -s .
}

# ——— Generate the per-repo permissions object via jq —————————————
build_jq_obj(){
  local arr_json="$1"
  jq -n --argjson arr "$arr_json" '
    reduce $arr[] as $repo ({}; 
      . + {
        ($repo): (
          if "'"$PERMISSIONS"'" == "all" then
            { permissions:"write-all" }
          elif "'"$PERMISSIONS"'" == "contents" then
            { permissions:{ contents:"write" } }
          else
            {
              permissions: {
                actions:  "write",
                contents: "write",
                packages: "read",
                workflows:"write"
              }
            }
          end
        )
      }
    )
  '
}

# ——— Merge into devcontainer.json (jq variant) —————————————————————
update_with_jq(){
  local file="$1"
  local arr_json repos_obj tmp

  arr_json=$(build_jq_array)
  repos_obj=$(build_jq_obj "$arr_json")

  if [ ! -f "$file" ]; then
    jq -n --argjson repos "$repos_obj" '
      { customizations:{ codespaces:{ repositories:$repos } } }
    ' >"$file"
  else
    tmp=$(mktemp)
    jq --argjson repos "$repos_obj" '
      .customizations.codespaces.repositories
        |= ( (. // {}) + $repos )
    ' "$file" >"$tmp" && mv "$tmp" "$file"
  fi

  echo "Updated '$file' with jq."
}

# ——— Python fallback ——————————————————————————————————————
update_with_python(){
  local file="$1"
  local arr_json repos_obj

  arr_json=$(build_jq_array)
  repos_obj=$(build_jq_obj "$arr_json")

  python - "$file" <<PYCODE
import json, sys
new = $repos_obj
try:
    data = json.load(open(sys.argv[1]))
except:
    data = {}
cs = data.get('customizations', {})
cp = cs.get('codespaces', {})
repos = cp.get('repositories', {})
repos.update(new)
cp['repositories'] = repos
cs['codespaces'] = cp
data['customizations'] = cs
print(json.dumps(data, indent=2))
PYCODE
}

# ——— Rscript fallback ——————————————————————————————————————
update_with_rscript(){
  local file="$1"
  local arr_json repos_obj
  arr_json=$(build_jq_array)
  repos_obj=$(build_jq_obj "$arr_json")

  Rscript - <<RSCRIPT "$file"
args <- commandArgs(trailingOnly=TRUE)
file <- args[1]
new <- jsonlite::fromJSON('$repos_obj')
if (file.exists(file)) {
  data <- tryCatch(jsonlite::fromJSON(file), error=function(e) list())
} else data <- list()
cs <- data\$customizations %||% list()
cp <- cs\$codespaces %||% list()
repos <- cp\$repositories %||% list()
repos <- c(repos, new)
cp\$repositories <- repos
cs\$codespaces <- cp
data\$customizations <- cs
jsonlite::write_json(data, file, pretty=TRUE, auto_unbox=TRUE)
RSCRIPT
}

# ——— Dispatch to the first available tool ——————————————————————
update_devfile(){
  if [ "$DRY_RUN" -eq 1 ]; then
    if command -v jq >/dev/null; then
      update_with_jq "$DEVFILE"
    elif command -v python >/dev/null; then
      update_with_python "$DEVFILE"
    elif command -v python3 >/dev/null; then
      update_with_python "$DEVFILE"
    elif command -v py >/dev/null; then
      update_with_python "$DEVFILE"
    elif command -v Rscript >/dev/null; then
      update_with_rscript "$DEVFILE"
    else
      echo "Error: No JSON tool found" >&2
      exit 1
    fi
  else
    # In-place write
    if command -v jq >/dev/null; then
      update_with_jq "$DEVFILE"
    elif command -v python >/dev/null; then
      update_with_python "$DEVFILE" > "$DEVFILE"
    elif command -v python3 >/dev/null; then
      update_with_python "$DEVFILE" > "$DEVFILE"
    elif command -v py >/dev/null; then
      update_with_python "$DEVFILE" > "$DEVFILE"
    elif command -v Rscript >/dev/null; then
      update_with_rscript "$DEVFILE"
    else
      echo "Error: No JSON tool found" >&2
      exit 1
    fi
  fi
}

# ——— Main ————————————————————————————————————————————————
main(){
  parse_args "$@"
  build_raw_list
  filter_valid_list

  echo "DEBUG: will add the following repos:" >&2
  printf '%s' "$VALID_LIST" >&2

  [ -f "$DEVFILE" ] || { echo "Error: devcontainer.json not found at $DEVFILE" >&2; exit 1; }
  update_devfile
}

main "$@"
