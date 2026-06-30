#!/usr/bin/env bash
# Re-applies the merge (no-commit) and extracts conflict hunks per file into /tmp/hunks.json.
# Each hunk includes: file path, ours block, theirs block, context lines, hunk line count.
set -euo pipefail

BASE_BRANCH="${1:-${BASE_BRANCH:?'BASE_BRANCH required'}}"
CONFLICT_FILE="${CONFLICT_FILE:-/tmp/conflicting_files.txt}"
HUNKS_FILE="/tmp/hunks.json"

if [ ! -s "$CONFLICT_FILE" ]; then
  echo "==> No conflicting files listed. Nothing to extract."
  echo "[]" > "$HUNKS_FILE"
  exit 0
fi

echo "==> Re-applying merge to expose conflict markers"
git merge --no-commit --no-ff "origin/$BASE_BRANCH" 2>&1 || true

extract_hunks_from_file() {
  local filepath="$1"
  local content
  content=$(cat "$filepath" 2>/dev/null || echo "")

  # Use awk to extract each conflict block with 5 lines of context
  awk '
    /^<<<<<<< / { in_conflict=1; ours=""; theirs=""; side="ours"; ctx_start=NR; next }
    /^=======/  { if(in_conflict) { side="theirs"; next } }
    /^>>>>>>> / {
      if(in_conflict) {
        in_conflict=0
        gsub(/\n$/, "", ours)
        gsub(/\n$/, "", theirs)
        hunk_lines = split(ours, a, "\n") + split(theirs, b, "\n")
        printf "%s\t%s\t%d\n", ours, theirs, hunk_lines
      }
      next
    }
    {
      if(in_conflict) {
        if(side=="ours")   ours   = ours $0 "\n"
        if(side=="theirs") theirs = theirs $0 "\n"
      }
    }
  ' "$filepath"
}

HUNKS_JSON="["
FIRST=true

while IFS= read -r filepath; do
  [ -z "$filepath" ] && continue
  [ ! -f "$filepath" ] && continue

  echo "==> Extracting hunks from: $filepath"

  # Read full conflicting file content (escaped for JSON)
  RAW_CONTENT=$(cat "$filepath" | jq -Rs .)

  # Count total conflict hunk lines for GPT-critique threshold decision
  HUNK_LINE_COUNT=$(grep -c "^<<<<<<< \|^=======$\|^>>>>>>> " "$filepath" 2>/dev/null || echo "0")

  ENTRY=$(jq -n \
    --arg file "$filepath" \
    --argjson content "$RAW_CONTENT" \
    --argjson hunk_lines "$HUNK_LINE_COUNT" \
    '{file: $file, raw_conflict_content: $content, hunk_line_count: $hunk_lines}')

  if [ "$FIRST" = true ]; then
    HUNKS_JSON="${HUNKS_JSON}${ENTRY}"
    FIRST=false
  else
    HUNKS_JSON="${HUNKS_JSON},${ENTRY}"
  fi

done < "$CONFLICT_FILE"

HUNKS_JSON="${HUNKS_JSON}]"
echo "$HUNKS_JSON" > "$HUNKS_FILE"

COUNT=$(echo "$HUNKS_JSON" | jq 'length')
echo "==> Extracted hunks for $COUNT file(s) → $HUNKS_FILE"
