#!/usr/bin/env bash
set -euo pipefail

AWS_REGION="${AWS_REGION:-eu-west-2}"
STACK_NAME="${OIDC_STACK_NAME:-nfc-github-actions-deploy-role}"
ARTIFACT_PREFIX="${S3_PREFIX:-nfc}"
DEPLOYMENT_ROLE_NAME="${DEPLOYMENT_ROLE_NAME:-GitHubActionsNfcDeployRole}"
REQUIRED_API_KEY_PARAMETER="${REQUIRED_API_KEY_PARAMETER:-/lambdas/nfc/required-api-key}"
SLACK_SIGNING_SECRET_PARAMETER="${SLACK_SIGNING_SECRET_PARAMETER:-/lambdas/aws2022-slack-handler/slack-signing-secret}"
CLOUDFLARE_API_TOKEN_PARAMETER="${CLOUDFLARE_API_TOKEN_PARAMETER:-/nfc/cloudflare/api-token}"

: "${CODE_BUCKET:?CODE_BUCKET is required and must name the existing private deployment-artifact bucket}"

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

aws cloudformation deploy \
  --template-file "${script_dir}/github-actions-deploy-role.yaml" \
  --stack-name "${STACK_NAME}" \
  --region "${AWS_REGION}" \
  --capabilities CAPABILITY_NAMED_IAM \
  --parameter-overrides \
    "CodeBucketName=${CODE_BUCKET}" \
    "ArtifactPrefix=${ARTIFACT_PREFIX}" \
    "DeploymentRoleName=${DEPLOYMENT_ROLE_NAME}" \
    "RequiredApiKeyParameter=${REQUIRED_API_KEY_PARAMETER}" \
    "SlackSigningSecretParameter=${SLACK_SIGNING_SECRET_PARAMETER}" \
    "CloudflareApiTokenParameter=${CLOUDFLARE_API_TOKEN_PARAMETER}"

aws cloudformation describe-stacks \
  --stack-name "${STACK_NAME}" \
  --region "${AWS_REGION}" \
  --query "Stacks[0].Outputs[?OutputKey=='DeploymentRoleArn'].OutputValue | [0]" \
  --output text
