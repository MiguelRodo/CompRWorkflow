#!/usr/bin/env bash

# strict mode
set -o errexit   # bail on error
set -o nounset   # undefined var → error
set -o pipefail  # catch failures in pipes
IFS=$'\n\t'      # only split on newline and tab

# 0. Ensure Rscript exists
if ! command -v Rscript >/dev/null 2>&1; then
  echo "❌ Rscript not found. Please install Rscript." >&2
  exit 1
fi
# 4. Parse all the "path" entries via jq
if ! command -v jq >/dev/null 2>&1; then
  echo "❌ jq not found. Please install jq to parse the workspace file." >&2
  exit 1
fi

# 1. Where the user ran this script
INVOKE_DIR="$PWD"

# 2. Where this script lives (to locate the workspace file)
SCRIPT_DIR="$(cd "$(dirname "$0")" >/dev/null 2>&1 && pwd)"

# 3. Locate the workspace JSON (one level up)
WS1="$SCRIPT_DIR/../entire-project.code-workspace"
WS2="$SCRIPT_DIR/../EntireProject.code-workspace"
if   [ -f "$WS1" ]; then WORKSPACE_FILE="$WS1"
elif [ -f "$WS2" ]; then WORKSPACE_FILE="$WS2"
else
  echo "❌ No .code‑workspace file found in $(dirname \"\$SCRIPT_DIR\")" >&2
  exit 1
fi

# 4. Parse all the "path" entries into a Bash array
FOLDERS=()
while IFS= read -r folder; do
  FOLDERS+=("$folder")
done < <(jq -r '.folders[].path' "$WORKSPACE_FILE")

# 5. Your provided helpers, tweaked to operate per‑folder
restore_renv() {
  local rel="$1"
  local tgt="$INVOKE_DIR/$rel"

  echo "🔄 [$rel] Found renv.lock – restoring with renv…"
  # run everything *inside* that folder
  cd "$tgt" || { echo "⚠️ cannot cd to $tgt"; return 1; }

  echo "⚙️  Checking for renv…"
  cd ".." || exit 1
  Rscript -e '
    if (!requireNamespace("renv", quietly=TRUE))
      install.packages("renv", repos="https://cloud.r-project.org")
  '
  cd "$tgt" || exit 1

  echo "⚙️ Upgrade renv…"
  Rscript -e 'renv::upgrade()'

  echo "⚙️  Checking for gitcreds…"
  Rscript -e '
    if (!requireNamespace("gitcreds", quietly=TRUE))
      renv::install("gitcreds")
  '

  echo "🔗  Installing UtilsProjrMR…"
  Rscript -e 'renv::install("MiguelRodo/UtilsProjrMR")'

  echo "🔄  Updating & restoring project via UtilsProjrMR…"
  Rscript -e 'UtilsProjrMR::projr_renv_restore_and_update()'

  echo "✅ [$rel] Done."
  # back to where we started
  cd "$INVOKE_DIR" || exit 1
}

restore_pak_desc() {
  local rel="$1"
  local tgt="$INVOKE_DIR/$rel"

  echo "🔄 [$rel] Found DESCRIPTION – installing via pak…"
  cd "$tgt" || { echo "⚠️ cannot cd to $tgt"; return 1; }

  Rscript -e '
    if (!requireNamespace("pak", quietly=TRUE))
      install.packages("pak", repos="https://cloud.r-project.org");
    pak::local_install_dev_deps()
  ' || return 1

  echo "✅ [$rel] pak install done."
  cd "$INVOKE_DIR" || exit 1
}

# 6. Loop over each folder and try restoring
for rel in "${FOLDERS[@]}"; do
  TARGET="$INVOKE_DIR/$rel"

  if [ ! -d "$TARGET" ]; then
    echo "⚠️ [$rel] Folder not found – skipping"
    continue
  fi

  if [ -f "$TARGET/renv.lock" ]; then
    restore_renv "$rel" \
      || echo "⚠️ [$rel] renv restore failed – moving on"
  elif [ -f "$TARGET/DESCRIPTION" ]; then
    restore_pak_desc "$rel" \
      || echo "⚠️ [$rel] pak install failed – moving on"
  else
    echo "ℹ️ [$rel] No renv.lock or DESCRIPTION – skipping"
  fi
done

echo "✅ All done across all folders!"
