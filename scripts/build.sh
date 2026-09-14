#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
dist_dir="${repo_root}/dist"

for command_name in npm zip unzip; do
  command -v "${command_name}" >/dev/null 2>&1 || {
    echo "Required command not found: ${command_name}" >&2
    exit 1
  }
done

rm -rf "${dist_dir}"
mkdir -p "${dist_dir}"

(
  cd "${repo_root}/lambda-layer/nodejs"
  npm ci --omit=dev
)

(
  cd "${repo_root}/lambda-layer"
  zip -qr "${dist_dir}/lambda-layer.zip" nodejs
)

(
  cd "${repo_root}"
  zip -q "${dist_dir}/nfc2sqs-lambda.zip" nfc2sqs/nfc2sqs.mjs
  zip -q "${dist_dir}/sqs2nfc-lambda.zip" sqs2nfc/sqs2nfc.mjs
)

for artifact in \
  "${dist_dir}/lambda-layer.zip" \
  "${dist_dir}/nfc2sqs-lambda.zip" \
  "${dist_dir}/sqs2nfc-lambda.zip"; do
  test -s "${artifact}"
  unzip -tq "${artifact}" >/dev/null
done

echo "Built NFC deployment artifacts in ${dist_dir}."
