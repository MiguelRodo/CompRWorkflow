#!/usr/bin/env bash

set -e

usage() {
  cat <<EOF
Usage: $0 [options]

Options:
  -f, --file <file>       Specify the repository list file (default: 'repos-to-clone.list').
  -h, --help              Display this help message.

Each line in the repository list file can be in the following formats:
  repo_spec [target_directory]

Where repo_spec is one of:
  owner/repo[@branch]
  datasets/owner/repo[@branch]
  https://<host>/owner/repo[@branch]

Examples:
  user1/project1
  user2/project2@develop ./Projects/Repo2
  datasets/user3/dataset1@main ../Datasets
  https://gitlab.com/user4/project4@feature-branch ./GitLabRepos
EOF
}

# Global Python code (only written once)
PYTHON_UPDATE_SCRIPT=$(cat <<'PYCODE'
import sys, json, os
ws = sys.argv[1]
paths = [line for line in os.environ['PATHS_LIST'].splitlines() if line.strip()]
try:
    with open(ws) as f:
        data = json.load(f)
except Exception:
    data = {}
data['folders'] = [{'path': p} for p in paths]
with open(ws, 'w') as f:
    json.dump(data, f, indent=2)
    f.write('\n')
PYCODE
)

get_workspace_file() {
  # Prefer lower-case, but use CamelCase if that's all there is
  local current_dir="$1"
  local workspace_file="$current_dir/entire-project.code-workspace"
  local workspace_file_camel="$current_dir/EntireProject.code-workspace"
  if [ -f "$workspace_file" ]; then
    echo "$workspace_file"
  elif [ -f "$workspace_file_camel" ]; then
    echo "$workspace_file_camel"
  else
    # If neither exists, will create lower-case one by default
    echo "$workspace_file"
  fi
}

build_paths_list() {
  local repos_list_file="$1"
  local current_dir="$2"
  local paths_list="."
  local line repo_spec target_dir repo_url_no_branch dir repo_path relative_repo_path

  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in ''|\#*) continue ;; esac
    line="$(printf '%s\n' "$line" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
    [ -z "$line" ] && continue

    repo_spec="$(printf '%s\n' "$line" | awk '{print $1}')"
    target_dir="$(printf '%s\n' "$line" | awk '{print $2}')"
    case "$repo_spec" in *@*) repo_url_no_branch="${repo_spec%@*}" ;; *) repo_url_no_branch="$repo_spec" ;; esac
    dir="$(basename "$repo_url_no_branch" .git)"

    if [ -n "$target_dir" ]; then
      repo_path="$current_dir/$target_dir/$dir"
    else
      repo_path="$current_dir/$dir"
    fi

    if command -v realpath >/dev/null 2>&1 && realpath --help 2>&1 | grep -q -- --relative-to; then
      relative_repo_path="$(realpath --relative-to="$current_dir" "$repo_path" 2>/dev/null || printf '%s\n' "$repo_path")"
    else
      case "$repo_path" in
        "$current_dir"/*) relative_repo_path="${repo_path#$current_dir/}" ;;
        *)                relative_repo_path="$repo_path" ;;
      esac
    fi

    [ "$relative_repo_path" = "." ] && continue
    paths_list="${paths_list}"$'\n'"../$relative_repo_path"
  done < "$repos_list_file"

  printf '%s\n' "$paths_list"
}

update_workspace_file() {
  local workspace_file="$1"
  local paths_list="$2"
  local folders_json
  if command -v jq >/dev/null 2>&1; then
    folders_json=$(printf '%s\n' "$paths_list" | jq -R . | jq -s '[.[] | {path: .}]')
    if [ ! -f "$workspace_file" ]; then
      jq --null-input --argjson folders "$folders_json" '{folders: $folders}' > "$workspace_file"
    else
      tmp="$(mktemp)"
      jq --argjson folders "$folders_json" '.folders = $folders' "$workspace_file" > "$tmp" && mv "$tmp" "$workspace_file"
    fi
    echo "Updated '$workspace_file' with jq."
  elif command -v python >/dev/null 2>&1; then
    PATHS_LIST="$paths_list" python - "$workspace_file" <<<"$PYTHON_UPDATE_SCRIPT"
    echo "Updated '$workspace_file' with Python."
  elif command -v python3 >/dev/null 2>&1; then
    PATHS_LIST="$paths_list" python3 - "$workspace_file" <<<"$PYTHON_UPDATE_SCRIPT"
    echo "Updated '$workspace_file' with Python3."
  elif command -v py >/dev/null 2>&1; then
    PATHS_LIST="$paths_list" py - "$workspace_file" <<<"$PYTHON_UPDATE_SCRIPT"
    echo "Updated '$workspace_file' with py launcher."
  else
    echo "Error: none of jq, python, python3 or py found. Cannot update workspace." >&2
    exit 1
  fi
}

main() {
  local repos_list_file="repos-to-clone.list"
  # Argument parsing
  while [ "$#" -gt 0 ]; do
    case "$1" in
      -f|--file)
        shift
        [ "$#" -gt 0 ] && repos_list_file="$1" && shift || { usage; exit 1; }
        ;;
      -h|--help)
        usage; exit 0
        ;;
      *)
        echo "Unknown argument: $1"
        usage
        exit 1
        ;;
    esac
  done

  if [ ! -f "$repos_list_file" ]; then
    echo "Repository list file '$repos_list_file' not found."
    exit 1
  fi

  local current_dir workspace_file paths_list
  current_dir="$(pwd)"
  workspace_file="$(get_workspace_file "$current_dir")"

  paths_list="$(build_paths_list "$repos_list_file" "$current_dir")"

  update_workspace_file "$workspace_file" "$paths_list"
}

main "$@"
