#!/usr/bin/env bash
set -euo pipefail

fail=0
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${repo_root}"

check_pattern() {
  local description="$1"
  local pattern="$2"
  if git grep -nE -- "$pattern" -- ':!scripts/check-public-source.sh' >/tmp/nfc-public-source-scan 2>/dev/null; then
    echo "Public-source check failed: ${description}" >&2
    cat /tmp/nfc-public-source-scan >&2
    fail=1
  fi
}

check_pattern 'AWS account identifier' '(^|[^0-9])[0-9]{12}([^0-9]|$)'
check_pattern 'monorepo-style Lambda deployment bucket' 'aws[0-9]{4}-lambda-code'
check_pattern 'broad Lambda monorepo deployment role' 'GitHubActions[A-Za-z0-9_-]*Lambdas[A-Za-z0-9_-]*DeployRole'
check_pattern 'Bitwarden machine-account credential value' '^[[:space:]]*(export[[:space:]]+)?BWS_(ACCESS_TOKEN|GITHUB_ACTIONS_[A-Z0-9_]+)[[:space:]]*=[[:space:]]*[^[:space:]#]+'
check_pattern 'Bitwarden secret UUID literal' '(^|[^0-9A-Fa-f])[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[1-5][0-9A-Fa-f]{3}-[89ABab][0-9A-Fa-f]{3}-[0-9A-Fa-f]{12}([^0-9A-Fa-f]|$)'
check_pattern 'AWS access key-shaped value' 'AKIA[0-9A-Z]{16}'
check_pattern 'Google API key-shaped value' 'AIza[0-9A-Za-z_-]{35}'
check_pattern 'private key material' '-----BEGIN (RSA |EC |OPENSSH |)?PRIVATE KEY-----'

if git grep -nE 'bitwarden/sm-action|bws secret get|bws secret list' -- '.github/workflows/*.yml' '.github/workflows/*.yaml' >/tmp/nfc-public-workflow-scan 2>/dev/null; then
  echo 'Public-source check failed: production/CI workflows must not depend on Bitwarden.' >&2
  cat /tmp/nfc-public-workflow-scan >&2
  fail=1
fi

tracked_forbidden="$(git ls-files | grep -E '(^|/)migration-backup/|(^|/)node_modules/|(^|/)dist/|\.zip$|(^|/)\.env$|(^|/)\.env\.[^e]|(^|/)(get-function|stack-export|aws-export|resource-export)[^/]*\.(json|ya?ml)$' || true)"
if [[ -n "${tracked_forbidden}" ]]; then
  echo 'Public-source check failed: generated/private files are tracked:' >&2
  printf '%s\n' "${tracked_forbidden}" >&2
  fail=1
fi

if [[ "${fail}" -ne 0 ]]; then
  exit 1
fi

echo 'Public-source checks passed.'
