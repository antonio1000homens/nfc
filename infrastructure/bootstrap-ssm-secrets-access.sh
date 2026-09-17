#!/usr/bin/env bash
set -euo pipefail

AWS_REGION="${AWS_REGION:-eu-west-2}"
DEPLOYMENT_ROLE_NAME="${DEPLOYMENT_ROLE_NAME:-GitHubActionsNfcDeployRole}"
POLICY_NAME="${POLICY_NAME:-nfc-ssm-read}"
REQUIRED_API_KEY_PARAMETER="${REQUIRED_API_KEY_PARAMETER:-/lambdas/nfc/required-api-key}"
SLACK_SIGNING_SECRET_PARAMETER="${SLACK_SIGNING_SECRET_PARAMETER:-/lambdas/aws2022-slack-handler/slack-signing-secret}"
CLOUDFLARE_API_TOKEN_PARAMETER="${CLOUDFLARE_API_TOKEN_PARAMETER:-/nfc/cloudflare/api-token}"

account_id="$(aws sts get-caller-identity --query Account --output text --region "${AWS_REGION}")"
caller_arn="$(aws sts get-caller-identity --query Arn --output text --region "${AWS_REGION}")"
partition="$(cut -d: -f2 <<<"${caller_arn}")"
aws iam get-role --role-name "${DEPLOYMENT_ROLE_NAME}" --query 'Role.Arn' --output text --region "${AWS_REGION}" >/dev/null

[[ -n "${account_id}" && "${account_id}" != "None" ]] || { echo 'Unable to resolve AWS account ID.' >&2; exit 1; }
[[ -n "${partition}" ]] || { echo 'Unable to resolve AWS partition.' >&2; exit 1; }

policy_file="$(mktemp)"
trap 'rm -f "${policy_file}"' EXIT

jq -n \
  --arg region "${AWS_REGION}" \
  --arg account "${account_id}" \
  --arg partition "${partition}" \
  --arg api "${REQUIRED_API_KEY_PARAMETER#/}" \
  --arg signing "${SLACK_SIGNING_SECRET_PARAMETER#/}" \
  --arg cloudflare "${CLOUDFLARE_API_TOKEN_PARAMETER#/}" \
  '{Version:"2012-10-17",Statement:[{Sid:"ReadNfcDeploymentParameters",Effect:"Allow",Action:["ssm:GetParameter","ssm:GetParameters"],Resource:[
    "arn:\($partition):ssm:\($region):\($account):parameter/\($api)",
    "arn:\($partition):ssm:\($region):\($account):parameter/\($signing)",
    "arn:\($partition):ssm:\($region):\($account):parameter/\($cloudflare)"
  ]}]}' > "${policy_file}"

aws iam put-role-policy \
  --role-name "${DEPLOYMENT_ROLE_NAME}" \
  --policy-name "${POLICY_NAME}" \
  --policy-document "file://${policy_file}" \
  --region "${AWS_REGION}"

echo "Updated ${POLICY_NAME} on ${DEPLOYMENT_ROLE_NAME}; no secret values were read."
