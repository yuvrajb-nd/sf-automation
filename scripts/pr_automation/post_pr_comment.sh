#!/usr/bin/env bash
# Posts or updates a single structured PR comment using <!-- ai-pr-bot --> as an idempotency marker.
# Reads /tmp/conflict_report.json, /tmp/package_audit.json, /tmp/ocm_report.json to build the body.
set -euo pipefail

PR_NUMBER="${1:-${PR_NUMBER:?'PR_NUMBER required'}}"
REPO="${2:-${REPO:?'REPO required'}}"
HEAD_BRANCH="${3:-${HEAD_BRANCH:?'HEAD_BRANCH required'}}"
BASE_BRANCH="${4:-${BASE_BRANCH:?'BASE_BRANCH required'}}"

CONFLICT_REPORT="${CONFLICT_REPORT:-/tmp/conflict_report.json}"
AUDIT_FILE="${AUDIT_FILE:-/tmp/package_audit.json}"
OCM_FILE="${OCM_FILE:-/tmp/ocm_report.json}"

BOT_MARKER="<!-- ai-pr-bot -->"

# ── Helper: read JSON or fallback ─────────────────────────────────────────────
read_json() {
  local file="$1" fallback="$2"
  [ -f "$file" ] && cat "$file" || echo "$fallback"
}

# ── Conflict Resolution Section ───────────────────────────────────────────────
CONFLICT_JSON=$(read_json "$CONFLICT_REPORT" '{"skipped":true}')
CONFLICTS_FOUND=$(echo "$CONFLICT_JSON" | jq -r '.conflicts_found // false')
RESOLUTION_STATUS="[SKIP] No conflicts detected"
CONFLICT_TABLE=""
RESOLUTION_COMMIT=""

if [ "$CONFLICTS_FOUND" = "true" ]; then
  ALL_PASSED=$(echo "$CONFLICT_JSON" | jq -r '.all_passed // false')
  RESOLUTION_COMMIT=$(echo "$CONFLICT_JSON" | jq -r '.commit_sha // ""')

  if [ "$ALL_PASSED" = "true" ]; then
    RESOLUTION_STATUS="[OK] Resolved automatically"
    [ -n "$RESOLUTION_COMMIT" ] && RESOLUTION_STATUS="$RESOLUTION_STATUS — committed as \`${RESOLUTION_COMMIT:0:7}\`"
  else
    RESOLUTION_STATUS="[FAIL] Some files could not be resolved — manual intervention required"
  fi

  CONFLICT_TABLE=$(echo "$CONFLICT_JSON" | jq -r '
    .files[]? |
    "| `\(.file)` | \(.model // "claude-sonnet-4-6") | \(if .critique_skipped then "Skipped (<20 lines)" else (if .critique_approved then "GPT:APPROVED" else "GPT:REJECTED" end) end) | \(.status) |"
  ' || true)
fi

# ── OCM Section ───────────────────────────────────────────────────────────────
OCM_JSON=$(read_json "$OCM_FILE" '{"categories":[],"risk_flags":[],"risk_summary":{"high":0,"medium":0,"low":0}}')
OCM_SKIPPED=$(echo "$OCM_JSON" | jq -r '.skipped // false')
OCM_HIGH=$(echo "$OCM_JSON" | jq -r '.risk_summary.high // 0')
OCM_MED=$(echo "$OCM_JSON"  | jq -r '.risk_summary.medium // 0')
OCM_LOW=$(echo "$OCM_JSON"  | jq -r '.risk_summary.low // 0')

OCM_TABLE=$(echo "$OCM_JSON" | jq -r '
  .categories[]? |
  "| \(.type) | \(.count) |"
' || true)

RISK_ROWS=$(echo "$OCM_JSON" | jq -r '
  .risk_flags[]? |
  if .severity == "high"   then "[HIGH]"
  elif .severity == "medium" then "[MED]"
  else "[LOW]" end + " **\(.message)**" +
  (if .detail then "\n  > `\(.detail)`" else "" end)
' || true)

# ── Package Audit Section ─────────────────────────────────────────────────────
AUDIT_JSON=$(read_json "$AUDIT_FILE" '{"skipped":true}')
AUDIT_SKIPPED=$(echo "$AUDIT_JSON" | jq -r '.skipped // false')
AUDIT_STATUS="[SKIP] No Package.xml found for this branch"
AUDIT_DETAIL=""
AUDIT_EXPLANATION=""

if [ "$AUDIT_SKIPPED" != "true" ]; then
  TOTAL=$(echo "$AUDIT_JSON"   | jq -r '.total_components // 0')
  FOUND=$(echo "$AUDIT_JSON"   | jq -r '.found_count // 0')
  MISSING=$(echo "$AUDIT_JSON" | jq -r '.missing_count // 0')

  if [ "$MISSING" -eq 0 ]; then
    AUDIT_STATUS="[OK] All $TOTAL components present in repository"
  else
    AUDIT_STATUS="[WARN] $MISSING/$TOTAL component(s) missing from repository"
    AUDIT_DETAIL=$(echo "$AUDIT_JSON" | jq -r '.missing[]? | "- `\(.member)` (\(.type)) — expected at `\(.expected_path)`"' || true)
    AUDIT_EXPLANATION=$(echo "$AUDIT_JSON" | jq -r '.missing_explanation // ""')
  fi

  NET_NEW=$(echo "$AUDIT_JSON"  | jq -r '.net_new_vs_base[]?' | sed 's/^/- /' || true)
  REMOVED=$(echo "$AUDIT_JSON"  | jq -r '.removed_vs_base[]?' | sed 's/^/- /' || true)
fi

# ── Overall status badge ──────────────────────────────────────────────────────
BRANCH_ORDER_FILE="${BRANCH_ORDER_FILE:-/tmp/branch_order.json}"
BRANCH_ORDER_JSON=$(read_json "$BRANCH_ORDER_FILE" '{"status":"skipped"}')
BRANCH_ORDER_STATUS=$(echo "$BRANCH_ORDER_JSON" | jq -r '.status // "skipped"')
BRANCH_ORDER_MSG=$(echo "$BRANCH_ORDER_JSON" | jq -r '.message // ""')
BRANCH_ORDER_PIPELINE=$(echo "$BRANCH_ORDER_JSON" | jq -r '.pipeline // ""')

case "$BRANCH_ORDER_STATUS" in
  ok)        BRANCH_ORDER_LABEL="[OK]" ;;
  violation) BRANCH_ORDER_LABEL="[VIOLATION]" ;;
  skipped)   BRANCH_ORDER_LABEL="[SKIP]" ;;
  *)         BRANCH_ORDER_LABEL="[SKIP]" ;;
esac

if [ "$OCM_HIGH" -gt 0 ] || echo "$CONFLICT_JSON" | jq -e '.all_passed == false' > /dev/null 2>&1 || [ "$BRANCH_ORDER_STATUS" = "violation" ]; then
  BADGE="[ACTION REQUIRED]"
elif [ "$OCM_MED" -gt 0 ] || [ "$(echo "$AUDIT_JSON" | jq -r '.missing_count // 0')" -gt 0 ]; then
  BADGE="[REVIEW RECOMMENDED]"
else
  BADGE="[ALL CLEAR]"
fi

# ── Assemble comment body ─────────────────────────────────────────────────────
BODY="${BOT_MARKER}
## AI PR Review — #${PR_NUMBER} · \`${HEAD_BRANCH}\` → \`${BASE_BRANCH}\`

${BADGE}

---

### Conflict Resolution — ${RESOLUTION_STATUS}"

if [ -n "$CONFLICT_TABLE" ]; then
  BODY="${BODY}

| File | Model | Critique | Result |
|------|-------|----------|--------|
${CONFLICT_TABLE}"
fi

BODY="${BODY}

---

### Org Change Management"

if [ "$OCM_SKIPPED" != "true" ] && [ -n "$OCM_TABLE" ]; then
  BODY="${BODY}

| Metadata Type | Count |
|---------------|-------|
${OCM_TABLE}"
fi

if [ -n "$RISK_ROWS" ]; then
  BODY="${BODY}

#### Risk Flags — High: ${OCM_HIGH} · Medium: ${OCM_MED} · Low: ${OCM_LOW}

${RISK_ROWS}"
else
  BODY="${BODY}

#### Risk Flags — [NONE]"
fi

BODY="${BODY}

---

### Package.xml Audit (OCM) — ${AUDIT_STATUS}"

if [ -n "$AUDIT_DETAIL" ]; then
  BODY="${BODY}

${AUDIT_DETAIL}"
fi

if [ -n "$AUDIT_EXPLANATION" ]; then
  BODY="${BODY}

> **AI Analysis:** ${AUDIT_EXPLANATION}"
fi

if [ -n "${NET_NEW:-}" ]; then
  BODY="${BODY}

**Net-new components vs \`${BASE_BRANCH}\`:**
${NET_NEW}"
fi

if [ -n "${REMOVED:-}" ]; then
  BODY="${BODY}

**Removed components vs \`${BASE_BRANCH}\`:**
${REMOVED}"
fi

BODY="${BODY}

---

### Branch Order — ${BRANCH_ORDER_LABEL} ${BRANCH_ORDER_MSG}
Pipeline: \`${BRANCH_ORDER_PIPELINE}\`"

BODY="${BODY}

---
*Generated by AI PR Review Bot · Human approval required · Bot will not merge*"

# ── Post or update comment ────────────────────────────────────────────────────
echo "==> Checking for existing bot comment on PR #$PR_NUMBER"

EXISTING_ID=$(gh api "repos/$REPO/issues/$PR_NUMBER/comments" \
  --jq ".[] | select(.body | startswith(\"$BOT_MARKER\")) | .id" \
  2>/dev/null | head -1 || true)

if [ -n "$EXISTING_ID" ]; then
  echo "==> Updating existing comment ID: $EXISTING_ID"
  gh api --method PATCH "repos/$REPO/issues/comments/$EXISTING_ID" \
    -f body="$BODY" > /dev/null
  echo "==> Comment updated."
else
  echo "==> Posting new comment on PR #$PR_NUMBER"
  gh pr comment "$PR_NUMBER" --repo "$REPO" --body "$BODY"
  echo "==> Comment posted."
fi
