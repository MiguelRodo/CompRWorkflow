#!/usr/bin/env bash
# clone-multirepos.sh — Simple, portable multi-repo cloner (Linux, Mac, WSL, Git Bash)

set -e

# --- Prerequisite checks ---
check_prerequisites() {
  for cmd in git awk; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
      echo "Error: '$cmd' is required but not found in PATH." >&2
      exit 1
    fi
  done
}

usage() {
  cat <<EOF
Usage: $0 [--file <repo-list>]

Clone all repositories listed in <repo-list> (default: repos-to-clone.list).
Format per line: [repo_spec] [target_directory]
- repo_spec: owner/repo[@branch] OR https://host/owner/repo[@branch]
- target_directory: (optional) folder to clone into (relative to CWD).

Examples:
  user1/repo1
  user2/repo2@dev ./src
  https://github.com/user3/repo3@main ./github
EOF
}

parse_args() {
  REPOS_FILE="repos-to-clone.list"
  while [ "$#" -gt 0 ]; do
    case "$1" in
      -f|--file)
        shift
        [ "$#" -gt 0 ] && REPOS_FILE="$1" || { usage; exit 1; }
        shift
        ;;
      -h|--help)
        usage; exit 0
        ;;
      *)
        echo "Unknown arg: $1"
        usage; exit 1
        ;;
    esac
  done
  if [ ! -f "$REPOS_FILE" ]; then
    echo "File '$REPOS_FILE' not found."; exit 1
  fi
}

parse_repo_line() {
  # Outputs: repo_spec, target_dir
  local line="$1"
  local repo_spec target_dir
  repo_spec=$(echo "$line" | awk '{print $1}')
  target_dir=$(echo "$line" | awk '{print $2}')
  echo "$repo_spec" "$target_dir"
}

clone_one_repo() {
  # Arguments: repo_spec target_dir start_dir
  local repo_spec="$1"
  local target_dir="$2"
  local start_dir="$3"

  # Parse @branch if present
  local repo_url_no_branch branch
  case "$repo_spec" in
    *@*) repo_url_no_branch="${repo_spec%@*}"; branch="${repo_spec##*@}" ;;
    *) repo_url_no_branch="$repo_spec"; branch="" ;;
  esac

  # Compute remote and default folder
  local repo_url repo_dir host
  case "$repo_url_no_branch" in
    https://*) repo_url="$repo_url_no_branch"
               repo_dir=$(basename "$repo_url_no_branch" .git)
               ;;
    *)
      # Assume GitHub by default, datasets/ prefix for Hugging Face
      case "$repo_url_no_branch" in
        datasets/*)
          host="https://huggingface.co"
          repo_url="$host/$repo_url_no_branch"
          repo_dir="${repo_url_no_branch#datasets/}"
          ;;
        *)
          host="https://github.com"
          repo_url="$host/$repo_url_no_branch"
          repo_dir="${repo_url_no_branch#*/}"
          ;;
      esac
      ;;
  esac

  # Use provided or default target dir
  local dest
  if [ -n "$target_dir" ]; then
    dest="$start_dir/$target_dir"
  else
    dest="$start_dir"
  fi

  mkdir -p "$dest"
  cd "$dest"

  # Clone or update
  if [ ! -d "$repo_dir" ]; then
    if [ -n "$branch" ]; then
      git clone -b "$branch" "$repo_url"
    else
      git clone "$repo_url"
    fi
  else
    echo "Already exists: $dest/$repo_dir"
    # Optionally: git -C "$repo_dir" pull
  fi

  cd "$start_dir"
}

main() {
  check_prerequisites
  parse_args "$@"
  local start_dir
  start_dir="$(pwd)"
  parent_dir="$(dirname "$start_dir")"

  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in \#*|"") continue ;; esac
    set -- $(parse_repo_line "$line")
    local repo_spec="$1" target_dir="$2"
    [ -z "$repo_spec" ] && continue
    clone_one_repo "$repo_spec" "$target_dir" "$parent_dir"
  done < "$REPOS_FILE"
}

main "$@"
