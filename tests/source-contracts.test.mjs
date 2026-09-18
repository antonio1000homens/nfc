import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import { test } from 'node:test';

const read = (path) => readFile(new URL(`../${path}`, import.meta.url), 'utf8');

test('nfc2sqs keeps application-level API key validation and SSM lookup', async () => {
  const source = await read('nfc2sqs/nfc2sqs.mjs');
  assert.match(source, /getRequiredSecret\('REQUIRED_API_KEY_PARAMETER'\)/);
  assert.match(source, /headers\['x-api-key'\]/);
  assert.match(source, /statusCode:\s*401/);
  assert.match(source, /statusCode:\s*403/);
  assert.match(source, /SendMessageCommand/);
});

test('sqs2nfc keeps SSM-backed Google and Slack integration', async () => {
  const source = await read('sqs2nfc/sqs2nfc.mjs');
  assert.match(source, /getRequiredSecret\('GOOGLE_SERVICE_ACCOUNT_PARAMETER'\)/);
  assert.match(source, /getRequiredSecret\('SLACK_BOT_TOKEN_PARAMETER'\)/);
  assert.match(source, /process\.env\.SPREADSHEET_ID/);
  assert.match(source, /event\.Records/);
});

test('runtime layer decrypts SSM values and requires parameter-name environment variables', async () => {
  const source = await read('lambda-layer/nodejs/ssm-secrets.mjs');
  assert.match(source, /WithDecryption:\s*true/);
  assert.match(source, /process\.env\[nameEnvVar\]/);
  assert.doesNotMatch(source, /put-parameter|PutParameter/);
});

test('normal deployment never retrieves or writes Lambda runtime secret plaintext', async () => {
  const source = await read('deploy.sh');
  assert.doesNotMatch(source, /ssm\s+(get-parameter|put-parameter)/);
  assert.doesNotMatch(source, /\bREQUIRED_API_KEY=/);
  assert.doesNotMatch(source, /\bSLACK_BOT_TOKEN=/);
  assert.doesNotMatch(source, /GOOGLE_SERVICE_ACCOUNT_(JSON|B64)=/);
  assert.match(source, /REQUIRED_API_KEY_PARAMETER/);
  assert.match(source, /GOOGLE_SERVICE_ACCOUNT_PARAMETER/);
});

test('production workflow uses OIDC and SSM without Bitwarden or GitHub secret values', async () => {
  const source = await read('.github/workflows/deploy.yml');
  assert.match(source, /environment:\s*production/);
  assert.match(source, /id-token:\s*write/);
  assert.match(source, /vars\.AWS_ROLE_TO_ASSUME/);
  assert.match(source, /workflow_run:/);
  assert.match(source, /scripts\/load-ssm-secrets\.sh cloudflare/);
  assert.match(source, /CLOUDFLARE_ACCOUNT_ID/);
  assert.doesNotMatch(source, /CLOUDFLARE_DEPLOY_ENABLED/);
  assert.doesNotMatch(source, /bitwarden|BWS_/i);
  assert.doesNotMatch(source, /\$\{\{\s*secrets\./i);
});

test('CloudFormation preserves retained queue and current SSM parameter names', async () => {
  const source = await read('infrastructure/nfc.yaml');
  assert.match(source, /DeletionPolicy:\s*Retain/);
  assert.match(source, /UpdateReplacePolicy:\s*Retain/);
  assert.match(source, /\/lambdas\/nfc\/required-api-key/);
  assert.match(source, /\/lambdas\/nfc\/sqs2nfc\/google-service-account/);
  assert.match(source, /\/lambdas\/shared\/slack-bot-token/);
});


test('Phase A Cloudflare config keeps both hostnames until cutover completes', async () => {
  const worker = await read('cloudflare/nfcscan/worker.js');
  const wrangler = await read('cloudflare/nfcscan/wrangler.toml');
  assert.match(worker, /nfc\.alf-broadcast\.co\.uk/);
  assert.match(worker, /awsnfcscan\.alf1000\.uk/);
  assert.match(wrangler, /nfc\.alf-broadcast\.co\.uk/);
  assert.match(wrangler, /awsnfcscan\.alf1000\.uk/);
});

test('SSM bootstrap normalises Google service-account JSON before storing it', async () => {
  const source = await read('scripts/bootstrap-ssm-migration.sh');
  assert.match(source, /put_google_service_account_parameter/);
  assert.match(source, /decode_base64_stdin/);
  assert.match(source, /--rawfile value/);
  assert.match(source, /normalised JSON/);
});
