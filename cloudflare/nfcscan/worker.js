const ALLOWED_HOST = "awsnfcscan.alf1000.uk";
const ALLOWED_METHODS = new Set(["POST", "PUT"]);

function jsonResponse(status, payload) {
  return new Response(JSON.stringify(payload), {
    status,
    headers: { "content-type": "application/json" },
  });
}

// Windsor's existing nfcscan Worker uses SHA-256(secret + Slack basestring),
// rather than Slack's HMAC-SHA256 scheme. Preserve that deployed contract for
// the ownership cutover; change it only in a separately reviewed hardening.
export async function computeLegacySlackSignature(signingSecret, timestamp, body = "") {
  const basestring = `v0:${timestamp}:${body}`;
  const hash = await crypto.subtle.digest(
    "SHA-256",
    new TextEncoder().encode(`${signingSecret}${basestring}`),
  );
  const hex = Array.from(
    new Uint8Array(hash),
    byte => byte.toString(16).padStart(2, "0"),
  ).join("");
  return `v0=${hex}`;
}

function timingSafeEqual(left, right) {
  if (typeof left !== "string" || typeof right !== "string" || left.length !== right.length) {
    return false;
  }

  let mismatch = 0;
  for (let index = 0; index < left.length; index += 1) {
    mismatch |= left.charCodeAt(index) ^ right.charCodeAt(index);
  }
  return mismatch === 0;
}

export default {
  async fetch(request, env) {
    const url = new URL(request.url);

    try {
      if (url.host !== ALLOWED_HOST) {
        return new Response(`Unhandled host: ${url.host}`, { status: 400 });
      }

      if (!ALLOWED_METHODS.has(request.method)) {
        return new Response("Method Not Allowed", {
          status: 405,
          headers: { allow: "POST, PUT" },
        });
      }

      // Fail closed if a deployment accidentally omits the API-key binding.
      if (!env.CF_NFC_API_KEY) {
        console.error("CF_NFC_API_KEY is not configured");
        return jsonResponse(503, { error: "Service unavailable" });
      }

      const apiKey = request.headers.get("x-api-key")?.split(",")[0].trim() || null;
      if (apiKey !== env.CF_NFC_API_KEY) {
        return jsonResponse(403, { error: "Forbidden: Invalid API Key" });
      }

      const requestBody = await request.text();
      if (!requestBody) {
        return jsonResponse(400, { error: "Request body is required" });
      }

      let parsedBody;
      try {
        parsedBody = JSON.parse(requestBody);
      } catch {
        console.error("Invalid JSON body received");
        return jsonResponse(400, { error: "Invalid JSON body" });
      }

      if (!parsedBody || typeof parsedBody !== "object" || Array.isArray(parsedBody)) {
        return jsonResponse(400, { error: "Invalid JSON body" });
      }

      const slackSignature = request.headers.get("x-slack-signature");
      const slackTimestamp = request.headers.get("x-slack-request-timestamp");
      if (slackSignature || slackTimestamp) {
        if (!slackSignature || !slackTimestamp) {
          return jsonResponse(401, { error: "Invalid Slack signature" });
        }
        if (!env.AWS2022_SIGNING_SECRET) {
          console.error("AWS2022_SIGNING_SECRET is not configured");
          return jsonResponse(503, { error: "Service unavailable" });
        }

        const computedSignature = await computeLegacySlackSignature(
          env.AWS2022_SIGNING_SECRET,
          slackTimestamp,
          requestBody,
        );
        if (!timingSafeEqual(computedSignature, slackSignature)) {
          return jsonResponse(401, { error: "Invalid Slack signature" });
        }
      }

      const realm = url.searchParams.get("realm") || parsedBody.realm;
      if (realm !== "nfc") {
        return jsonResponse(403, { error: "Forbidden: Invalid realm" });
      }

      if (!env.NFC2SQS_URL) {
        console.error("NFC2SQS_URL is not configured");
        return jsonResponse(503, { error: "Service unavailable" });
      }

      const originalHeaders = new Headers(request.headers);
      if (originalHeaders.has("content-type")) {
        originalHeaders.set(
          "content-type",
          originalHeaders.get("content-type").split(",")[0].trim(),
        );
      }
      if (originalHeaders.has("x-api-key")) {
        originalHeaders.set(
          "x-api-key",
          originalHeaders.get("x-api-key").split(",")[0].trim(),
        );
      }

      try {
        return await fetch(env.NFC2SQS_URL, {
          method: request.method,
          headers: originalHeaders,
          body: requestBody,
        });
      } catch (error) {
        console.error("Error proxying to Lambda:", error);
        return jsonResponse(502, { error: "Bad Gateway" });
      }
    } catch (error) {
      console.error("Unhandled exception:", error);
      return jsonResponse(500, { error: "Internal Server Error" });
    }
  },
};
