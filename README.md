# NFC

Standalone AWS workload for NFC scan handling. This repository owns the application source, CloudFormation stack, CI, and production deployment that previously lived in the private `lambdas` monorepo.

## Architecture

The production flow is:

1. An NFC client calls the public `nfc2sqs` Lambda Function URL.
2. `nfc2sqs` validates the application-level `x-api-key` against an SSM SecureString, writes the NFC event to the retained `nfc` SQS queue, and posts the ingress notification to Slack.
3. The queue invokes `sqs2nfc` through an event-source mapping.
4. `sqs2nfc` resolves the Google service-account credential and Slack token from SSM, reads/writes the configured Google spreadsheet, and posts the interactive Slack response.

The Function URL intentionally uses `AuthType: NONE`; the API key is the application-level ingress control. Do not remove that validation without replacing it with an equivalent reviewed authentication mechanism.

## Runtime configuration

Runtime secret values are owned by AWS SSM Parameter Store and are read directly by the Lambdas. The initial standalone cutover deliberately keeps the existing parameter names:

- `/lambdas/nfc/required-api-key`
- `/lambdas/nfc/sqs2nfc/google-service-account`
- `/lambdas/shared/slack-bot-token`

The Slack token is a shared external dependency and is not duplicated into an NFC-specific path during this migration.

`SPREADSHEET_ID` is non-secret configuration. Production supplies it as a GitHub `production` environment variable and CloudFormation passes it to `sqs2nfc`.

Normal deployments never retrieve secret plaintext and never call `ssm:PutParameter`. Secret import/rotation is a separate local/admin operation.

## Local development

Requirements: Node.js 22+ (CI/deployment uses Node.js 24), npm, `zip`, and `unzip`.

```bash
npm test
npm run check
npm run build
```

`npm run build` installs the Lambda-layer dependencies from the committed lockfile and creates:

- `dist/nfc2sqs-lambda.zip`
- `dist/sqs2nfc-lambda.zip`
- `dist/lambda-layer.zip`

Generated artifacts and installed dependencies are gitignored.

## CI

`.github/workflows/ci.yml` runs on pull requests and pushes to `master`. It:

- enforces the public-source boundary;
- builds the Lambda layer reproducibly from `lambda-layer/nodejs/package-lock.json`;
- runs source/security contract tests and syntax checks;
- validates function/layer package contents;
- tests the one-time migration/SSM bootstrap helpers;
- lints both CloudFormation templates without production AWS credentials;
- publishes the tested `dist/` artifact only for a trusted push to `master`.

PR CI requires no AWS credentials, SSM access, GitHub deployment identity, or Bitwarden access.

## Production deployment

Production uses the protected GitHub environment named `production`. Configure these environment variables:

- `AWS_ROLE_TO_ASSUME` — ARN output by `infrastructure/bootstrap-deployment-role.sh`;
- `AWS_REGION` — normally `eu-west-2`;
- `CODE_BUCKET` — private S3 bucket for deployment artifacts;
- `STACK_NAME` — normally `nfc`;
- `S3_PREFIX` — normally `nfc`;
- `SPREADSHEET_ID` — non-secret spreadsheet identifier;
- optional overrides for `REQUIRED_API_KEY_PARAMETER`, `SLACK_BOT_TOKEN_PARAMETER`, and `GOOGLE_SERVICE_ACCOUNT_PARAMETER`.

The deployment workflow uses GitHub OIDC. It has no long-lived AWS access keys and no Bitwarden credentials. Automatic deployment is triggered only after CI succeeds for the exact current `master` SHA, then reuses the build artifact produced by that CI run. Manual workflow dispatch supports a non-executing CloudFormation plan or an explicitly confirmed deployment.

### Bootstrap the repository-specific OIDC role

From an authenticated local/admin AWS session:

```bash
CODE_BUCKET='<private-artifact-bucket>' \
  bash infrastructure/bootstrap-deployment-role.sh
```

The role trust policy is restricted to this repository and the `production` GitHub environment. Its permissions are scoped to the NFC stack/artifact prefix, NFC functions/layers/queue/runtime roles/log groups, event-source mapping, and read-only access to the three runtime SSM parameters.

After the role is created, configure the returned ARN as `AWS_ROLE_TO_ASSUME` in the `production` environment. Restrict that GitHub environment to the `master` deployment branch and apply the desired reviewer/protection policy before enabling automatic production deployment.

### One-time Bitwarden → SSM bootstrap

Bitwarden is supported only as a migration source. It is not used by CI or production deployment.

```bash
cp config/bootstrap-ssm-migration.env.example config/bootstrap-ssm-migration.env
# Fill the gitignored local config, then validate mappings/auth without reading values:
bash scripts/bootstrap-ssm-migration.sh --dry-run
# Execute only after reviewing the target account/role/paths:
bash scripts/bootstrap-ssm-migration.sh
```

In the copied `config/bootstrap-ssm-migration.env`, populate the `BWS_ACCESS_TOKEN=` line with the Bitwarden Secrets Manager machine-account token. The bootstrap sources the file with exported variables, so the `bws` CLI receives that token automatically. You can alternatively export `BWS_ACCESS_TOKEN` in the shell and leave the config entry blank.

The script imports/refreshes the NFC API key, shared Slack token, and Google service-account value into their existing SSM SecureString paths. It moves the spreadsheet ID into a non-secret GitHub production environment variable. It never prints secret values or Bitwarden IDs. The real local config is gitignored.

## Direct deployment

`deploy.sh` is also usable from an authenticated shell. It accepts only deployment configuration and SSM parameter *names*; secret values are not inputs.

```bash
CODE_BUCKET='<private-artifact-bucket>' \
SPREADSHEET_ID='<spreadsheet-id>' \
bash ./deploy.sh
```

Set `PLAN_ONLY=true` to create but not execute the CloudFormation change set. Set `SKIP_BUILD=true` only when the three tested ZIP files already exist under `dist/`.

## Cutover safety

The template preserves the existing stack/resource defaults (`nfc`, `nfc2sqs`, `sqs2nfc`, layers and runtime-role names), retained SQS queue, Function URL, and event-source mapping. The first standalone production run should be a plan and should be reviewed for updates/no-op rather than duplicate/replacement resources.

Before removing NFC from the `lambdas` monorepo, complete an executed standalone deployment and verify: Function URL/API-key behaviour, SQS enqueue/consume, Google Sheets access, Slack notifications, runtime SSM retrieval, and preservation of existing queue state/messages. Monorepo cleanup is intentionally deferred until that production verification has succeeded.

## Public repository boundary

`scripts/check-public-source.sh` rejects common credential/account patterns, Bitwarden machine credential values/UUIDs, monorepo deployment data, private keys, generated deployment artifacts, historical migration exports, and `migration-backup/`. Never commit local bootstrap config, exported AWS resource snapshots, real credentials, or generated ZIP files.
