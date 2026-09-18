# nfcscan Cloudflare Worker

This directory is the NFC repository's replacement for `windsor-app/cloudflare/nfcscan`.
It preserves the production Worker name `nfcscan` and custom domain
`awsnfcscan.alf1000.uk` while moving deployment ownership into this repository.

## Request contract

The Worker:

- accepts `POST` and `PUT` requests only;
- accepts only the configured canonical/legacy NFC hosts (`nfc.alf-broadcast.co.uk` and `awsnfcscan.alf1000.uk`);
- requires `x-api-key` to match `CF_NFC_API_KEY`;
- validates the migrated Windsor Slack-signature contract when Slack signature
  headers are present;
- requires `realm=nfc` from the query string or JSON body;
- requires a JSON request body;
- forwards to the deployed `nfc2sqs` Function URL;
- preserves the downstream response and status;
- fails closed if required bindings are missing.

The legacy Windsor signature algorithm is intentionally preserved during this
ownership transfer. It is covered by tests so a later switch to Slack's standard
HMAC-SHA256 verification can be made as an explicit security change rather than
silently changing the migration contract.

## Runtime bindings

Sensitive bindings are provisioned at deployment time from AWS SSM through the
repo-specific GitHub OIDC role:

| Worker binding | Canonical source |
| --- | --- |
| `CF_NFC_API_KEY` | `/lambdas/nfc/required-api-key` |
| `AWS2022_SIGNING_SECRET` | `/lambdas/aws2022-slack-handler/slack-signing-secret` |

`NFC2SQS_URL` is non-secret configuration. The production workflow reads the
`Nfc2SqsFunctionUrl` output from the deployed `nfc` CloudFormation stack and
passes it to Wrangler as a plain Worker variable.

The dedicated NFC Cloudflare deployment token is stored in SSM at
`/nfc/cloudflare/api-token` by default. It is loaded only into the deployment
job as `CLOUDFLARE_API_TOKEN`; it is not a Worker runtime binding.

## Local validation

No production credentials are required:

```bash
node --test cloudflare/nfcscan/worker.test.mjs
npx --yes wrangler@4 deploy \
  --config cloudflare/nfcscan/wrangler.toml \
  --dry-run \
  --var 'NFC2SQS_URL:https://example.invalid/'
```

## Production cutover guard

Merging this code does **not** immediately transfer the production custom domain.
Cloudflare deployment is skipped until the protected GitHub `production`
environment contains:

- `CLOUDFLARE_ACCOUNT_ID`;
- `CLOUDFLARE_API_TOKEN_PARAMETER` if the default SSM path is not used;
- `SLACK_SIGNING_SECRET_PARAMETER` if the canonical shared path is overridden.

Before first ownership cutover, audit the live Cloudflare account
and confirm:

1. `nfcscan` is the Worker currently serving `awsnfcscan.alf1000.uk`;
2. how the custom domain/DNS record is owned;
3. whether a Cloudflare Access application/policies exist for this hostname;
4. which WAF/custom/rate-limit rules reference the hostname;
5. the dedicated NFC API token has only the permissions needed for Worker
   deployment and custom-domain reconciliation.

Do not create Access, DNS, or WAF resources from this repository merely because
they are absent from source control. If an Access application exists, import it
into a deliberately isolated NFC Terraform state before managing it here. If no
Access application exists, do not add browser-interactive Access to this machine
endpoint without proving every NFC/Slack caller is compatible.

## Shared WAF ownership

The shared `alf1000.uk` zone entry-point/WAF ruleset remains under its existing
central owner. This repository must not create a second `kind = "zone"` ruleset
for a phase already centrally managed. The NFC scan-protection rule should remain
scoped to `awsnfcscan.alf1000.uk` in that shared owner and must be verified after
the Worker cutover.

## Cutover sequence

1. Create a dedicated NFC Cloudflare API token and store it as the configured SSM
   SecureString (see the main README).
2. Audit live Worker/custom-domain/DNS/Access/WAF ownership without recording
   secret values.
3. Run the production deploy workflow. It deploys AWS first, resolves the live
   Function URL, loads only the required Cloudflare values from SSM, syncs Worker
   secrets, and deploys `nfcscan` with the same custom domain.
5. Verify bad API keys are rejected and a valid NFC request reaches Lambda -> SQS
   -> `sqs2nfc` -> Google Sheets/Slack.
6. Only after that verification, execute the Windsor cleanup follow-up described
   by `windsor-app#1876`; do not remove shared zone/WAF ownership.
