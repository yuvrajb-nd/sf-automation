#!/usr/bin/env bash
# OCM: Audits manifest/<BRANCH>_Package.xml against force-app/ repo files.
# Outputs /tmp/package_audit.json with found/missing components and net-new/removed vs base.
set -euo pipefail

HEAD_BRANCH="${1:-${HEAD_BRANCH:?'HEAD_BRANCH required'}}"
BASE_BRANCH="${2:-${BASE_BRANCH:?'BASE_BRANCH required'}}"
REPO_ROOT="${REPO_ROOT:-$(git rev-parse --show-toplevel)}"
MANIFEST_DIR="$REPO_ROOT/manifest"
FORCE_APP="$REPO_ROOT/force-app/main/default"
AUDIT_FILE="/tmp/package_audit.json"
GH_TOKEN="${GH_TOKEN:-}"
GH_MODELS_ENDPOINT="https://models.inference.ai.azure.com/chat/completions"

# ── Locate package.xml ────────────────────────────────────────────────────────
PKG_FILE="$MANIFEST_DIR/${HEAD_BRANCH}_Package.xml"

if [ ! -f "$PKG_FILE" ]; then
  # Fallback: find any *_Package.xml modified in this PR diff
  PKG_FILE=$(git diff --name-only "origin/$BASE_BRANCH"...HEAD \
    | grep -i 'manifest/.*_package\.xml' \
    | head -1 || true)
  [ -n "$PKG_FILE" ] && PKG_FILE="$REPO_ROOT/$PKG_FILE"
fi

if [ -z "$PKG_FILE" ] || [ ! -f "$PKG_FILE" ]; then
  echo "==> No Package.xml found for branch '$HEAD_BRANCH'. Skipping audit."
  echo '{"skipped":true,"reason":"no_package_xml_found"}' > "$AUDIT_FILE"
  echo "PACKAGE_AUDIT_SKIPPED=true" >> "${GITHUB_OUTPUT:-/tmp/gha_output.txt}"
  exit 0
fi

echo "==> Auditing: $PKG_FILE"

# ── Metadata type → file path map ────────────────────────────────────────────
resolve_path() {
  local meta_type="$1"
  local member="$2"
  case "$meta_type" in
    ApexClass)               echo "$FORCE_APP/classes/${member}.cls" ;;
    ApexTrigger)             echo "$FORCE_APP/triggers/${member}.trigger" ;;
    LightningComponentBundle) echo "$FORCE_APP/lwc/${member}" ;;
    AuraDefinitionBundle)    echo "$FORCE_APP/aura/${member}" ;;
    Flow)                    echo "$FORCE_APP/flows/${member}.flow-meta.xml" ;;
    CustomObject)            echo "$FORCE_APP/objects/${member}" ;;
    CustomField)
      local obj member_field
      obj=$(echo "$member" | cut -d. -f1)
      member_field=$(echo "$member" | cut -d. -f2)
      echo "$FORCE_APP/objects/${obj}/fields/${member_field}.field-meta.xml"
      ;;
    Layout)                  echo "$FORCE_APP/layouts/${member}.layout-meta.xml" ;;
    PermissionSet)           echo "$FORCE_APP/permissionsets/${member}.permissionset-meta.xml" ;;
    Profile)                 echo "$FORCE_APP/profiles/${member}.profile-meta.xml" ;;
    CustomTab)               echo "$FORCE_APP/tabs/${member}.tab-meta.xml" ;;
    StaticResource)          echo "$FORCE_APP/staticresources/${member}" ;;
    EmailTemplate)           echo "$FORCE_APP/email/${member}.email-meta.xml" ;;
    CustomLabel)             echo "$FORCE_APP/labels/CustomLabels.labels-meta.xml" ;;
    ValidationRule)
      local obj rule
      obj=$(echo "$member" | cut -d. -f1)
      rule=$(echo "$member" | cut -d. -f2)
      echo "$FORCE_APP/objects/${obj}/validationRules/${rule}.validationRule-meta.xml"
      ;;
    *)                       echo "" ;;
  esac
}

# ── Parse Package.xml ─────────────────────────────────────────────────────────
FOUND_LIST=()
MISSING_LIST=()
CURRENT_TYPE=""

while IFS= read -r line; do
  line=$(echo "$line" | sed 's/^[[:space:]]*//' | sed 's/[[:space:]]*$//')
  if echo "$line" | grep -q "^<name>"; then
    CURRENT_TYPE=$(echo "$line" | sed 's|<name>||;s|</name>||')
  elif echo "$line" | grep -q "^<members>"; then
    MEMBER=$(echo "$line" | sed 's|<members>||;s|</members>||')
    EXPECTED_PATH=$(resolve_path "$CURRENT_TYPE" "$MEMBER")
    if [ -z "$EXPECTED_PATH" ]; then
      FOUND_LIST+=("{\"type\":\"$CURRENT_TYPE\",\"member\":\"$MEMBER\",\"status\":\"unknown_type\"}")
    elif [ -f "$EXPECTED_PATH" ] || [ -d "$EXPECTED_PATH" ]; then
      FOUND_LIST+=("{\"type\":\"$CURRENT_TYPE\",\"member\":\"$MEMBER\",\"status\":\"found\"}")
    else
      MISSING_LIST+=("{\"type\":\"$CURRENT_TYPE\",\"member\":\"$MEMBER\",\"expected_path\":\"$EXPECTED_PATH\",\"status\":\"missing\"}")
    fi
  fi
done < "$PKG_FILE"

FOUND_COUNT=${#FOUND_LIST[@]}
MISSING_COUNT=${#MISSING_LIST[@]}
TOTAL=$((FOUND_COUNT + MISSING_COUNT))

# ── Net-new and removed vs base branch ───────────────────────────────────────
BASE_PKG="$MANIFEST_DIR/${BASE_BRANCH}_Package.xml"
NET_NEW="[]"
REMOVED="[]"
if [ -f "$BASE_PKG" ]; then
  HEAD_MEMBERS=$(grep "<members>" "$PKG_FILE" | sed 's|.*<members>||;s|</members>.*||' | sort)
  BASE_MEMBERS=$(grep "<members>" "$BASE_PKG" | sed 's|.*<members>||;s|</members>.*||' | sort)
  NET_NEW_RAW=$(comm -23 <(echo "$HEAD_MEMBERS") <(echo "$BASE_MEMBERS"))
  REMOVED_RAW=$(comm -13 <(echo "$HEAD_MEMBERS") <(echo "$BASE_MEMBERS"))
  NET_NEW=$(echo "$NET_NEW_RAW" | jq -Rs 'split("\n") | map(select(. != ""))')
  REMOVED=$(echo "$REMOVED_RAW" | jq -Rs 'split("\n") | map(select(. != ""))')
fi

# ── Build JSON ────────────────────────────────────────────────────────────────
FOUND_JSON=$(printf '%s\n' "${FOUND_LIST[@]+"${FOUND_LIST[@]}"}" | jq -Rs 'split("\n") | map(select(. != "")) | map(fromjson)')
MISSING_JSON=$(printf '%s\n' "${MISSING_LIST[@]+"${MISSING_LIST[@]}"}" | jq -Rs 'split("\n") | map(select(. != "")) | map(fromjson)')

jq -n \
  --arg pkg "$PKG_FILE" \
  --argjson found "$FOUND_JSON" \
  --argjson missing "$MISSING_JSON" \
  --argjson net_new "$NET_NEW" \
  --argjson removed "$REMOVED" \
  --argjson total "$TOTAL" \
  --argjson found_count "$FOUND_COUNT" \
  --argjson missing_count "$MISSING_COUNT" \
  '{
    package_file: $pkg,
    total_components: $total,
    found_count: $found_count,
    missing_count: $missing_count,
    found: $found,
    missing: $missing,
    net_new_vs_base: $net_new,
    removed_vs_base: $removed
  }' > "$AUDIT_FILE"

echo "==> Audit complete: $FOUND_COUNT/$TOTAL found, $MISSING_COUNT missing"

# ── GPT-4o-mini via GitHub Models: explain missing components (only if any missing) ──
if [ "$MISSING_COUNT" -gt 0 ] && [ -n "$GH_TOKEN" ]; then
  MISSING_NAMES=$(echo "$MISSING_JSON" | jq -r '.[].member' | paste -sd ', ')
  echo "==> Asking GPT-4o-mini to explain missing components: $MISSING_NAMES"

  MINI_PAYLOAD=$(jq -n \
    --arg missing "$MISSING_NAMES" \
    '{
      model: "gpt-4o-mini",
      max_tokens: 512,
      messages: [
        {
          role: "system",
          content: "You are a Salesforce DevOps expert. Be concise."
        },
        {
          role: "user",
          content: ("These Salesforce components are listed in package.xml but their files are missing from the repository: " + $missing + ". List the most likely causes in 3 bullet points.")
        }
      ]
    }')

  AI_EXPLANATION=$(curl -s "$GH_MODELS_ENDPOINT" \
    -H "Authorization: Bearer $GH_TOKEN" \
    -H "content-type: application/json" \
    -d "$MINI_PAYLOAD" | jq -r '.choices[0].message.content // "Unable to fetch explanation."')

  # Merge explanation into audit JSON
  jq --arg explanation "$AI_EXPLANATION" '. + {missing_explanation: $explanation}' \
    "$AUDIT_FILE" > /tmp/audit_tmp.json && mv /tmp/audit_tmp.json "$AUDIT_FILE"
fi

echo "MISSING_COUNT=$MISSING_COUNT" >> "${GITHUB_OUTPUT:-/tmp/gha_output.txt}"
echo "PACKAGE_AUDIT_SKIPPED=false" >> "${GITHUB_OUTPUT:-/tmp/gha_output.txt}"
