#!/usr/bin/env bash
# run-repos.sh — Simple, portable multi-repo “run.sh” executor

set -e

# --- Prerequisite checks ---
check_prerequisites() {
  for cmd in awk chmod; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
      echo "Error: '$cmd' is required but not found in PATH." >&2
      exit 1
    fi
  done
}

# --- Usage message ---
usage() {
  cat <<EOF
Usage: $0 [options]

Options:
  -f, --file <file>        Repo list file (default: repos.list)
  -i, --include <names>    Comma-separated list of repo names to INCLUDE
  -e, --exclude <names>    Comma-separated list of repo names to EXCLUDE
  -n, --dry-run            Show what would be done, but don't execute
  -v, --verbose            Enable verbose logging
  -h, --help               Show this message

Each line in the repo list file must be:
  repo_spec [target_directory]

where repo_spec is owner/repo[@branch] or https://host/owner/repo[@branch]
and target_directory is optional (relative to this script’s parent directory).

If a folder exists and contains run.sh, this script will make it executable
and then run it. One failing run.sh stops the process. If no run.sh is found
in any repository, you’ll get a final notice.
EOF
}

# --- parse arguments ---
parse_args() {
  if [ ! -f "repos.list" ] && [ -f "repos-to-clone.list" ]; then
    REPOS_FILE="repos-to-clone.list"
  else
    REPOS_FILE="repos.list"
  fi
  DRY_RUN=false
  VERBOSE=false
  INCLUDE_RAW=""
  EXCLUDE_RAW=""

  while [ "$#" -gt 0 ]; do
    case "$1" in
      -f|--file)
        shift; REPOS_FILE="$1"; shift ;;
      -i|--include)
        shift; INCLUDE_RAW="$1"; shift ;;
      -e|--exclude)
        shift; EXCLUDE_RAW="$1"; shift ;;
      -n|--dry-run)
        DRY_RUN=true; shift ;;
      -v|--verbose)
        VERBOSE=true; shift ;;
      -h|--help)
        usage; exit 0 ;;
      *)
        echo "Unknown option: $1" >&2
        usage; exit 1 ;;
    esac
  done

  if [ ! -f "$REPOS_FILE" ]; then
    echo "Error: repo list '$REPOS_FILE' not found." >&2
    exit 1
  fi

  IFS=',' read -r -a INCLUDE <<< "$INCLUDE_RAW"
  IFS=',' read -r -a EXCLUDE <<< "$EXCLUDE_RAW"
}

# --- determine inclusion/exclusion ---
should_process() {
  local name="$1"
  if [ "${#INCLUDE[@]}" -gt 0 ]; then
    local found=0
    for inc in "${INCLUDE[@]}"; do
      [ "$inc" = "$name" ] && found=1
    done
    [ $found -eq 1 ] || return 1
  fi
  if [ "${#EXCLUDE[@]}" -gt 0 ]; then
    for exc in "${EXCLUDE[@]}"; do
      [ "$exc" = "$name" ] && return 1
    done
  fi
  return 0
}

# --- parse a repo line robustly ---
parse_repo_line() {
  local line="$1"
  # strip leading/trailing whitespace
  line="${line#"${line%%[![:space:]]*}"}"
  line="${line%"${line##*[![:space:]]}"}"
  # first token = repo_spec
  local repo_spec="${line%%[[:space:]]*}"
  # rest after first token
  local rest="${line#"$repo_spec"}"
  rest="${rest#"${rest%%[![:space:]]*}"}"  # strip leading spaces
  local target_dir="$rest"
  echo "$repo_spec" "$target_dir"
}

# --- run one repo's run.sh if present ---
FOUND_ANY=false
run_one_repo() {
  local repo_spec="$1"
  local target_dir="$2"
  local start_dir="$3"
  local parent_dir
  parent_dir="$(dirname "$start_dir")"

  # strip branch
  local repo_url="${repo_spec%@*}"
  local folder
  if [[ "$repo_url" =~ ^https?:// ]]; then
    folder=$(basename "${repo_url%%.git}")
  else
    case "$repo_url" in
      datasets/*) folder="${repo_url#datasets/}" ;;
      *)          folder="${repo_url#*/}"        ;;
    esac
  fi

  if ! should_process "$folder"; then
    $VERBOSE && echo "Skipping $folder"
    return
  fi

  # compute the repo directory as sibling under parent_dir
  local dest
  if [ -n "$target_dir" ]; then
    dest="$parent_dir/$target_dir/$folder"
  else
    dest="$parent_dir/$folder"
  fi

  if [ -d "$dest" ]; then
    local script="$dest/run.sh"
    if [ -f "$script" ]; then
      echo "⏵ $folder: run.sh found"
      FOUND_ANY=true

      if $DRY_RUN; then
        echo "  DRY-RUN: would chmod +x and execute $script"
      else
        $VERBOSE && echo "  chmod +x \"$script\""
        chmod +x "$script"
        $VERBOSE && echo "  cd \"$dest\" && ./run.sh"
        ( cd "$dest" && ./run.sh )
      fi
    else
      $VERBOSE && echo "⏭ $folder: no run.sh"
    fi
  else
    echo "⚠️  Folder not found: $folder"
    exit 1
  fi
}

# --- main loop ---
main() {
  check_prerequisites
  parse_args "$@"

  local start_dir
  start_dir="$(pwd)"
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      \#*|'' ) continue ;;
    esac
    read repo_spec target_dir <<< "$(parse_repo_line "$line")"
    [ -z "$repo_spec" ] && continue
    run_one_repo "$repo_spec" "$target_dir" "$start_dir"
  done < "$REPOS_FILE"

  if [ "$FOUND_ANY" = false ]; then
    echo "ℹ️  No run.sh found in any of the repositories."
  fi
}

main "$@"
