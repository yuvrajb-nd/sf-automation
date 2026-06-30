#!/usr/bin/env bash
# Validates that a PR follows the configured branch promotion pipeline.
# E.g. PIPELINE_ORDER=TESTING,main enforces: feature->TESTING->main
# Outputs /tmp/branch_order.json
set -euo pipefail

HEAD_BRANCH="${HEAD_BRANCH:?'HEAD_BRANCH required'}"
BASE_BRANCH="${BASE_BRANCH:?'BASE_BRANCH required'}"
PIPELINE_ORDER="${PIPELINE_ORDER:-TESTING,main}"
OUTPUT_FILE="${OUTPUT_FILE:-/tmp/branch_order.json}"

echo "==> Branch order check: $HEAD_BRANCH -> $BASE_BRANCH (pipeline: $PIPELINE_ORDER)"

IFS=',' read -ra STAGES <<< "$PIPELINE_ORDER"

index_of() {
  local branch="$1" i
  for i in "${!STAGES[@]}"; do
    [ "${STAGES[$i]}" = "$branch" ] && echo "$i" && return
  done
  echo "-1"
}

BASE_IDX=$(index_of "$BASE_BRANCH")
HEAD_IDX=$(index_of "$HEAD_BRANCH")

STATUS="ok"
MESSAGE=""
VIOLATION=""

if [ "$BASE_IDX" = "-1" ]; then
  STATUS="skipped"
  MESSAGE="Target branch '$BASE_BRANCH' is not in the configured pipeline. No order check performed."
elif [ "$HEAD_IDX" = "-1" ]; then
  # Feature branch (not in pipeline) — must target the first stage only
  if [ "$BASE_IDX" != "0" ]; then
    STATUS="violation"
    VIOLATION="direct_to_non_first_stage"
    MESSAGE="Feature branch '$HEAD_BRANCH' targets '$BASE_BRANCH' directly. It must go through '${STAGES[0]}' first."
  else
    STATUS="ok"
    MESSAGE="Feature branch targeting first pipeline stage '${STAGES[0]}'. Order is correct."
  fi
else
  EXPECTED_PREV=$((BASE_IDX - 1))
  if [ "$EXPECTED_PREV" -lt 0 ]; then
    STATUS="skipped"
    MESSAGE="'${STAGES[0]}' is the first stage. Any branch may target it."
  elif [ "$HEAD_IDX" -eq "$EXPECTED_PREV" ]; then
    STATUS="ok"
    MESSAGE="'$HEAD_BRANCH' correctly promotes to '$BASE_BRANCH' per pipeline order."
  elif [ "$HEAD_IDX" -lt "$EXPECTED_PREV" ]; then
    NEXT_STAGE="${STAGES[$((HEAD_IDX + 1))]}"
    STATUS="violation"
    VIOLATION="skipping_stages"
    MESSAGE="'$HEAD_BRANCH' skips stages. Next required target is '$NEXT_STAGE', not '$BASE_BRANCH'."
  else
    STATUS="violation"
    VIOLATION="backwards_promotion"
    MESSAGE="'$HEAD_BRANCH' is at a later pipeline stage than '$BASE_BRANCH'. This is a backwards promotion."
  fi
fi

jq -n \
  --arg status "$STATUS" \
  --arg message "$MESSAGE" \
  --arg violation "$VIOLATION" \
  --arg head "$HEAD_BRANCH" \
  --arg base "$BASE_BRANCH" \
  --arg pipeline "$PIPELINE_ORDER" \
  '{status:$status, message:$message, violation:$violation,
    head_branch:$head, base_branch:$base, pipeline:$pipeline}' > "$OUTPUT_FILE"

echo "==> Result: $STATUS — $MESSAGE"
if [ "$STATUS" = "violation" ]; then
  echo "BRANCH_ORDER_VIOLATION=true" >> "${GITHUB_OUTPUT:-/tmp/gha_output.txt}"
else
  echo "BRANCH_ORDER_VIOLATION=false" >> "${GITHUB_OUTPUT:-/tmp/gha_output.txt}"
fi
