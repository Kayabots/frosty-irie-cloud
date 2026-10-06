#!/usr/bin/env bash
# Plan one stack, evaluate the JSON plan with Conftest, keep a redacted record.
# Usage: scripts/plan_and_check.sh aws|azure <backend.hcl> [extra terraform args...]
#
# The full JSON plan contains sensitive values in clear text (for example the
# Functions storage key), so it is deleted after evaluation. Only a redacted
# change list and the policy results are kept as audit evidence.
set -euo pipefail
cd "$(dirname "$0")/.."
CLOUD="$1"; BACKEND="$2"; shift 2
DIR="infra/$CLOUD"
EVID=evidence
mkdir -p "$EVID"
PLAN_JSON="$(mktemp)"
trap 'rm -f "$PLAN_JSON"' EXIT

terraform -chdir="$DIR" init -input=false -backend-config="$BACKEND"
terraform -chdir="$DIR" plan -input=false -lock=false -out=tfplan "$@"
terraform -chdir="$DIR" show -json tfplan > "$PLAN_JSON"

jq '{format_version, terraform_version, timestamp,
     changes: [.resource_changes[] | {address, type, actions: .change.actions}]}' \
   "$PLAN_JSON" > "$EVID/plan-$CLOUD-changes.json"

STATUS=0
conftest test "$PLAN_JSON" --policy policies/opa --namespace "terraform.$CLOUD" \
  --output json > "$EVID/policy-$CLOUD.json" || STATUS=$?
conftest test "$PLAN_JSON" --policy policies/opa --namespace "terraform.$CLOUD" --no-color \
  | tee "$EVID/policy-$CLOUD.txt" || true
exit "$STATUS"
