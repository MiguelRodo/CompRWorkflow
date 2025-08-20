#!/usr/bin/env bash
# clone-multirepos.sh — Simple, portable multi-repo cloner (Linux, macOS, WSL, Git Bash)

set -e

# --- Prerequisite checks -----------------------------------------------------
check_prerequisites() {
    for cmd in git awk; do
        if ! command -v "$cmd" >/dev/null 2>&1; then
            echo "Error: '$cmd' is required but not found in PATH." >&2
            exit 1
        fi
    done
}

# --- Usage -------------------------------------------------------------------
usage() {
    cat <<EOF
Usage: $0 [--file <repo-list>]

Clone all repositories listed in <repo-list> (default: repos.list).
Format per line: [repo_spec] [target_directory]
  repo_spec        owner/repo[@branch]  OR  https://host/owner/repo[@branch]
  target_directory (optional) directory to clone into (relative to parent of CWD)

Examples:
  user1/repo1
  user2/repo2@dev ./src
  https://gitlab.com/u/r@main ./gitlab
EOF
}

# --- Argument parsing --------------------------------------------------------
parse_args() {
    if [ ! -f "repos.list" ] && [ -f "repos-to-clone.list" ]; then
        REPOS_FILE="repos-to-clone.list"
    else
        REPOS_FILE="repos.list"
    fi

    while [ "$#" -gt 0 ]; do
        case "$1" in
            -f|--file)
                shift
                [ "$#" -gt 0 ] && REPOS_FILE="$1" || { usage; exit 1; }
                shift
                ;;
            -h|--help)
                usage
                exit 0
                ;;
            *)
                echo "Unknown argument: $1" >&2
                usage
                exit 1
                ;;
        esac
    done

    if [ ! -f "$REPOS_FILE" ]; then
        echo "File '$REPOS_FILE' not found." >&2
        exit 1
    fi
}

# --- Helpers -----------------------------------------------------------------
parse_repo_line() {
    # Echoes: repo_spec  target_dir
    local line="$1"
    local repo_spec target_dir
    repo_spec=$(echo "$line" | awk '{print $1}')
    target_dir=$(echo "$line" | awk '{print $2}')
    echo "$repo_spec" "$target_dir"
}

clone_one_repo() {
    # Args: repo_spec  target_dir  base_dir
    local repo_spec="$1" target_dir="$2" base_dir="$3"

    # Split out @ref (branch/tag/commit) if present
    local repo_url_no_ref ref
    case "$repo_spec" in
        *@*) repo_url_no_ref="${repo_spec%@*}"; ref="${repo_spec##*@}" ;;
        *)   repo_url_no_ref="$repo_spec"; ref="" ;;
    esac

    # Determine remote URL and default local folder name
    local repo_url repo_dir
    case "$repo_url_no_ref" in
        https://*)
            repo_url="$repo_url_no_ref"
            repo_dir=$(basename "${repo_url_no_ref%.git}")
            ;;
        *)
            repo_url="https://github.com/$repo_url_no_ref"
            repo_dir="${repo_url_no_ref#*/}"
            ;;
    esac

    # Compute final destination
    local dest
    if [ -n "$target_dir" ]; then
        dest="$base_dir/$target_dir"   # clone directly into this directory
    else
        dest="$base_dir/$repo_dir"     # default: repo-named directory
    fi

    # Skip if already there
    if [ -d "$dest/.git" ]; then
        echo "Already exists: $dest"
        return 0
    fi

    # Ensure parent exists; allow cloning into an empty existing dir
    mkdir -p "$dest"
    if [ -n "$(ls -A "$dest" 2>/dev/null)" ]; then
        echo "Error: destination '$dest' exists and is not empty." >&2
        return 1
    fi

    # Clone directly into the destination
    git clone "$repo_url" "$dest"

    # Optional: checkout branch/tag/commit
    if [ -n "$ref" ]; then
        git -C "$dest" checkout "$ref"
    fi
}

# --- Main --------------------------------------------------------------------
main() {
    check_prerequisites
    parse_args "$@"

    local start_dir parent_dir
    start_dir="$(pwd)"
    parent_dir="$(dirname "$start_dir")"

    while IFS= read -r line || [ -n "$line" ]; do
        case "$line" in \#*|"") continue ;; esac   # skip comments / blanks
        set -- $(parse_repo_line "$line")
        local repo_spec="$1" target_dir="$2"
        [ -z "$repo_spec" ] && continue
        clone_one_repo "$repo_spec" "$target_dir" "$parent_dir"
    done <"$REPOS_FILE"
}

main "$@"
