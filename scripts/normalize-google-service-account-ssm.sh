#!/usr/bin/env bash
set -euo pipefail

AWS_REGION="${AWS_REGION:-eu-west-2}"
GOOGLE_SERVICE_ACCOUNT_PARAMETER="${GOOGLE_SERVICE_ACCOUNT_PARAMETER:-/lambdas/nfc/sqs2nfc/google-service-account}"

for command_name in aws jq base64; do
  command -v "${command_name}" >/dev/null 2>&1 || {
    echo "Required command not found: ${command_name}" >&2
    exit 1
  }
done

work_dir="$(mktemp -d)"
trap 'rm -rf "${work_dir}"' EXIT
chmod 700 "${work_dir}"
raw_file="${work_dir}/raw"
json_file="${work_dir}/canonical.json"
request_file="${work_dir}/put-parameter.json"
chmod 600 "${raw_file}" "${json_file}" "${request_file}"

aws ssm get-parameter \
  --region "${AWS_REGION}" \
  --name "${GOOGLE_SERVICE_ACCOUNT_PARAMETER}" \
  --with-decryption \
  --query 'Parameter.Value' \
  --output text > "${raw_file}"

if jq -ce . "${raw_file}" > "${json_file}" 2>/dev/null; then
  :
elif base64 --decode < "${raw_file}" | jq -ce . > "${json_file}" 2>/dev/null; then
  :
elif base64 -D < "${raw_file}" | jq -ce . > "${json_file}" 2>/dev/null; then
  :
else
  echo 'The SSM value is neither JSON nor base64-encoded JSON.' >&2
  exit 1
fi

jq -e 'type == "object" and .type == "service_account"' "${json_file}" >/dev/null || {
  echo 'The normalized value is not a Google service-account JSON object.' >&2
  exit 1
}

jq -n \
  --arg name "${GOOGLE_SERVICE_ACCOUNT_PARAMETER}" \
  --rawfile value "${json_file}" \
  '{Name:$name,Type:"SecureString",Value:$value,Overwrite:true}' > "${request_file}"

aws ssm put-parameter \
  --region "${AWS_REGION}" \
  --cli-input-json "file://${request_file}" >/dev/null

echo "Normalized ${GOOGLE_SERVICE_ACCOUNT_PARAMETER} in SSM without printing its value."
