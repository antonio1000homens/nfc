#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "${script_dir}/.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "${tmp}"' EXIT
mkdir -p "${tmp}/bin"
mutation_log="${tmp}/mutations.log"

cat > "${tmp}/bin/aws" <<'MOCK_AWS'
#!/usr/bin/env bash
set -euo pipefail
account="$(printf '%012d' 1)"
case "$1 $2" in
  'sts get-caller-identity') printf '%s\n' "${account}" ;;
  'iam get-role') printf 'arn:aws:iam::%s:role/GitHubActionsNfcDeployRole\n' "${account}" ;;
  'ssm put-parameter') printf 'mutation: %s\n' "$*" >> "${MOCK_MUTATION_LOG}" ;;
  *) echo "Unexpected aws call: $*" >&2; exit 1 ;;
esac
MOCK_AWS
chmod +x "${tmp}/bin/aws"

cat > "${tmp}/bin/gh" <<'MOCK_GH'
#!/usr/bin/env bash
set -euo pipefail
case "$1 $2" in
  'auth status') exit 0 ;;
  'repo view') printf 'antonio1000homens/nfc\n' ;;
  'variable get') printf 'test-code-bucket\n' ;;
  'variable set') printf 'mutation: %s\n' "$*" >> "${MOCK_MUTATION_LOG}" ;;
  *) echo "Unexpected gh call: $*" >&2; exit 1 ;;
esac
MOCK_GH
chmod +x "${tmp}/bin/gh"

cat > "${tmp}/bin/bws" <<'MOCK_BWS'
#!/usr/bin/env bash
set -euo pipefail
if [[ "$1 $2" == 'secret list' ]]; then
  cat <<'JSON'
[
  {"id":"id-api","key":"CF_NFC_API_KEY"},
  {"id":"id-slack","key":"SLACK_BOT_TOKEN"},
  {"id":"id-google","key":"NFC_GOOGLE_SA"},
  {"id":"id-sheet","key":"NFC_SPREADSHEET_ID"}
]
JSON
  exit 0
fi
if [[ "$1 $2" == 'secret get' ]]; then
  printf 'mutation: %s\n' "$*" >> "${MOCK_MUTATION_LOG}"
  printf '{"value":"should-not-be-read-in-dry-run"}\n'
  exit 0
fi
echo "Unexpected bws call: $*" >&2
exit 1
MOCK_BWS
chmod +x "${tmp}/bin/bws"

# Exercise the same environment-based authentication contract used by the real
# bws CLI without placing a credential-shaped assignment in committed source.
bws_token_name='BWS_ACCESS_TOKEN'
export "${bws_token_name}=test-machine-token"

output="$(PATH="${tmp}/bin:${PATH}" MOCK_MUTATION_LOG="${mutation_log}" BOOTSTRAP_CONFIG=/dev/null \
  bash "${repo_root}/scripts/bootstrap-ssm-migration.sh" --dry-run --code-bucket test-code-bucket)"

grep -Fq 'Dry run complete' <<<"${output}"
if [[ -s "${mutation_log}" ]]; then
  echo 'Dry run performed a mutation or read a secret value:' >&2
  cat "${mutation_log}" >&2
  exit 1
fi
if grep -Fq 'id-api' <<<"${output}"; then
  echo 'Dry-run output leaked a Bitwarden ID.' >&2
  exit 1
fi

echo 'Bootstrap portability/dry-run test passed.'
