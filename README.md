# NFC

Standalone NFC service for scan ingestion, queueing and Slack/Google Sheets processing. This repository owns the AWS application/infrastructure and the dedicated Cloudflare `nfcscan` edge Worker that were previously split across the `lambdas` and `windsor-app` repositories.

## Architecture

The production flow is:

```text
NFC client / Slack-originated request
        |
        v
https://nfc.alf-broadcast.co.uk
        |
        v
Cloudflare Worker: nfcscan
  - validates x-api-key
  - validates the migrated Slack-signature contract when headers are present
  - requires realm=nfc
        |
        v
nfc2sqs Lambda Function URL
        |
        v
retained SQS queue: nfc
        |
        v
sqs2nfc
  -> Google Sheets
  -> Slack
```

The Lambda Function URL intentionally uses `AuthType: NONE`; the application API key is still validated by `nfc2sqs` as defence in depth behind the Worker. Do not remove either ingress validation layer without a separately reviewed replacement.

Shared Cloudflare zone/WAF entry-point rules remain centrally owned. This repository owns the NFC Worker/custom domain, but must not create a second zone entry-point ruleset for a Cloudflare phase already managed by another Terraform state.

## Repository layout

- `nfc2sqs/` — public Function URL ingress Lambda;
- `sqs2nfc/` — SQS consumer and Google Sheets/Slack processing;
- `lambda-layer/` — shared Lambda dependencies and SSM helper;
- `infrastructure/nfc.yaml` — NFC application CloudFormation stack;
- `infrastructure/github-actions-deploy-role.yaml` — repository-specific GitHub OIDC deployment role;
- `cloudflare/nfcscan/` — NFC-owned Cloudflare Worker, tests, Wrangler config and deployment helper;
- `scripts/` — build, public-source, SSM bootstrap/load and Cloudflare-token helpers.

## Runtime configuration

Lambda runtime secret values are owned by AWS SSM Parameter Store. The initial standalone cutover deliberately keeps the existing parameter names:

- `/lambdas/nfc/required-api-key`;
- `/lambdas/nfc/sqs2nfc/google-service-account`;
- `/lambdas/shared/slack-bot-token`.

The Slack bot token is a shared external runtime dependency and is not duplicated into an NFC-specific path during this migration.

`SPREADSHEET_ID` is non-secret configuration. Production supplies it as a GitHub `production` environment variable and CloudFormation passes it to `sqs2nfc`.

Normal AWS deployments never retrieve the Google service account or Slack bot token into GitHub Actions and never call `ssm:PutParameter`. Secret import/rotation is separate from normal deployment.

## Cloudflare configuration

The `nfcscan` Worker owns the canonical and only production custom domain `nfc.alf-broadcast.co.uk`. Its deployment uses the same GitHub OIDC AWS session as the application deployment and loads only these SSM values:

- `CF_NFC_API_KEY` from `/lambdas/nfc/required-api-key`;
- `AWS2022_SIGNING_SECRET` from `/lambdas/aws2022-slack-handler/slack-signing-secret`;
- `CLOUDFLARE_API_TOKEN` from `/nfc/cloudflare/api-token` by default.

The Worker API key therefore comes from the same canonical value used by `nfc2sqs`, avoiding two independent copies that can drift. `NFC2SQS_URL` is non-secret and is resolved from the deployed CloudFormation `Nfc2SqsFunctionUrl` output on every production deployment.

The migrated Windsor Worker used a legacy SHA-256 signing calculation for Slack-tagged requests rather than Slack's standard HMAC-SHA256 scheme. The new Worker preserves that deployed behaviour and tests it so the ownership cutover does not silently alter the request contract. Replacing it should be a separate hardening change.

See `cloudflare/nfcscan/README.md` for the Worker contract and Cloudflare ownership boundary.

## Local development

Requirements: Node.js 22+ (CI/deployment uses Node.js 24), npm, `zip`, and `unzip`.

```bash
npm test
npm run check
npm run build
```

Cloudflare-only tests can be run with:

```bash
npm run test:cloudflare
```

Wrangler configuration can be validated without production credentials:

```bash
npx --yes wrangler@4 deploy \
  --config cloudflare/nfcscan/wrangler.toml \
  --dry-run \
  --var 'NFC2SQS_URL:https://example.invalid/'
```

`npm run build` installs Lambda-layer dependencies from the committed lockfile and creates:

- `dist/nfc2sqs-lambda.zip`;
- `dist/sqs2nfc-lambda.zip`;
- `dist/lambda-layer.zip`.

Generated artifacts, Wrangler state and Terraform local state are gitignored.

## CI

`.github/workflows/ci.yml` runs on pull requests and pushes to `master`. It:

- enforces the public-source boundary;
- builds the Lambda layer reproducibly;
- runs Lambda and `nfcscan` Worker tests;
- validates function/layer package contents;
- tests the one-time migration and SSM helpers;
- lints the NFC and GitHub deployment-role CloudFormation templates;
- syntax-checks Cloudflare helpers;
- runs a credential-free Wrangler deployment dry-run;
- publishes the tested `dist/` artifact only for a trusted push to `master`.

PR CI requires no AWS, Cloudflare, SSM or Bitwarden credentials, including fork PRs.

## Production deployment

Production uses the protected GitHub environment named `production` and GitHub OIDC. Configure these existing/non-secret AWS environment variables:

- `AWS_ROLE_TO_ASSUME` — ARN output by `infrastructure/bootstrap-deployment-role.sh`;
- `AWS_REGION` — normally `eu-west-2`;
- `CODE_BUCKET` — private S3 bucket for deployment artifacts;
- `STACK_NAME` — normally `nfc`;
- `S3_PREFIX` — normally `nfc`;
- `SPREADSHEET_ID` — non-secret spreadsheet identifier;
- optional overrides for `REQUIRED_API_KEY_PARAMETER`, `SLACK_BOT_TOKEN_PARAMETER`, and `GOOGLE_SERVICE_ACCOUNT_PARAMETER`.

The workflow deploys only a CI-tested current `master` SHA and supports `workflow_dispatch`. Manual dispatch can create a non-executing CloudFormation plan or perform an explicitly confirmed deployment. Production concurrency is serialized.

### Bootstrap/update the repository-specific OIDC role

From an authenticated local/admin AWS session:

```bash
CODE_BUCKET='<private-artifact-bucket>' \
  bash infrastructure/bootstrap-deployment-role.sh
```

Run this again after merging the Cloudflare migration before enabling Worker deployment. The role is restricted to the NFC repository's protected `production` environment and grants Cloudflare deployment read access only to:

- the NFC API-key parameter;
- the shared Slack-signing-secret parameter;
- the dedicated NFC Cloudflare-token parameter.

It does not need GitHub Actions read access to the Lambda runtime Slack bot token or Google service-account credential.

### One-time Bitwarden -> SSM bootstrap for existing NFC runtime values

Bitwarden is supported only as a migration source. It is not used by CI or production deployment.

```bash
cp config/bootstrap-ssm-migration.env.example config/bootstrap-ssm-migration.env
bash scripts/bootstrap-ssm-migration.sh --dry-run
bash scripts/bootstrap-ssm-migration.sh
```

The populated local config is gitignored. The bootstrap imports/refreshes the existing NFC API key, shared Slack bot token and Google service-account value into their established SSM paths and writes only non-secret deployment configuration to the GitHub production environment.

### Store the dedicated NFC Cloudflare token

Create a Cloudflare API token scoped only to the account/zone permissions actually required by `nfcscan` Worker deployment and custom-domain reconciliation. Do not reuse Windsor's broad deployment token.

From an authenticated local/admin AWS session, store it without putting it on a command line:

```bash
bash scripts/store-cloudflare-api-token.sh
```

The default target is the SSM SecureString `/nfc/cloudflare/api-token`. Set `CLOUDFLARE_API_TOKEN_PARAMETER` only if a different path is deliberately used, then rerun the deployment-role bootstrap with the same override.

### Cloudflare production ownership

Cloudflare deployment is part of the normal tested production deployment, following the same repository-owned deployment pattern as `recordings`.

Configure the protected `production` environment with:

- `CLOUDFLARE_ACCOUNT_ID` — non-secret account identifier;
- `CLOUDFLARE_API_TOKEN_PARAMETER` — optional, defaults to `/nfc/cloudflare/api-token`;
- `SLACK_SIGNING_SECRET_PARAMETER` — optional, defaults to `/lambdas/aws2022-slack-handler/slack-signing-secret`.

On a real deployment the workflow:

1. deploys the AWS stack;
2. tests the exact `nfcscan` revision;
3. resolves the current `nfc2sqs` Function URL from CloudFormation;
4. reads the required deployment values from SSM and masks them;
5. performs a Wrangler dry-run;
6. syncs the API key/signing secret to Worker secrets;
7. deploys `nfcscan` on `nfc.alf-broadcast.co.uk`;
8. verifies the canonical edge rejects an invalid API key.

The dedicated NFC Cloudflare token should be scoped only to the permissions required for the NFC Worker and the `alf-broadcast.co.uk` custom domain. It should not retain `alf1000.uk` Workers Routes permission after Phase B.

## Cloudflare Access and shared WAF ownership

Repository source is not proof of live Cloudflare absence. Do not create DNS, Access or WAF resources merely because they are not present here.

Shared zone-entry/WAF resources remain under their existing central Terraform owner. The canonical `nfc.alf-broadcast.co.uk` machine-ingress exception is centrally managed as part of the `alf-broadcast.co.uk` ruleset; NFC must not duplicate that ruleset in this repository.

The retired `awsnfcscan.alf1000.uk` hostname is no longer an NFC dependency, so any hostname-specific central `alf1000.uk` exception should also be removed.

## Runtime verification and ownership

CI follows the `recordings` ingress pattern: it proves the Worker is deployed and that bad credentials are rejected at the canonical edge, but it does not attempt to impersonate a production NFC client with an authenticated GitHub-hosted `curl`.

The canonical endpoint has also passed a real production scan through:

`Worker -> nfc2sqs -> SQS -> sqs2nfc -> Google Sheets -> Slack`

Windsor no longer owns or deploys the `nfcscan` Worker. It retains only centrally managed shared zone-security Terraform until/unless that Terraform state is deliberately carved out as a whole.

## Direct AWS deployment

### Repair an existing Google service-account parameter

The deployed `sqs2nfc` consumer expects the canonical Google service-account
JSON object in SSM. If an older migration stored base64-encoded JSON instead,
run this one-time repair from an authenticated AWS shell. The helper validates
and rewrites the existing parameter without printing the credential:

```bash
AWS_PROFILE=windsor AWS_DEFAULT_REGION=eu-west-2 \
  bash scripts/normalize-google-service-account-ssm.sh
```

Verify only the parameter metadata afterwards; do not retrieve or print its
value.

`deploy.sh` is usable from an authenticated shell. It accepts only deployment configuration and SSM parameter *names*; runtime secret values are not inputs.

```bash
CODE_BUCKET='<private-artifact-bucket>' \
SPREADSHEET_ID='<spreadsheet-id>' \
bash ./deploy.sh
```

Set `PLAN_ONLY=true` to create but not execute the CloudFormation change set. Set `SKIP_BUILD=true` only when the three tested ZIP files already exist under `dist/`.

## Public repository boundary

`scripts/check-public-source.sh` rejects common credential/account patterns, Bitwarden machine credential values/UUIDs, monorepo deployment data, private keys, generated deployment artifacts, historical migration exports and `migration-backup/`. Never commit local bootstrap config, exported AWS/Cloudflare resource snapshots, real credentials, Worker secrets or generated ZIP files.
