#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "${tmp}"' EXIT
mkdir -p "${tmp}/bin"
log="${tmp}/aws.log"
policy_copy="${tmp}/policy.json"

cat > "${tmp}/bin/aws" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >> "${MOCK_AWS_LOG}"
account="$(printf '%012d' 1)"
case "$1 $2" in
  'sts get-caller-identity')
    if [[ "$*" == *'--query Account'* ]]; then
      printf '%s\n' "${account}"
    else
      printf 'arn:aws:iam::%s:user/test\n' "${account}"
    fi
    ;;
  'iam get-role')
    printf 'arn:aws:iam::%s:role/GitHubActionsNfcDeployRole\n' "${account}"
    ;;
  'iam put-role-policy')
    for arg in "$@"; do
      if [[ "${arg}" == file://* ]]; then
        cp "${arg#file://}" "${MOCK_POLICY_COPY}"
      fi
    done
    ;;
  *)
    echo "Unexpected aws call: $*" >&2
    exit 1
    ;;
esac
MOCK
chmod +x "${tmp}/bin/aws"

PATH="${tmp}/bin:${PATH}" MOCK_AWS_LOG="${log}" MOCK_POLICY_COPY="${policy_copy}" \
  bash "${script_dir}/bootstrap-ssm-secrets-access.sh" >/dev/null

test -s "${policy_copy}"
grep -Fq 'parameter/lambdas/nfc/required-api-key' "${policy_copy}"
grep -Fq 'parameter/lambdas/shared/slack-bot-token' "${policy_copy}"
grep -Fq 'parameter/lambdas/nfc/sqs2nfc/google-service-account' "${policy_copy}"
if grep -Fq 'ssm:PutParameter' "${policy_copy}"; then
  echo 'SSM access policy unexpectedly grants write access.' >&2
  exit 1
fi

echo 'SSM access bootstrap test passed.'
