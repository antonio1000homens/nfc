#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
loader="${repo_root}/scripts/load-ssm-secrets.sh"
tmp_dir="$(mktemp -d)"
trap 'rm -rf "${tmp_dir}"' EXIT

mkdir -p "${tmp_dir}/bin"
cat > "${tmp_dir}/bin/aws" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

parameter_name=''
while [[ $# -gt 0 ]]; do
  case "$1" in
    --name)
      parameter_name="$2"
      shift 2
      ;;
    *)
      shift
      ;;
  esac
done

test -n "${parameter_name}" || { echo 'fake aws: --name was not supplied' >&2; exit 1; }
printf 'value-for:%s\n' "${parameter_name}"
EOF
chmod +x "${tmp_dir}/bin/aws"

export PATH="${tmp_dir}/bin:${PATH}"
export AWS_REGION='eu-west-2'
export REQUIRED_API_KEY_PARAMETER='/test/nfc/api-key'
export SLACK_SIGNING_SECRET_PARAMETER='/test/shared/slack-signing-secret'
export CLOUDFLARE_API_TOKEN_PARAMETER='/test/nfc/cloudflare-token'
export GITHUB_ENV="${tmp_dir}/github.env"
: > "${GITHUB_ENV}"

bash "${loader}" cloudflare >/dev/null

grep -Fq 'CLOUDFLARE_API_TOKEN<<__SSM_CLOUDFLARE_API_TOKEN__' "${GITHUB_ENV}"
grep -Fq 'value-for:/test/nfc/cloudflare-token' "${GITHUB_ENV}"
grep -Fq 'CF_NFC_API_KEY<<__SSM_CF_NFC_API_KEY__' "${GITHUB_ENV}"
grep -Fq 'value-for:/test/nfc/api-key' "${GITHUB_ENV}"
grep -Fq 'AWS2022_SIGNING_SECRET<<__SSM_AWS2022_SIGNING_SECRET__' "${GITHUB_ENV}"
grep -Fq 'value-for:/test/shared/slack-signing-secret' "${GITHUB_ENV}"

unset GITHUB_ENV
if bash "${loader}" cloudflare >/dev/null 2>&1; then
  echo 'Expected loader to fail when GITHUB_ENV is missing.' >&2
  exit 1
fi

if GITHUB_ENV="${tmp_dir}/invalid.env" bash "${loader}" invalid >/dev/null 2>&1; then
  echo 'Expected loader to reject an unsupported mode.' >&2
  exit 1
fi

echo 'SSM secret loader tests passed.'
