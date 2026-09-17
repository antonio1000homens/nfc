#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
config_path="${repo_root}/cloudflare/nfcscan/wrangler.toml"
wrangler=(npx --yes wrangler@4)

require_env() {
  local name="$1"
  if [[ -z "${!name:-}" ]]; then
    echo "Missing required environment variable: ${name}" >&2
    exit 1
  fi
}

put_secret() {
  local name="$1"
  local value="$2"
  printf '%s' "${value}" | "${wrangler[@]}" secret put "${name}" --config "${config_path}"
}

require_env CLOUDFLARE_API_TOKEN
require_env CLOUDFLARE_ACCOUNT_ID
require_env CF_NFC_API_KEY
require_env AWS2022_SIGNING_SECRET
require_env NFC2SQS_URL

# Sync the two sensitive Worker bindings from canonical SSM values loaded by
# GitHub Actions. NFC2SQS_URL is intentionally a plain Worker variable because
# the Function URL is non-secret deployment configuration.
put_secret CF_NFC_API_KEY "${CF_NFC_API_KEY}"
put_secret AWS2022_SIGNING_SECRET "${AWS2022_SIGNING_SECRET}"

"${wrangler[@]}" deploy \
  --config "${config_path}" \
  --var "NFC2SQS_URL:${NFC2SQS_URL}"
