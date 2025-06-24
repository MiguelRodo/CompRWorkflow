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
FORCE_TOOL=""   # if set via -t|--tool (one of jq, python, python3, py, rscript)

# ——— Usage ————————————————————————————————————————————————
usage(){
  cat <<EOF
Usage: $0 [options]

Options:
  -f, --file <path>        Read repos from <path> (default: repos-to-clone.list)
  -r, --repo <a,b,c…>      Comma-separated repos; overrides the file
  --permissions all        Use "permissions":"write-all"
  --permissions contents   Use "permissions":{"contents":"write"}
  -t, --tool <name>        Force update mechanism: jq, python, python3, py, or Rscript (if rscript provided, it will be used as Rscript)
  -n, --dry-run            Print resulting devcontainer.json to stdout
  -h, --help               Show this help and exit

File lines may end in .git, @branch, or include a target directory; these parts are ignored.
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
        shift; [ $# -gt 0 ] || { echo "Error: Missing file" >&2; usage; }
        REPOS_FILE="$1"; shift
        ;;
      -r|--repo)
        shift; [ $# -gt 0 ] || { echo "Error: Missing repo list" >&2; usage; }
        REPOS_OVERRIDE="$1"; shift
        ;;
      --permissions)
        shift; [ $# -gt 0 ] || { echo "Error: Missing type" >&2; usage; }
        case "$1" in all) PERMISSIONS="all" ;; contents) PERMISSIONS="contents" ;;
          *) echo "Error: Unknown permissions: $1" >&2; usage ;;
        esac
        shift
        ;;
      -t|--tool)
        shift; [ $# -gt 0 ] || { echo "Error: Missing tool name" >&2; usage; }
        case "$1" in
          jq|python|python3|py|rscript|Rscript) 
            [ "$1" = "rscript" ] && FORCE_TOOL="Rscript" || FORCE_TOOL="$1"
            ;;          *) echo "Error: Unsupported tool: $1" >&2; usage ;;
        esac
        shift
        ;;
      -n|--dry-run)
        DRY_RUN=1; shift
        ;;
      -h|--help)
        usage
        ;;
      *)
        echo "Error: Unknown option: $1" >&2; usage
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

# ——— Python (or python3 / py) fallback, JSONC-aware + trailing-comma strip —————
# Usage: update_with_python <devfile> <python-cmd>
update_with_python(){
  local file="$1"
  local py_cmd="${2:-python}"
  local arr_json repos_obj

  # 1) Build the JSON array & object as jq would
  arr_json=$(build_jq_array)
  repos_obj=$(build_jq_obj "$arr_json")

  # 2) Export it so the Python process can see it
  export REPOS_JSON="$repos_obj"

  # 3) Run Python: strip comments & trailing commas, parse, merge, emit JSON
  "$py_cmd" - "$file" <<'PYCODE'
import sys, json, re, os

fname = sys.argv[1]
text = open(fname, 'r').read()

# Remove // line comments
text = re.sub(r'//.*$', '', text, flags=re.MULTILINE)
# Remove /* ... */ block comments
text = re.sub(r'/\*.*?\*/', '', text, flags=re.DOTALL)
# Remove trailing commas before } or ]
text = re.sub(r',\s*([}\]])', r'\1', text)

# Now parse clean JSON
data = json.loads(text)

# Load the new repos block from the env var
new = json.loads(os.environ['REPOS_JSON'])

# Merge into data
cs = data.setdefault('customizations', {})
cp = cs.setdefault('codespaces', {})
repos = cp.setdefault('repositories', {})
repos.update(new)

# Output the merged JSON
print(json.dumps(data, indent=2))
PYCODE
}

# In your update_devfile(), make sure you capture that stdout into the file:
# update_with_python "$DEVFILE" "$tool" > "$DEVFILE"
# echo "Updated '$DEVFILE' with $tool."




# ——— Rscript fallback (env-var merge, no duplicates) —————————————————————
update_with_rscript(){
  local file="$1"
  local arr_json repos_obj

  # Build the same JSON array & object as jq
  arr_json=$(build_jq_array)
  repos_obj=$(build_jq_obj "$arr_json")

  # Pass the JSON via env var to Rscript
  REPOS_OBJ="$repos_obj" Rscript --vanilla - "$file" <<'RSCRIPT'
library(jsonlite)

# Read args
args <- commandArgs(trailingOnly=TRUE)
file <- args[1]

# Parse the new repos block from the environment
repos_json <- Sys.getenv("REPOS_OBJ")
new <- fromJSON(repos_json)

# Load or initialise existing JSON
if (file.exists(file)) {
  data <- tryCatch(fromJSON(file), error = function(e) list())
} else {
  data <- list()
}

# Drill into nested lists, creating if missing
cs <- data$customizations;    if (is.null(cs))    cs <- list()
cp <- cs$codespaces;         if (is.null(cp))    cp <- list()
repos <- cp$repositories;    if (is.null(repos)) repos <- list()

# Merge by name (overwrite existing, no .1 duplicates)
repos[names(new)] <- new

# Rebuild and write back
cp$repositories     <- repos
cs$codespaces       <- cp
data$customizations <- cs

write_json(data, file, pretty = TRUE, auto_unbox = TRUE)
RSCRIPT

  echo "Updated '$file' with Rscript."
}

# ——— Dispatch to the first available tool ——————————————————————
update_devfile(){
  local tool=""

  # 1) Pick the forced tool or auto-detect
  if [ -n "$FORCE_TOOL" ]; then
    command -v "$FORCE_TOOL" >/dev/null 2>&1 \
      || { echo "Error: forced tool '$FORCE_TOOL' not found." >&2; exit 1; }
    tool="$FORCE_TOOL"
  else
    for candidate in jq python python3 py Rscript; do
      if command -v "$candidate" >/dev/null 2>&1; then
        tool="$candidate"; break
      fi
    done
    [ -n "$tool" ] || { echo "Error: No JSON tool found." >&2; exit 1; }
  fi

  # 2) Invoke the updater
  case "$tool" in
    jq)
      update_with_jq "$DEVFILE"
      ;;
    python|python3|py)
      if [ "$DRY_RUN" -eq 1 ]; then
        # In dry-run, just print what Python would output
        update_with_python "$DEVFILE" "$tool"
      else
        # Safely write via a temporary file, then move into place
        tmp="$(mktemp)"
        update_with_python "$DEVFILE" "$tool" > "$tmp"
        mv "$tmp" "$DEVFILE"
        echo "Updated '$DEVFILE' with $tool."
      fi
      ;;
    Rscript)
      update_with_rscript "$DEVFILE"
      ;;
  esac

  # 3) In dry-run mode, show the result
  if [ "$DRY_RUN" -eq 1 ]; then
    echo "=== DRY-RUN OUTPUT ==="
    cat "$DEVFILE"
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
