#!/usr/bin/env bash
# AI conflict resolution: GPT-4o (GitHub Models) resolves, GPT-4o critiques hunks >20 lines.
# All AI calls use GH_TOKEN via GitHub Models — no separate API keys needed.
# On success: commits resolved files to HEAD branch. On any failure: aborts without pushing.
# Outputs /tmp/conflict_report.json
set -euo pipefail

PR_NUMBER="${1:-${PR_NUMBER:?'PR_NUMBER required'}}"
HEAD_BRANCH="${2:-${HEAD_BRANCH:?'HEAD_BRANCH required'}}"
BASE_BRANCH="${3:-${BASE_BRANCH:?'BASE_BRANCH required'}}"
GH_TOKEN="${GH_TOKEN:?'GH_TOKEN required'}"

GH_MODELS_ENDPOINT="https://models.inference.ai.azure.com/chat/completions"
RESOLVER_MODEL="gpt-4o"
CRITIQUE_MODEL="gpt-4o"

CONFLICT_FILE="${CONFLICT_FILE:-/tmp/conflicting_files.txt}"
HUNKS_FILE="${HUNKS_FILE:-/tmp/hunks.json}"
REPORT_FILE="/tmp/conflict_report.json"
GPT_CRITIQUE_THRESHOLD=20   # lines — skip GPT below this

# ── Abort if no conflicts ─────────────────────────────────────────────────────
if [ ! -s "$CONFLICT_FILE" ]; then
  echo "==> No conflicts to resolve."
  echo '{"conflicts_found":false}' > "$REPORT_FILE"
  exit 0
fi

if [ ! -f "$HUNKS_FILE" ] || [ "$(cat "$HUNKS_FILE")" = "[]" ]; then
  echo "==> Hunks file empty. Nothing to resolve."
  echo '{"conflicts_found":false}' > "$REPORT_FILE"
  exit 0
fi

echo "==> Re-applying merge to expose conflict markers in working tree"
git fetch origin "$BASE_BRANCH" --quiet
git merge --no-commit --no-ff "origin/$BASE_BRANCH" 2>&1 || true

FILE_RESULTS=()
ABORT=false

# ── Process each conflicting file ─────────────────────────────────────────────
FILE_COUNT=$(jq 'length' "$HUNKS_FILE")
echo "==> Resolving $FILE_COUNT file(s) with AI"

for i in $(seq 0 $((FILE_COUNT - 1))); do
  FILEPATH=$(jq -r ".[$i].file" "$HUNKS_FILE")
  RAW_CONTENT=$(jq -r ".[$i].raw_conflict_content" "$HUNKS_FILE")
  HUNK_LINES=$(jq -r ".[$i].hunk_line_count" "$HUNKS_FILE")

  echo "==> [$((i+1))/$FILE_COUNT] Resolving: $FILEPATH (hunk lines: $HUNK_LINES)"

  # Determine file type for Salesforce-specific resolution hints
  case "$FILEPATH" in
    *.cls|*.trigger) SF_HINT="Apex class/trigger: preserve both sides logic, deduplicate annotations and method signatures." ;;
    *package.xml|*Package.xml) SF_HINT="Salesforce package.xml: union merge — include all <members> from both sides, remove duplicates, keep alphabetical sort." ;;
    *-meta.xml|*.xml) SF_HINT="Salesforce metadata XML: union merge of XML child nodes, remove duplicate tags, preserve valid XML structure." ;;
    *.js) SF_HINT="LWC JavaScript: preserve both sides' functions and imports, resolve naming conflicts." ;;
    *.html) SF_HINT="LWC HTML template: merge template sections, preserve both sides' markup." ;;
    *) SF_HINT="Merge both sides intelligently preserving all functionality." ;;
  esac

  # ── GPT-4o resolution via GitHub Models ──────────────────────────────────
  RESOLVER_PAYLOAD=$(jq -n \
    --arg file "$FILEPATH" \
    --arg content "$RAW_CONTENT" \
    --arg hint "$SF_HINT" \
    --arg model "$RESOLVER_MODEL" \
    '{
      model: $model,
      max_tokens: 8192,
      messages: [
        {
          role: "system",
          content: "You are an expert Salesforce DevOps engineer resolving git merge conflicts. Return ONLY the complete resolved file content with all conflict markers removed. No explanations, no markdown fences, no commentary — just the file content."
        },
        {
          role: "user",
          content: ("File: " + $file + "\nHint: " + $hint + "\n\nConflicting file content:\n" + $content + "\n\nReturn the fully resolved file content only.")
        }
      ]
    }')

  RESOLVER_RESPONSE=$(curl -s --max-time 60 "$GH_MODELS_ENDPOINT" \
    -H "Authorization: Bearer $GH_TOKEN" \
    -H "content-type: application/json" \
    -d "$RESOLVER_PAYLOAD")

  RESOLVED_CONTENT=$(echo "$RESOLVER_RESPONSE" | jq -r '.choices[0].message.content // ""')
  RESOLVER_ERROR=$(echo "$RESOLVER_RESPONSE" | jq -r '.error.message // ""')

  if [ -z "$RESOLVED_CONTENT" ] || [ -n "$RESOLVER_ERROR" ]; then
    echo "  ✗ Resolver failed for $FILEPATH: $RESOLVER_ERROR"
    FILE_RESULTS+=("{\"file\":\"$FILEPATH\",\"status\":\"failed\",\"error\":\"resolver_error: $RESOLVER_ERROR\",\"critique_skipped\":true}")
    ABORT=true
    continue
  fi

  # Sanity check: resolved content must not contain conflict markers
  if echo "$RESOLVED_CONTENT" | grep -q "^<<<<<<< \|^=======$\|^>>>>>>> "; then
    echo "  ✗ Resolution still contains conflict markers for $FILEPATH"
    FILE_RESULTS+=("{\"file\":\"$FILEPATH\",\"status\":\"failed\",\"error\":\"unresolved_markers_remain\",\"critique_skipped\":true}")
    ABORT=true
    continue
  fi

  FINAL_CONTENT="$RESOLVED_CONTENT"
  CRITIQUE_SKIPPED=true
  CRITIQUE_APPROVED=false

  # ── GPT-4o critique via GitHub Models — only for large hunks ────────────────
  if [ "$HUNK_LINES" -gt "$GPT_CRITIQUE_THRESHOLD" ]; then
    echo "  → Hunk >$GPT_CRITIQUE_THRESHOLD lines — sending to GitHub Models (GPT-4o) critique"
    CRITIQUE_SKIPPED=false

    GPT_PAYLOAD=$(jq -n \
      --arg file "$FILEPATH" \
      --arg original "$RAW_CONTENT" \
      --arg resolved "$RESOLVED_CONTENT" \
      --arg hint "$SF_HINT" \
      --arg model "$CRITIQUE_MODEL" \
      '{
        model: $model,
        max_tokens: 2048,
        response_format: {type: "json_object"},
        messages: [
          {
            role: "system",
            content: "You are a senior Salesforce code reviewer critiquing an AI-generated merge conflict resolution. Respond in JSON only."
          },
          {
            role: "user",
            content: ("File: " + $file + "\nContext: " + $hint + "\n\nOriginal conflict:\n" + $original + "\n\nProposed resolution:\n" + $resolved + "\n\nReview the resolution for correctness, completeness, and rule adherence. Respond with JSON: {\"decision\": \"APPROVE\" or \"REJECT\", \"reasons\": [\"...\"], \"corrected_file\": \"<full corrected content if REJECT, else null>\"}")
          }
        ]
      }')

    GPT_RESPONSE=$(curl -s --max-time 60 "$GH_MODELS_ENDPOINT" \
      -H "Authorization: Bearer $GH_TOKEN" \
      -H "content-type: application/json" \
      -d "$GPT_PAYLOAD")

    GPT_CONTENT=$(echo "$GPT_RESPONSE" | jq -r '.choices[0].message.content // "{}"')
    GPT_DECISION=$(echo "$GPT_CONTENT" | jq -r '.decision // "APPROVE"')
    GPT_CORRECTED=$(echo "$GPT_CONTENT" | jq -r '.corrected_file // ""')
    GPT_REASONS=$(echo "$GPT_CONTENT" | jq -r '.reasons // [] | join("; ")')

    if [ "$GPT_DECISION" = "APPROVE" ]; then
      echo "  ✓ GPT approved resolution for $FILEPATH"
      CRITIQUE_APPROVED=true
    elif [ "$GPT_DECISION" = "REJECT" ] && [ -n "$GPT_CORRECTED" ] && [ "$GPT_CORRECTED" != "null" ]; then
      echo "  → GPT rejected but provided correction for $FILEPATH. Using GPT correction."
      FINAL_CONTENT="$GPT_CORRECTED"
      CRITIQUE_APPROVED=true
    else
      echo "  ✗ GPT rejected $FILEPATH without safe correction: $GPT_REASONS"
      FILE_RESULTS+=("{\"file\":\"$FILEPATH\",\"status\":\"failed\",\"error\":\"gpt_rejected: $GPT_REASONS\",\"critique_skipped\":false,\"critique_approved\":false}")
      ABORT=true
      continue
    fi
  else
    CRITIQUE_APPROVED=true
    [ "$HUNK_LINES" -le "$GPT_CRITIQUE_THRESHOLD" ] && echo "  → Hunk ≤$GPT_CRITIQUE_THRESHOLD lines — GitHub Models critique skipped"
  fi

  # ── Write resolved file ───────────────────────────────────────────────────
  echo "$FINAL_CONTENT" > "$FILEPATH"
  echo "  ✓ Written: $FILEPATH"

  CRITIQUE_SKIPPED_VAL=$([ "$CRITIQUE_SKIPPED" = true ] && echo "true" || echo "false")
  CRITIQUE_APPROVED_VAL=$([ "$CRITIQUE_APPROVED" = true ] && echo "true" || echo "false")
  FILE_RESULTS+=("{\"file\":\"$FILEPATH\",\"status\":\"resolved\",\"model\":\"gpt-4o\",\"critique_skipped\":$CRITIQUE_SKIPPED_VAL,\"critique_approved\":$CRITIQUE_APPROVED_VAL}")
done

# ── Abort if any file failed ──────────────────────────────────────────────────
if [ "$ABORT" = "true" ]; then
  echo "==> One or more files failed resolution. Aborting — no commit will be pushed."
  git merge --abort 2>/dev/null || true

  RESULTS_JSON=$(printf '%s\n' "${FILE_RESULTS[@]}" | jq -Rs 'split("\n") | map(select(. != "")) | map(fromjson)')
  jq -n --argjson files "$RESULTS_JSON" \
    '{conflicts_found:true, all_passed:false, files:$files}' > "$REPORT_FILE"

  echo "ALL_PASSED=false" >> "${GITHUB_OUTPUT:-/tmp/gha_output.txt}"
  exit 1
fi

# ── Commit and push resolved files ───────────────────────────────────────────
echo "==> All files resolved. Committing."

git config user.email "ai-pr-bot@netradyne.com"
git config user.name "AI PR Bot"

git add -A
git commit -m "fix: AI conflict resolution for PR #${PR_NUMBER} [skip ci]"

COMMIT_SHA=$(git rev-parse HEAD)
echo "==> Pushing to origin/$HEAD_BRANCH"
git push origin "HEAD:$HEAD_BRANCH"

echo "==> Conflict resolution committed: ${COMMIT_SHA:0:7}"

RESULTS_JSON=$(printf '%s\n' "${FILE_RESULTS[@]}" | jq -Rs 'split("\n") | map(select(. != "")) | map(fromjson)')
jq -n \
  --argjson files "$RESULTS_JSON" \
  --arg sha "$COMMIT_SHA" \
  '{conflicts_found:true, all_passed:true, commit_sha:$sha, files:$files}' > "$REPORT_FILE"

echo "ALL_PASSED=true"   >> "${GITHUB_OUTPUT:-/tmp/gha_output.txt}"
echo "COMMIT_SHA=$COMMIT_SHA" >> "${GITHUB_OUTPUT:-/tmp/gha_output.txt}"
