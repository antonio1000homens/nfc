#!/usr/bin/env bash
set -euo pipefail

mode="${1:-}"
AWS_REGION="${AWS_REGION:-eu-west-2}"
REQUIRED_API_KEY_PARAMETER="${REQUIRED_API_KEY_PARAMETER:-/lambdas/nfc/required-api-key}"
SLACK_SIGNING_SECRET_PARAMETER="${SLACK_SIGNING_SECRET_PARAMETER:-/lambdas/aws2022-slack-handler/slack-signing-secret}"
CLOUDFLARE_API_TOKEN_PARAMETER="${CLOUDFLARE_API_TOKEN_PARAMETER:-/nfc/cloudflare/api-token}"

if [[ -z "${GITHUB_ENV:-}" ]]; then
  echo 'GITHUB_ENV is required; this script is intended for GitHub Actions.' >&2
  exit 1
fi

load_parameter() {
  local env_name="$1"
  local parameter_name="$2"
  local value

  if [[ -z "${parameter_name}" ]]; then
    echo "SSM parameter name for ${env_name} is empty." >&2
    exit 1
  fi

  if ! value="$(aws ssm get-parameter \
      --name "${parameter_name}" \
      --with-decryption \
      --region "${AWS_REGION}" \
      --query 'Parameter.Value' \
      --output text)"; then
    echo "Unable to load required SSM parameter: ${parameter_name}" >&2
    exit 1
  fi

  if [[ -z "${value}" || "${value}" == "None" ]]; then
    echo "SSM parameter is empty: ${parameter_name}" >&2
    exit 1
  fi

  echo "::add-mask::${value}"
  {
    echo "${env_name}<<__SSM_${env_name}__"
    printf '%s\n' "${value}"
    echo "__SSM_${env_name}__"
  } >> "${GITHUB_ENV}"
  unset value
}

case "${mode}" in
  cloudflare)
    load_parameter CLOUDFLARE_API_TOKEN "${CLOUDFLARE_API_TOKEN_PARAMETER}"
    load_parameter CF_NFC_API_KEY "${REQUIRED_API_KEY_PARAMETER}"
    load_parameter AWS2022_SIGNING_SECRET "${SLACK_SIGNING_SECRET_PARAMETER}"
    ;;

  *)
    echo 'Usage: scripts/load-ssm-secrets.sh cloudflare' >&2
    exit 2
    ;;
esac
