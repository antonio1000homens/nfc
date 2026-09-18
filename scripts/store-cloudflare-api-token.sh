#!/usr/bin/env bash
set -euo pipefail

AWS_REGION="${AWS_REGION:-eu-west-2}"
CLOUDFLARE_API_TOKEN_PARAMETER="${CLOUDFLARE_API_TOKEN_PARAMETER:-/nfc/cloudflare/api-token}"

command -v aws >/dev/null 2>&1 || { echo 'aws CLI is required.' >&2; exit 1; }
command -v jq >/dev/null 2>&1 || { echo 'jq is required.' >&2; exit 1; }

if [[ -t 0 ]]; then
  read -r -s -p 'Dedicated NFC Cloudflare API token: ' token
  printf '\n' >&2
else
  IFS= read -r token
fi

if [[ -z "${token}" ]]; then
  echo 'Cloudflare API token must not be empty.' >&2
  exit 1
fi

secret_dir="$(mktemp -d)"
chmod 700 "${secret_dir}"
token_file="${secret_dir}/token"
request_file="${secret_dir}/request.json"
trap 'rm -rf "${secret_dir}"' EXIT

printf '%s' "${token}" > "${token_file}"
chmod 600 "${token_file}"
unset token

jq -n \
  --arg name "${CLOUDFLARE_API_TOKEN_PARAMETER}" \
  --rawfile value "${token_file}" \
  '{Name:$name,Type:"SecureString",Tier:"Standard",Value:$value,Overwrite:true}' \
  > "${request_file}"
chmod 600 "${request_file}"
rm -f "${token_file}"

aws ssm put-parameter \
  --region "${AWS_REGION}" \
  --cli-input-json "file://${request_file}" \
  >/dev/null

rm -rf "${secret_dir}"
trap - EXIT

echo "Stored dedicated NFC Cloudflare deployment token at ${CLOUDFLARE_API_TOKEN_PARAMETER}."
