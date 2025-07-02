#!/usr/bin/env bash
# setup-compendium.sh — orchestrate project bootstrapping
# Requires: bash 3.2+, curl, git, and your four helper scripts

set -euo pipefail

# — Paths & defaults —
PROJECT_ROOT="$(cd "$(dirname "$0")" && pwd)"
REPOS_FILE="$PROJECT_ROOT/repos-to-clone.list"

PUBLIC_FLAG=false
PERMISSIONS_OPT=""
TOOL_OPT=""

CODESPACES_SCRIPT="$PROJECT_ROOT/scripts/codespaces-auth-add.sh"
CREATE_SCRIPT="$PROJECT_ROOT/scripts/create-repos.sh"
CLONE_SCRIPT="$PROJECT_ROOT/scripts/clone-repos.sh"
WORKSPACE_SCRIPT="$PROJECT_ROOT/scripts/vscode-workspace-add.sh"

usage() {
  cat <<EOF
Usage: $0 [options]

Options:
  -f, --file <file>           Use <file> instead of repos-to-clone.list
  -p, --public                Create repos as public (default is private)
  --permissions <all|contents> Pass through to codespaces-auth-add.sh
  -t, --tool <jq|python|…>    Force tool for codespaces-auth-add.sh
  -h, --help                  Show this help and exit
EOF
  exit 1
}

# — Parse args —
while [ $# -gt 0 ]; do
  case $1 in
    -f|--file)      shift; [ $# -gt 0 ] || usage; REPOS_FILE="$1"; shift ;;
    -p|--public)    PUBLIC_FLAG=true; shift ;;
    --permissions)  shift; [ $# -gt 0 ] || usage; PERMISSIONS_OPT="$1"; shift ;;
    -t|--tool)      shift; [ $# -gt 0 ] || usage; TOOL_OPT="$1"; shift ;;
    -h|--help)      usage ;;
    *)              echo "Unknown option: $1" >&2; usage ;;
  esac
done

[ -f "$REPOS_FILE" ] || { echo "Error: repo list '$REPOS_FILE' not found." >&2; exit 1; }

# — Ensure helpers exist —
for script in "$CREATE_SCRIPT" "$CLONE_SCRIPT" "$WORKSPACE_SCRIPT"; do
  [ -x "$script" ] || { echo "Error: '$script' not found or not executable." >&2; exit 1; }
done

echo "=== 1) Creating repos on GitHub ==="
create_args=( -f "$REPOS_FILE" )
$PUBLIC_FLAG && create_args+=( --public )
"$CREATE_SCRIPT" "${create_args[@]}"

echo "=== 2) Cloning repos locally ==="
"$CLONE_SCRIPT" --file "$REPOS_FILE"

echo "=== 3) Updating VS Code workspace ==="
"$WORKSPACE_SCRIPT" -f "$REPOS_FILE"

if [ -f "$PROJECT_ROOT/.devcontainer/devcontainer.json" ]; then
  if [ -x "$CODESPACES_SCRIPT" ]; then
    echo "=== 4) Injecting Codespaces permissions ==="
    codespaces_args=( -f "$REPOS_FILE" )
    [ -n "$PERMISSIONS_OPT" ] && codespaces_args+=( --permissions "$PERMISSIONS_OPT" )
    [ -n "$TOOL_OPT" ]       && codespaces_args+=( -t "$TOOL_OPT" )
    "$CODESPACES_SCRIPT" "${codespaces_args[@]}"
  else
    echo "Warning: codespaces-auth-add.sh not found; skipping Codespaces auth step."
  fi
else
  echo "No .devcontainer/devcontainer.json; skipping Codespaces auth step."
fi

echo "✅ Setup complete."
