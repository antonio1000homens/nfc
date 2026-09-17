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

request_file="$(mktemp)"
chmod 600 "${request_file}"
trap 'rm -f "${request_file}"' EXIT

jq -n \
  --arg name "${CLOUDFLARE_API_TOKEN_PARAMETER}" \
  --arg value "${token}" \
  '{Name:$name,Type:"SecureString",Tier:"Standard",Value:$value,Overwrite:true}' \
  > "${request_file}"
unset token

aws ssm put-parameter \
  --region "${AWS_REGION}" \
  --cli-input-json "file://${request_file}" \
  >/dev/null

rm -f "${request_file}"
trap - EXIT

echo "Stored dedicated NFC Cloudflare deployment token at ${CLOUDFLARE_API_TOKEN_PARAMETER}."
