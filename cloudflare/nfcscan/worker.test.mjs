import assert from "node:assert/strict";
import test from "node:test";
import worker, { computeLegacySlackSignature } from "./worker.js";

const baseEnv = {
  CF_NFC_API_KEY: "nfc-key",
  AWS2022_SIGNING_SECRET: "signing-secret",
  NFC2SQS_URL: "https://lambda.example.test/",
};

function nfcRequest(body = { realm: "nfc", subject: "device-1" }, options = {}) {
  const headers = new Headers({
    "content-type": "application/json, application/json",
    "x-api-key": "nfc-key, nfc-key",
    ...(options.headers || {}),
  });

  return new Request(options.url || "https://awsnfcscan.alf1000.uk/scan", {
    method: options.method || "POST",
    headers,
    body: typeof body === "string" ? body : JSON.stringify(body),
  });
}

test("forwards valid NFC requests and preserves downstream response/status", async () => {
  const originalFetch = globalThis.fetch;
  let forwarded;
  globalThis.fetch = async (url, init) => {
    forwarded = {
      url: String(url),
      method: init.method,
      headers: new Headers(init.headers),
      body: init.body,
    };
    return new Response("accepted", {
      status: 202,
      headers: { "x-downstream": "kept" },
    });
  };

  try {
    const response = await worker.fetch(nfcRequest(), baseEnv);
    assert.equal(response.status, 202);
    assert.equal(await response.text(), "accepted");
    assert.equal(response.headers.get("x-downstream"), "kept");
    assert.equal(forwarded.url, baseEnv.NFC2SQS_URL);
    assert.equal(forwarded.method, "POST");
    assert.equal(forwarded.headers.get("content-type"), "application/json");
    assert.equal(forwarded.headers.get("x-api-key"), "nfc-key");
    assert.deepEqual(JSON.parse(forwarded.body), {
      realm: "nfc",
      subject: "device-1",
    });
  } finally {
    globalThis.fetch = originalFetch;
  }
});

test("accepts realm from query while keeping the original body", async () => {
  const originalFetch = globalThis.fetch;
  let body;
  globalThis.fetch = async (_url, init) => {
    body = init.body;
    return new Response("ok", { status: 200 });
  };

  try {
    const response = await worker.fetch(
      nfcRequest(
        { subject: "device-2" },
        { url: "https://awsnfcscan.alf1000.uk/scan?realm=nfc" },
      ),
      baseEnv,
    );
    assert.equal(response.status, 200);
    assert.deepEqual(JSON.parse(body), { subject: "device-2" });
  } finally {
    globalThis.fetch = originalFetch;
  }
});

test("rejects missing or invalid API key and fails closed if the binding is absent", async () => {
  const noKey = nfcRequest();
  noKey.headers.delete("x-api-key");
  assert.equal((await worker.fetch(noKey, baseEnv)).status, 403);

  assert.equal(
    (await worker.fetch(
      nfcRequest(undefined, { headers: { "x-api-key": "wrong" } }),
      baseEnv,
    )).status,
    403,
  );

  const missingBinding = { ...baseEnv };
  delete missingBinding.CF_NFC_API_KEY;
  assert.equal((await worker.fetch(nfcRequest(), missingBinding)).status, 503);
});

test("validates the migrated legacy Slack signature contract", async () => {
  const originalFetch = globalThis.fetch;
  globalThis.fetch = async () => new Response("ok", { status: 200 });

  try {
    const body = JSON.stringify({ realm: "nfc", subject: "device-3" });
    const timestamp = "1720000000";
    const signature = await computeLegacySlackSignature(
      baseEnv.AWS2022_SIGNING_SECRET,
      timestamp,
      body,
    );

    assert.equal(
      (await worker.fetch(
        nfcRequest(body, {
          headers: {
            "x-slack-request-timestamp": timestamp,
            "x-slack-signature": signature,
          },
        }),
        baseEnv,
      )).status,
      200,
    );

    assert.equal(
      (await worker.fetch(
        nfcRequest(body, {
          headers: {
            "x-slack-request-timestamp": timestamp,
            "x-slack-signature": "v0=invalid",
          },
        }),
        baseEnv,
      )).status,
      401,
    );

    assert.equal(
      (await worker.fetch(
        nfcRequest(body, { headers: { "x-slack-signature": signature } }),
        baseEnv,
      )).status,
      401,
    );

    const missingSecret = { ...baseEnv };
    delete missingSecret.AWS2022_SIGNING_SECRET;
    assert.equal(
      (await worker.fetch(
        nfcRequest(body, {
          headers: {
            "x-slack-request-timestamp": timestamp,
            "x-slack-signature": signature,
          },
        }),
        missingSecret,
      )).status,
      503,
    );
  } finally {
    globalThis.fetch = originalFetch;
  }
});

test("rejects invalid host, method, body and realm without forwarding", async () => {
  const originalFetch = globalThis.fetch;
  let calls = 0;
  globalThis.fetch = async () => {
    calls += 1;
    return new Response("unexpected");
  };

  try {
    assert.equal(
      (await worker.fetch(
        nfcRequest(undefined, { url: "https://example.test/" }),
        baseEnv,
      )).status,
      400,
    );
    assert.equal(
      (await worker.fetch(
        new Request("https://awsnfcscan.alf1000.uk/scan", {
          method: "GET",
          headers: { "x-api-key": "nfc-key" },
        }),
        baseEnv,
      )).status,
      405,
    );
    assert.equal((await worker.fetch(nfcRequest("not-json"), baseEnv)).status, 400);
    assert.equal(
      (await worker.fetch(
        nfcRequest({ realm: "wrong", subject: "device" }),
        baseEnv,
      )).status,
      403,
    );
    assert.equal(calls, 0);
  } finally {
    globalThis.fetch = originalFetch;
  }
});

test("fails closed for missing upstream and maps transport failures to 502", async () => {
  const missingUpstream = { ...baseEnv };
  delete missingUpstream.NFC2SQS_URL;
  assert.equal((await worker.fetch(nfcRequest(), missingUpstream)).status, 503);

  const originalFetch = globalThis.fetch;
  globalThis.fetch = async () => {
    throw new Error("network down");
  };
  try {
    assert.equal((await worker.fetch(nfcRequest(), baseEnv)).status, 502);
  } finally {
    globalThis.fetch = originalFetch;
  }
});
