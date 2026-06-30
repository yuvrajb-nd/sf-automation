#!/usr/bin/env bash
# OCM: Categorises changed files by Salesforce metadata type and flags high-risk patterns.
# Outputs /tmp/ocm_report.json
set -euo pipefail

PR_NUMBER="${1:-${PR_NUMBER:?'PR_NUMBER required'}}"
REPO="${2:-${REPO:?'REPO required'}}"
BASE_BRANCH="${3:-${BASE_BRANCH:?'BASE_BRANCH required'}}"
REPO_ROOT="${REPO_ROOT:-$(git rev-parse --show-toplevel)}"
OCM_FILE="/tmp/ocm_report.json"

# ── Get changed files via gh CLI ──────────────────────────────────────────────
echo "==> Fetching changed files for PR #$PR_NUMBER"
CHANGED_FILES=$(gh pr view "$PR_NUMBER" --repo "$REPO" --json files \
  --jq '.files[].path' 2>/dev/null || \
  git diff --name-only "origin/$BASE_BRANCH"...HEAD 2>/dev/null || true)

if [ -z "$CHANGED_FILES" ]; then
  echo "==> No changed files detected."
  echo '{"skipped":true,"reason":"no_changed_files"}' > "$OCM_FILE"
  exit 0
fi

echo "$CHANGED_FILES" > /tmp/changed_files.txt
echo "==> $(echo "$CHANGED_FILES" | wc -l | tr -d ' ') file(s) changed"

# ── Categorise by path pattern ────────────────────────────────────────────────
declare -A COUNTS
RISK_FLAGS=()

categorise() {
  local f="$1"
  case "$f" in
    */classes/*.cls)                          echo "ApexClass" ;;
    */triggers/*.trigger)                     echo "ApexTrigger" ;;
    */lwc/*)                                  echo "LWC" ;;
    */aura/*)                                 echo "AuraBundle" ;;
    */flows/*.flow-meta.xml)                  echo "Flow" ;;
    */objects/*/fields/*.field-meta.xml)      echo "CustomField" ;;
    */objects/*/validationRules/*)            echo "ValidationRule" ;;
    */objects/*.object-meta.xml|*/objects/*/) echo "CustomObject" ;;
    */profiles/*.profile-meta.xml)            echo "Profile" ;;
    */permissionsets/*.permissionset-meta.xml) echo "PermissionSet" ;;
    */layouts/*.layout-meta.xml)              echo "Layout" ;;
    */namedCredentials/*)                     echo "NamedCredential" ;;
    */connectedApps/*)                        echo "ConnectedApp" ;;
    */staticresources/*)                      echo "StaticResource" ;;
    */email/*)                                echo "EmailTemplate" ;;
    */labels/*)                               echo "CustomLabel" ;;
    manifest/*.xml)                           echo "PackageManifest" ;;
    *)                                        echo "Other" ;;
  esac
}

while IFS= read -r filepath; do
  [ -z "$filepath" ] && continue
  TYPE=$(categorise "$filepath")
  COUNTS[$TYPE]=$((${COUNTS[$TYPE]:-0} + 1))
done < /tmp/changed_files.txt

# ── High-risk flags ───────────────────────────────────────────────────────────
# Get diff of added lines only
DIFF_ADDED=$(git diff "origin/$BASE_BRANCH"...HEAD -- '*.cls' '*.trigger' 2>/dev/null \
  | grep '^+' | grep -v '^+++' || true)

# SOQL inside for loops
if echo "$DIFF_ADDED" | grep -qiE '\[SELECT[[:space:]]'; then
  SOQL_IN_LOOP=$(git diff "origin/$BASE_BRANCH"...HEAD -- '*.cls' '*.trigger' 2>/dev/null \
    | grep -n '^\+.*\[SELECT' | grep -v '^+++' \
    | sed 's/^/  /' | head -10 || true)
  if [ -n "$SOQL_IN_LOOP" ]; then
    RISK_FLAGS+=('{"severity":"high","type":"soql_in_loop","message":"Potential SOQL inside loop detected","detail":"'"$(echo "$SOQL_IN_LOOP" | head -3 | tr '\n' '|')"'"}')
  fi
fi

# Hardcoded Salesforce record IDs (15 or 18 char alphanumeric starting with known prefixes)
HARDCODED_IDS=$(echo "$DIFF_ADDED" | grep -oE "['\"][a-zA-Z0-9]{15,18}['\"]" | grep -v "test\|Test\|mock\|Mock" | head -5 || true)
if [ -n "$HARDCODED_IDS" ]; then
  RISK_FLAGS+=('{"severity":"high","type":"hardcoded_id","message":"Potential hardcoded Salesforce record ID detected","detail":"'"$(echo "$HARDCODED_IDS" | tr '\n' ' ')"'"}')
fi

# Profile or PermissionSet changes
if echo "$CHANGED_FILES" | grep -qE "profiles/|permissionsets/"; then
  RISK_FLAGS+=('{"severity":"medium","type":"profile_permset_change","message":"Profile or Permission Set modified — verify access changes with admin"}')
fi

# Named Credential or Connected App changes
if echo "$CHANGED_FILES" | grep -qE "namedCredentials/|connectedApps/"; then
  RISK_FLAGS+=('{"severity":"high","type":"credential_change","message":"Named Credential or Connected App modified — security review required"}')
fi

# Flow file deletions
DELETED_FLOWS=$(git diff --name-only --diff-filter=D "origin/$BASE_BRANCH"...HEAD \
  | grep '\.flow-meta\.xml' || true)
if [ -n "$DELETED_FLOWS" ]; then
  RISK_FLAGS+=('{"severity":"high","type":"flow_deletion","message":"Flow file(s) deleted — verify no active automation depends on these","detail":"'"$(echo "$DELETED_FLOWS" | tr '\n' ' ')"'"}')
fi

# Custom Field deletions
DELETED_FIELDS=$(git diff --name-only --diff-filter=D "origin/$BASE_BRANCH"...HEAD \
  | grep '\.field-meta\.xml' || true)
if [ -n "$DELETED_FIELDS" ]; then
  RISK_FLAGS+=('{"severity":"high","type":"field_deletion","message":"Custom Field metadata deleted — data loss risk in org","detail":"'"$(echo "$DELETED_FIELDS" | tr '\n' ' ')"'"}')
fi

# System.debug left in code
DEBUG_COUNT=$(echo "$DIFF_ADDED" | grep -c 'System\.debug' || true)
if [ "$DEBUG_COUNT" -gt 0 ]; then
  RISK_FLAGS+=("{\"severity\":\"low\",\"type\":\"system_debug\",\"message\":\"$DEBUG_COUNT System.debug statement(s) found — remove before production\"}")
fi

# ── Build JSON ────────────────────────────────────────────────────────────────
COUNTS_JSON=$(for key in "${!COUNTS[@]}"; do
  echo "{\"type\":\"$key\",\"count\":${COUNTS[$key]}}"
done | jq -s '.')

FLAGS_JSON=$(printf '%s\n' "${RISK_FLAGS[@]+"${RISK_FLAGS[@]}"}" \
  | jq -Rs 'split("\n") | map(select(. != "")) | map(fromjson)')

HIGH_COUNT=$(echo "$FLAGS_JSON" | jq '[.[] | select(.severity=="high")] | length')
MED_COUNT=$(echo "$FLAGS_JSON"  | jq '[.[] | select(.severity=="medium")] | length')
LOW_COUNT=$(echo "$FLAGS_JSON"  | jq '[.[] | select(.severity=="low")] | length')

jq -n \
  --argjson categories "$COUNTS_JSON" \
  --argjson risk_flags "$FLAGS_JSON" \
  --argjson high "$HIGH_COUNT" \
  --argjson medium "$MED_COUNT" \
  --argjson low "$LOW_COUNT" \
  '{
    categories: $categories,
    risk_flags: $risk_flags,
    risk_summary: {high: $high, medium: $medium, low: $low}
  }' > "$OCM_FILE"

echo "==> OCM categorisation complete. Risk: High=$HIGH_COUNT Med=$MED_COUNT Low=$LOW_COUNT"
echo "OCM_HIGH=$HIGH_COUNT" >> "${GITHUB_OUTPUT:-/tmp/gha_output.txt}"
echo "OCM_MED=$MED_COUNT"   >> "${GITHUB_OUTPUT:-/tmp/gha_output.txt}"
echo "OCM_LOW=$LOW_COUNT"   >> "${GITHUB_OUTPUT:-/tmp/gha_output.txt}"
