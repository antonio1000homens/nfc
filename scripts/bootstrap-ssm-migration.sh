#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "${script_dir}/.." && pwd)"
default_config_file="${repo_root}/config/bootstrap-ssm-migration.env"
CONFIG_FILE="${BOOTSTRAP_CONFIG:-${default_config_file}}"
config_explicit=false

args=("$@")
for ((i = 0; i < ${#args[@]}; i++)); do
  if [[ "${args[$i]}" == "--config" ]]; then
    if ((i + 1 >= ${#args[@]})); then
      echo '--config requires a value.' >&2
      exit 2
    fi
    CONFIG_FILE="${args[$((i + 1))]}"
    config_explicit=true
    ((i += 1))
  fi
done

if [[ -f "${CONFIG_FILE}" ]]; then
  set -a
  # shellcheck disable=SC1090
  source "${CONFIG_FILE}"
  set +a
elif [[ "${config_explicit}" == "true" ]]; then
  echo "Configuration file not found: ${CONFIG_FILE}" >&2
  exit 1
fi

REPO="${REPO:-antonio1000homens/nfc}"
GH_ENVIRONMENT="${GH_ENVIRONMENT:-production}"
AWS_REGION="${AWS_REGION:-eu-west-2}"
DEPLOYMENT_ROLE_NAME="${DEPLOYMENT_ROLE_NAME:-GitHubActionsNfcDeployRole}"
STACK_NAME="${STACK_NAME:-nfc}"
S3_PREFIX="${S3_PREFIX:-nfc}"
CODE_BUCKET="${CODE_BUCKET:-}"
SPREADSHEET_ID="${SPREADSHEET_ID:-}"
DRY_RUN=false

REQUIRED_API_KEY_PARAMETER="${REQUIRED_API_KEY_PARAMETER:-/lambdas/nfc/required-api-key}"
SLACK_BOT_TOKEN_PARAMETER="${SLACK_BOT_TOKEN_PARAMETER:-/lambdas/shared/slack-bot-token}"
GOOGLE_SERVICE_ACCOUNT_PARAMETER="${GOOGLE_SERVICE_ACCOUNT_PARAMETER:-/lambdas/nfc/sqs2nfc/google-service-account}"
GOOGLE_SERVICE_ACCOUNT_PARAMETER_TIER="${GOOGLE_SERVICE_ACCOUNT_PARAMETER_TIER:-Standard}"

usage() {
  cat <<EOF_HELP
Usage: scripts/bootstrap-ssm-migration.sh [options]

One-time NFC bootstrap that imports/refreshes runtime secrets from Bitwarden into
AWS SSM Parameter Store and writes only non-secret deployment configuration to
the protected GitHub production environment. Normal GitHub deployments do not
run this script and do not retrieve secret values.

Default local config:
  ${default_config_file}

Options:
  --config FILE              Load a different local configuration file
  --repo OWNER/REPO          GitHub repository (default: antonio1000homens/nfc)
  --environment NAME         GitHub Actions environment (default: production)
  --region REGION            AWS region (default: eu-west-2)
  --role-name NAME           Existing GitHub OIDC deploy role name
  --code-bucket NAME         Private deployment-artifact bucket
  --stack-name NAME          NFC CloudFormation stack name (default: nfc)
  --s3-prefix PREFIX         NFC artifact prefix (default: nfc)
  --dry-run                  Validate auth/mapping/config without reading values or mutating AWS/GitHub
  -h, --help                 Show this help

Optional Bitwarden ID overrides (IDs only, never values):
  BW_CF_NFC_API_KEY
  BW_AWS2022_AWS_SLACK_BOT
  BW_NFC_GOOGLE_SA
  BW_NFC_SPREADSHEET_ID
EOF_HELP
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --config) shift 2 ;;
    --repo) REPO="${2:?--repo requires a value}"; shift 2 ;;
    --environment) GH_ENVIRONMENT="${2:?--environment requires a value}"; shift 2 ;;
    --region) AWS_REGION="${2:?--region requires a value}"; shift 2 ;;
    --role-name) DEPLOYMENT_ROLE_NAME="${2:?--role-name requires a value}"; shift 2 ;;
    --code-bucket) CODE_BUCKET="${2:?--code-bucket requires a value}"; shift 2 ;;
    --stack-name) STACK_NAME="${2:?--stack-name requires a value}"; shift 2 ;;
    --s3-prefix) S3_PREFIX="${2:?--s3-prefix requires a value}"; shift 2 ;;
    --dry-run) DRY_RUN=true; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown option: $1" >&2; usage >&2; exit 2 ;;
  esac
done

for command_name in aws gh bws jq; do
  command -v "${command_name}" >/dev/null 2>&1 || {
    echo "Required command not found: ${command_name}" >&2
    exit 1
  }
done

printf 'Checking AWS authentication... '
AWS_ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text --region "${AWS_REGION}")"
echo 'ok'

printf 'Checking GitHub authentication... '
gh auth status >/dev/null
GH_REPO="$(gh repo view "${REPO}" --json nameWithOwner --jq .nameWithOwner)"
[[ "${GH_REPO}" == "${REPO}" ]] || { echo "Unexpected repository: ${GH_REPO}" >&2; exit 1; }
echo 'ok'

printf 'Checking Bitwarden Secrets Manager authentication... '
BITWARDEN_CATALOG="$(bws secret list --output json | jq -ce '[.[] | {id, key}]')"
echo 'ok'

if [[ -z "${CODE_BUCKET}" ]]; then
  CODE_BUCKET="$(gh variable get CODE_BUCKET --env "${GH_ENVIRONMENT}" --repo "${REPO}" 2>/dev/null || true)"
fi
[[ -n "${CODE_BUCKET}" ]] || {
  echo 'CODE_BUCKET is not configured locally or as a GitHub environment variable.' >&2
  exit 1
}

ROLE_ARN="$(aws iam get-role --role-name "${DEPLOYMENT_ROLE_NAME}" --query 'Role.Arn' --output text --region "${AWS_REGION}")"
[[ -n "${ROLE_ARN}" && "${ROLE_ARN}" != "None" ]] || { echo "Unable to resolve ${DEPLOYMENT_ROLE_NAME}." >&2; exit 1; }

resolve_secret_id() {
  local override_name="$1"
  shift
  local override_value="${!override_name:-}"
  local key match
  local matches=()

  if [[ -n "${override_value}" ]]; then
    printf '%s' "${override_value}"
    return 0
  fi

  for key in "$@"; do
    while IFS= read -r match; do
      [[ -n "${match}" ]] && matches+=("${match}")
    done < <(jq -r --arg key "${key}" '.[] | select(.key == $key) | .id' <<<"${BITWARDEN_CATALOG}")
  done

  if [[ ${#matches[@]} -eq 1 ]]; then
    printf '%s' "${matches[0]}"
    return 0
  fi

  if [[ ${#matches[@]} -eq 0 ]]; then
    echo "Unable to find Bitwarden secret for ${override_name}." >&2
  else
    echo "Multiple Bitwarden secrets matched ${override_name}; refusing to guess." >&2
  fi
  echo "Set ${override_name}=<secret-uuid> in the gitignored local config." >&2
  return 1
}

BW_API_ID="$(resolve_secret_id BW_CF_NFC_API_KEY CF_NFC_API_KEY NFC_API_KEY REQUIRED_API_KEY)"
BW_SLACK_ID="$(resolve_secret_id BW_AWS2022_AWS_SLACK_BOT AWS2022_AWS_SLACK_BOT SLACK_BOT_TOKEN)"
BW_GOOGLE_ID="$(resolve_secret_id BW_NFC_GOOGLE_SA NFC_GOOGLE_SA GOOGLE_SERVICE_ACCOUNT_B64 GOOGLE_SERVICE_ACCOUNT_JSON)"
BW_SPREADSHEET_ID=""
if [[ -z "${SPREADSHEET_ID}" ]]; then
  BW_SPREADSHEET_ID="$(resolve_secret_id BW_NFC_SPREADSHEET_ID NFC_SPREADSHEET_ID SPREADSHEET_ID)"
fi

unset AWS_ACCOUNT_ID BITWARDEN_CATALOG

echo 'Resolved all required Bitwarden mappings without printing IDs or values.'
echo "AWS region: ${AWS_REGION}"
echo "GitHub environment: ${REPO}:${GH_ENVIRONMENT}"
echo "Stack name: ${STACK_NAME}"
echo "S3 prefix: ${S3_PREFIX}"

if [[ "${DRY_RUN}" == "true" ]]; then
  echo 'Dry run complete; no secret values were read and no AWS or GitHub changes were made.'
  exit 0
fi

secret_request_dir="$(mktemp -d)"
chmod 700 "${secret_request_dir}"
trap 'rm -rf "${secret_request_dir}"' EXIT

put_secret_parameter() {
  local parameter_name="$1"
  local secret_id="$2"
  local tier="$3"
  local value request_file

  value="$(bws secret get "${secret_id}" --output json | jq -er '.value')"
  [[ -n "${value}" ]] || { echo "Bitwarden returned an empty value for ${parameter_name}." >&2; exit 1; }

  request_file="$(mktemp "${secret_request_dir}/put-parameter.XXXXXX")"
  chmod 600 "${request_file}"
  jq -n --arg name "${parameter_name}" --arg value "${value}" --arg tier "${tier}" \
    '{Name:$name,Type:"SecureString",Tier:$tier,Value:$value,Overwrite:true}' > "${request_file}"
  aws ssm put-parameter --region "${AWS_REGION}" --cli-input-json "file://${request_file}" >/dev/null
  rm -f "${request_file}"
  unset value
  echo "Stored ${parameter_name}"
}

put_secret_parameter "${REQUIRED_API_KEY_PARAMETER}" "${BW_API_ID}" Standard
put_secret_parameter "${SLACK_BOT_TOKEN_PARAMETER}" "${BW_SLACK_ID}" Standard
put_secret_parameter "${GOOGLE_SERVICE_ACCOUNT_PARAMETER}" "${BW_GOOGLE_ID}" "${GOOGLE_SERVICE_ACCOUNT_PARAMETER_TIER}"

if [[ -z "${SPREADSHEET_ID}" ]]; then
  SPREADSHEET_ID="$(bws secret get "${BW_SPREADSHEET_ID}" --output json | jq -er '.value')"
fi
[[ -n "${SPREADSHEET_ID}" ]] || { echo 'Spreadsheet ID is empty.' >&2; exit 1; }

set_gh_variable() {
  gh variable set "$1" --env "${GH_ENVIRONMENT}" --repo "${REPO}" --body "$2"
}

set_gh_variable AWS_REGION "${AWS_REGION}"
set_gh_variable AWS_ROLE_TO_ASSUME "${ROLE_ARN}"
set_gh_variable CODE_BUCKET "${CODE_BUCKET}"
set_gh_variable STACK_NAME "${STACK_NAME}"
set_gh_variable S3_PREFIX "${S3_PREFIX}"
set_gh_variable SPREADSHEET_ID "${SPREADSHEET_ID}"
set_gh_variable REQUIRED_API_KEY_PARAMETER "${REQUIRED_API_KEY_PARAMETER}"
set_gh_variable SLACK_BOT_TOKEN_PARAMETER "${SLACK_BOT_TOKEN_PARAMETER}"
set_gh_variable GOOGLE_SERVICE_ACCOUNT_PARAMETER "${GOOGLE_SERVICE_ACCOUNT_PARAMETER}"

unset SPREADSHEET_ID

echo 'Bootstrap complete. Runtime secrets are in SSM; only non-secret deployment configuration was written to GitHub.'
