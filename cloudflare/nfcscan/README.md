# nfcscan Cloudflare Worker

This directory owns the NFC service's Cloudflare edge Worker. The Worker name remains
`nfcscan`, and the canonical and only production custom domain is
`nfc.alf-broadcast.co.uk`.

## Request contract

The Worker:

- accepts `POST` and `PUT` requests only;
- accepts only the canonical NFC host `nfc.alf-broadcast.co.uk`;
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

## Production ownership

The NFC repository owns the `nfcscan` Worker and its `nfc.alf-broadcast.co.uk`
custom domain. The former `awsnfcscan.alf1000.uk` compatibility hostname was
retired only after a real production scan proved the canonical Worker -> Lambda ->
SQS -> consumer -> Google Sheets/Slack path.

The dedicated NFC Cloudflare token should have only the account/zone permissions
needed to deploy the Worker and reconcile the `alf-broadcast.co.uk` custom domain.
It should not retain `alf1000.uk` Workers Routes permission in steady state.

Do not create Access, DNS, or WAF resources from this repository merely because
they are absent from source control. Shared zone-entry security remains under its
single central Terraform owner.

## Shared WAF ownership

The canonical `nfc.alf-broadcast.co.uk` machine-ingress exception remains part
of the centrally managed `alf-broadcast.co.uk` zone ruleset. The retired
`awsnfcscan.alf1000.uk` exception is no longer required and should not remain in
the central `alf1000.uk` ruleset.

This repository must not create a second `kind = "zone"` ruleset for a phase
already centrally managed.
