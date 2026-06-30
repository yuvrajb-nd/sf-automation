#!/usr/bin/env bash
# Detects merge conflicts between HEAD branch and base branch.
# Outputs conflicting file paths to /tmp/conflicting_files.txt (empty = no conflicts).
set -euo pipefail

BASE_BRANCH="${1:-${BASE_BRANCH:?'BASE_BRANCH required'}}"
HEAD_BRANCH="${2:-${HEAD_BRANCH:?'HEAD_BRANCH required'}}"

CONFLICT_FILE="/tmp/conflicting_files.txt"
> "$CONFLICT_FILE"

echo "==> Fetching origin/$BASE_BRANCH"
git fetch origin "$BASE_BRANCH" --quiet

echo "==> Attempting merge (no-commit) to detect conflicts"
git merge --no-commit --no-ff "origin/$BASE_BRANCH" 2>&1 || true

CONFLICTS=$(git diff --name-only --diff-filter=U 2>/dev/null || true)

git merge --abort 2>/dev/null || true

if [ -z "$CONFLICTS" ]; then
  echo "==> No merge conflicts detected. Skipping AI resolution."
  echo "CONFLICTS_FOUND=false" >> "${GITHUB_OUTPUT:-/tmp/gha_output.txt}"
  exit 0
fi

echo "$CONFLICTS" > "$CONFLICT_FILE"
CONFLICT_COUNT=$(echo "$CONFLICTS" | wc -l | tr -d ' ')
echo "==> Found $CONFLICT_COUNT conflicting file(s):"
echo "$CONFLICTS"

echo "CONFLICTS_FOUND=true" >> "${GITHUB_OUTPUT:-/tmp/gha_output.txt}"
echo "CONFLICT_COUNT=$CONFLICT_COUNT" >> "${GITHUB_OUTPUT:-/tmp/gha_output.txt}"
