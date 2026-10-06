#!/usr/bin/env bash
# Converging two-cloud infrastructure deploy. Used by .github/workflows/deploy.yml
# and runnable locally from VS Code (Tasks: "Deploy infra (both clouds)").
#
# Why this order: each cloud needs one value from the other
#   AWS   needs the Azure static-site host   (CloudFront failover origin + CORS)
#   Azure needs the CloudFront origin        (Function CORS)
# On the very first run neither exists yet, so AWS is applied a second time.
set -euo pipefail

cd "$(dirname "$0")/.."
AWS_DIR=infra/aws
AZ_DIR=infra/azure
: "${OWNER_EMAIL:?set OWNER_EMAIL}"
: "${AWS_BACKEND_CONFIG:?path to AWS backend.hcl}"
: "${AZURE_BACKEND_CONFIG:?path to Azure backend.hcl}"
DEPLOYER_OBJECT_ID="${DEPLOYER_OBJECT_ID:-}"

tf() { terraform -chdir="$1" "${@:2}"; }
out() { tf "$1" output -raw "$2" 2>/dev/null || true; }
mkdir -p evidence

# plan -> policy gate -> apply exactly the plan that passed (SOX change control)
plan_apply() {
  local dir="$1" cloud; shift
  cloud="$(basename "$dir")"
  tf "$dir" plan -input=false -out=tfplan "$@"
  local plan_json; plan_json="$(mktemp)"
  tf "$dir" show -json tfplan > "$plan_json"
  if ! conftest test "$plan_json" --policy policies/opa --namespace "terraform.$cloud" --no-color \
       | tee -a "evidence/deploy-policy-$cloud.txt"; then
    rm -f "$plan_json"; echo "Policy gate failed for $cloud; nothing applied." >&2; exit 1
  fi
  rm -f "$plan_json"
  tf "$dir" apply -input=false tfplan
}

tf "$AWS_DIR" init -input=false -backend-config="$AWS_BACKEND_CONFIG"
tf "$AZ_DIR" init -input=false -backend-config="$AZURE_BACKEND_CONFIG"

AZ_HOST="$(out "$AZ_DIR" website_host)"
AZ_ORIGIN="${AZ_HOST:+https://$AZ_HOST}"

echo "::group::AWS apply (standby host: ${AZ_HOST:-none yet})"
plan_apply "$AWS_DIR" \
  -var "owner_email=$OWNER_EMAIL" -var "standby_web_host=$AZ_HOST" -var "standby_web_origin=$AZ_ORIGIN"
echo "::endgroup::"
CF_ORIGIN="$(out "$AWS_DIR" website_url)"

echo "::group::Azure apply (primary origin: $CF_ORIGIN)"
plan_apply "$AZ_DIR" \
  -var "owner_email=$OWNER_EMAIL" -var "primary_web_origin=$CF_ORIGIN" -var "deployer_object_id=$DEPLOYER_OBJECT_ID"
echo "::endgroup::"

NEW_AZ_HOST="$(out "$AZ_DIR" website_host)"
if [[ "$NEW_AZ_HOST" != "$AZ_HOST" ]]; then
  echo "::group::AWS re-apply to wire the new Azure failover origin"
  plan_apply "$AWS_DIR" \
    -var "owner_email=$OWNER_EMAIL" -var "standby_web_host=$NEW_AZ_HOST" -var "standby_web_origin=https://$NEW_AZ_HOST"
  echo "::endgroup::"
fi

# Hand outputs to later workflow steps.
if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
  {
    echo "aws_api_url=$(out "$AWS_DIR" api_url)"
    echo "aws_web_bucket=$(out "$AWS_DIR" web_bucket)"
    echo "aws_cf_id=$(out "$AWS_DIR" cloudfront_distribution_id)"
    echo "aws_web_url=$(out "$AWS_DIR" website_url)"
    echo "aws_orders_table=$(out "$AWS_DIR" orders_table)"
    echo "aws_contacts_table=$(out "$AWS_DIR" contacts_table)"
    echo "az_api_url=$(out "$AZ_DIR" api_url)"
    echo "az_func_name=$(out "$AZ_DIR" function_app_name)"
    echo "az_web_account=$(out "$AZ_DIR" web_storage_account)"
    echo "az_web_url=$(out "$AZ_DIR" website_url)"
    echo "az_rg=$(out "$AZ_DIR" resource_group)"
    echo "az_cosmos_endpoint=$(out "$AZ_DIR" cosmos_endpoint)"
  } >> "$GITHUB_OUTPUT"
fi
