const baseUrl = (process.env.MCP_SERVER_URL ?? "http://localhost:3000").replace(/\/$/, "");
const bearerToken = process.env.MCP_BEARER_TOKEN;
const timeoutMs = parseInt(process.env.MCP_TIMEOUT_MS ?? "10000", 10);

function withTimeout(signalTimeoutMs) {
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), signalTimeoutMs);
  return { controller, timer };
}

function buildHeaders(extra = {}) {
  const headers = { ...extra };
  if (bearerToken) {
    headers.Authorization = `Bearer ${bearerToken}`;
  }
  return headers;
}

async function fetchJson(url, options = {}) {
  const { controller, timer } = withTimeout(timeoutMs);
  try {
    const response = await fetch(url, { ...options, signal: controller.signal });
    const body = await response.text();
    return { response, body };
  } finally {
    clearTimeout(timer);
  }
}

async function main() {
  console.log(`[SMOKE] Base URL: ${baseUrl}`);

  const health = await fetchJson(`${baseUrl}/health`, {
    headers: buildHeaders(),
  });

  if (!health.response.ok) {
    throw new Error(`[SMOKE] /health failed: ${health.response.status} ${health.body}`);
  }

  console.log(`[SMOKE] /health OK: ${health.body}`);

  const { controller, timer } = withTimeout(timeoutMs);
  let sseResponse;
  try {
    sseResponse = await fetch(`${baseUrl}/sse`, {
      headers: buildHeaders({
        Accept: "text/event-stream",
      }),
      signal: controller.signal,
    });
  } finally {
    clearTimeout(timer);
  }

  if (!sseResponse.ok || !sseResponse.body) {
    const text = await sseResponse.text();
    throw new Error(`[SMOKE] /sse failed: ${sseResponse.status} ${text}`);
  }

  const reader = sseResponse.body.getReader();
  const decoder = new TextDecoder();
  let sseData = "";

  while (true) {
    const { value, done } = await reader.read();
    if (done) {
      break;
    }

    sseData += decoder.decode(value, { stream: true });
    if (sseData.includes("\n\n")) {
      break;
    }
  }

  const endpointLine = sseData
    .split("\n")
    .find((line) => line.startsWith("data:"));

  if (!endpointLine) {
    throw new Error(`[SMOKE] /sse did not return endpoint event: ${sseData}`);
  }

  const messagePath = endpointLine.replace(/^data:\s*/, "").trim();
  console.log(`[SMOKE] SSE endpoint received: ${messagePath}`);

  const initializePayload = {
    jsonrpc: "2.0",
    id: 1,
    method: "initialize",
    params: {
      protocolVersion: "2025-03-26",
      capabilities: {},
      clientInfo: {
        name: "smoke-test",
        version: "1.0.0",
      },
    },
  };

  const initialize = await fetchJson(`${baseUrl}${messagePath}`, {
    method: "POST",
    headers: buildHeaders({
      "Content-Type": "application/json",
      "MCP-Protocol-Version": "2025-03-26",
    }),
    body: JSON.stringify(initializePayload),
  });

  if (!initialize.response.ok) {
    throw new Error(
      `[SMOKE] initialize failed: ${initialize.response.status} ${initialize.body}`
    );
  }

  console.log(`[SMOKE] initialize response: ${initialize.body}`);
  await reader.cancel();
  console.log("[SMOKE] PASS");
}

main().catch((error) => {
  console.error(error.message || error);
  process.exit(1);
});
