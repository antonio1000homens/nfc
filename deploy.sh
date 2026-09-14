#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEMPLATE_FILE="${TEMPLATE_FILE:-${SCRIPT_DIR}/infrastructure/nfc.yaml}"

AWS_REGION="${AWS_REGION:-eu-west-2}"
STACK_NAME="${STACK_NAME:-nfc}"
CODE_BUCKET="${CODE_BUCKET:-}"
S3_PREFIX="${S3_PREFIX:-nfc}"
DEPLOY_ID="${DEPLOY_ID:-$(date -u +%Y%m%d%H%M%S)}"
SKIP_BUILD="${SKIP_BUILD:-false}"
PLAN_ONLY="${PLAN_ONLY:-false}"

NFC_QUEUE_NAME="${NFC_QUEUE_NAME:-nfc}"
NFC2SQS_FUNCTION_NAME="${NFC2SQS_FUNCTION_NAME:-nfc2sqs}"
NFC2SQS_LAYER_NAME="${NFC2SQS_LAYER_NAME:-nfc2sqs-layer}"
NFC2SQS_ROLE_NAME="${NFC2SQS_ROLE_NAME:-nfc2sqs-lambda-role}"
SQS2NFC_FUNCTION_NAME="${SQS2NFC_FUNCTION_NAME:-sqs2nfc}"
SQS2NFC_LAYER_NAME="${SQS2NFC_LAYER_NAME:-sqs2nfc-layer}"
SQS2NFC_ROLE_NAME="${SQS2NFC_ROLE_NAME:-sqs2nfc-lambda-role}"
RUNTIME="${RUNTIME:-nodejs24.x}"
NFC2SQS_HANDLER="${NFC2SQS_HANDLER:-nfc2sqs/nfc2sqs.lambdaHandler}"
SQS2NFC_HANDLER="${SQS2NFC_HANDLER:-sqs2nfc/sqs2nfc.lambdaHandler}"
NFC2SQS_TIMEOUT="${NFC2SQS_TIMEOUT:-30}"
NFC2SQS_MEMORY_SIZE="${NFC2SQS_MEMORY_SIZE:-256}"
SQS2NFC_TIMEOUT="${SQS2NFC_TIMEOUT:-30}"
SQS2NFC_MEMORY_SIZE="${SQS2NFC_MEMORY_SIZE:-512}"
FUNCTION_URL_AUTH_TYPE="${FUNCTION_URL_AUTH_TYPE:-NONE}"
NFC_SLACK_CHANNEL="${NFC_SLACK_CHANNEL:-#nfc}"
SQS2NFC_BATCH_SIZE="${SQS2NFC_BATCH_SIZE:-1}"
SPREADSHEET_ID="${SPREADSHEET_ID:-}"

REQUIRED_API_KEY_PARAMETER="${REQUIRED_API_KEY_PARAMETER:-/lambdas/nfc/required-api-key}"
SLACK_BOT_TOKEN_PARAMETER="${SLACK_BOT_TOKEN_PARAMETER:-/lambdas/shared/slack-bot-token}"
GOOGLE_SERVICE_ACCOUNT_PARAMETER="${GOOGLE_SERVICE_ACCOUNT_PARAMETER:-/lambdas/nfc/sqs2nfc/google-service-account}"

error() {
  echo "ERROR: $*" >&2
  exit 1
}

command -v aws >/dev/null 2>&1 || error "Missing required command: aws"
[ -f "${TEMPLATE_FILE}" ] || error "CloudFormation template not found: ${TEMPLATE_FILE}"
[ -n "${CODE_BUCKET}" ] || error "CODE_BUCKET is required."
[ -n "${SPREADSHEET_ID}" ] || error "SPREADSHEET_ID is required and should be supplied as non-secret deployment configuration."
[ -n "${REQUIRED_API_KEY_PARAMETER}" ] || error "REQUIRED_API_KEY_PARAMETER must not be empty."
[ -n "${SLACK_BOT_TOKEN_PARAMETER}" ] || error "SLACK_BOT_TOKEN_PARAMETER must not be empty."
[ -n "${GOOGLE_SERVICE_ACCOUNT_PARAMETER}" ] || error "GOOGLE_SERVICE_ACCOUNT_PARAMETER must not be empty."

if [ "${SKIP_BUILD}" = "true" ]; then
  for artifact in lambda-layer.zip nfc2sqs-lambda.zip sqs2nfc-lambda.zip; do
    [ -s "${SCRIPT_DIR}/dist/${artifact}" ] || error "SKIP_BUILD=true but dist/${artifact} is missing or empty."
  done
else
  bash "${SCRIPT_DIR}/scripts/build.sh"
fi

NFC2SQS_FUNCTION_CODE_KEY="${S3_PREFIX%/}/${DEPLOY_ID}/nfc2sqs-lambda.zip"
LAYER_CODE_KEY="${S3_PREFIX%/}/${DEPLOY_ID}/lambda-layer.zip"
SQS2NFC_FUNCTION_CODE_KEY="${S3_PREFIX%/}/${DEPLOY_ID}/sqs2nfc-lambda.zip"

aws s3 cp "${SCRIPT_DIR}/dist/nfc2sqs-lambda.zip" "s3://${CODE_BUCKET}/${NFC2SQS_FUNCTION_CODE_KEY}" --region "${AWS_REGION}" --only-show-errors
aws s3 cp "${SCRIPT_DIR}/dist/lambda-layer.zip" "s3://${CODE_BUCKET}/${LAYER_CODE_KEY}" --region "${AWS_REGION}" --only-show-errors
aws s3 cp "${SCRIPT_DIR}/dist/sqs2nfc-lambda.zip" "s3://${CODE_BUCKET}/${SQS2NFC_FUNCTION_CODE_KEY}" --region "${AWS_REGION}" --only-show-errors

deploy_args=(
  aws cloudformation deploy
  --region "${AWS_REGION}"
  --stack-name "${STACK_NAME}"
  --template-file "${TEMPLATE_FILE}"
  --capabilities CAPABILITY_NAMED_IAM
  --no-fail-on-empty-changeset
  --parameter-overrides
  "CodeBucket=${CODE_BUCKET}"
  "Nfc2SqsFunctionCodeKey=${NFC2SQS_FUNCTION_CODE_KEY}"
  "Nfc2SqsLayerCodeKey=${LAYER_CODE_KEY}"
  "Sqs2NfcFunctionCodeKey=${SQS2NFC_FUNCTION_CODE_KEY}"
  "Sqs2NfcLayerCodeKey=${LAYER_CODE_KEY}"
  "NfcQueueName=${NFC_QUEUE_NAME}"
  "Nfc2SqsFunctionName=${NFC2SQS_FUNCTION_NAME}"
  "Nfc2SqsLayerName=${NFC2SQS_LAYER_NAME}"
  "Nfc2SqsRoleName=${NFC2SQS_ROLE_NAME}"
  "Sqs2NfcFunctionName=${SQS2NFC_FUNCTION_NAME}"
  "Sqs2NfcLayerName=${SQS2NFC_LAYER_NAME}"
  "Sqs2NfcRoleName=${SQS2NFC_ROLE_NAME}"
  "Runtime=${RUNTIME}"
  "Nfc2SqsHandler=${NFC2SQS_HANDLER}"
  "Sqs2NfcHandler=${SQS2NFC_HANDLER}"
  "Nfc2SqsTimeout=${NFC2SQS_TIMEOUT}"
  "Nfc2SqsMemorySize=${NFC2SQS_MEMORY_SIZE}"
  "Sqs2NfcTimeout=${SQS2NFC_TIMEOUT}"
  "Sqs2NfcMemorySize=${SQS2NFC_MEMORY_SIZE}"
  "FunctionUrlAuthType=${FUNCTION_URL_AUTH_TYPE}"
  "RequiredApiKeyParameter=${REQUIRED_API_KEY_PARAMETER}"
  "SlackBotTokenParameter=${SLACK_BOT_TOKEN_PARAMETER}"
  "GoogleServiceAccountParameter=${GOOGLE_SERVICE_ACCOUNT_PARAMETER}"
  "SpreadsheetId=${SPREADSHEET_ID}"
  "NfcSlackChannel=${NFC_SLACK_CHANNEL}"
  "Sqs2NfcBatchSize=${SQS2NFC_BATCH_SIZE}"
)

if [ "${PLAN_ONLY}" = "true" ]; then
  deploy_args+=(--no-execute-changeset)
fi

"${deploy_args[@]}"

if [ "${PLAN_ONLY}" = "true" ]; then
  echo "CloudFormation change set created but not executed for ${STACK_NAME}."
else
  status="$(aws cloudformation describe-stacks \
    --region "${AWS_REGION}" \
    --stack-name "${STACK_NAME}" \
    --query 'Stacks[0].StackStatus' \
    --output text)"
  echo "NFC stack status: ${status}"
fi
