import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { SSEServerTransport } from "@modelcontextprotocol/sdk/server/sse.js";
import express from "express";
import { createRemoteJWKSet, jwtVerify } from "jose";
import { z } from "zod";

const PORT = parseInt(process.env.PORT ?? "3000", 10);
const AUTH_REQUIRED = (process.env.AUTH_REQUIRED ?? "true").toLowerCase() === "true";
const AUTH_AUDIENCE = (process.env.AUTH_AUDIENCE ?? "").trim();
const AUTH_TENANT_ID = (process.env.AUTH_TENANT_ID ?? process.env.AZURE_TENANT_ID ?? "").trim();
const ALLOWED_ORIGINS = (process.env.ALLOWED_ORIGINS ?? "http://localhost:6274")
  .split(",")
  .map((origin) => origin.trim())
  .filter(Boolean);
const ALLOW_ANY_ORIGIN = ALLOWED_ORIGINS.includes("*");

let jwtIssuer;
let jwtIssuerV1;
let jwks;
if (AUTH_REQUIRED && AUTH_TENANT_ID) {
  jwtIssuer = `https://login.microsoftonline.com/${AUTH_TENANT_ID}/v2.0`;
  jwtIssuerV1 = `https://sts.windows.net/${AUTH_TENANT_ID}/`;
  jwks = createRemoteJWKSet(new URL("https://login.microsoftonline.com/common/discovery/v2.0/keys"));
}

function getAcceptedAudiences() {
  if (!AUTH_AUDIENCE) {
    return [];
  }

  const audiences = new Set([AUTH_AUDIENCE]);
  if (AUTH_AUDIENCE.startsWith("api://")) {
    audiences.add(AUTH_AUDIENCE.replace("api://", ""));
  }
  return Array.from(audiences);
}

function normalizeAudienceClaim(aud) {
  if (Array.isArray(aud)) {
    return aud;
  }
  if (typeof aud === "string") {
    return [aud];
  }
  return [];
}

const app = express();
const jsonParser = express.json();

// MCP POST /messages must keep the raw readable stream for the SDK transport.
app.use((req, res, next) => {
  if (req.path === "/messages") {
    next();
    return;
  }
  jsonParser(req, res, next);
});

function getAllowedOrigin(origin) {
  if (!origin) {
    return "*";
  }

  if (ALLOW_ANY_ORIGIN) {
    return "*";
  }

  if (ALLOWED_ORIGINS.includes(origin)) {
    return origin;
  }

  return null;
}

// Browser MCP Inspector connects from a different origin.
app.use((req, res, next) => {
  const origin = req.headers.origin;
  const allowedOrigin = getAllowedOrigin(origin);

  if (origin && !allowedOrigin) {
    res.status(403).json({ error: "Origin not allowed" });
    return;
  }

  if (allowedOrigin) {
    res.setHeader("Access-Control-Allow-Origin", allowedOrigin);
  }

  res.setHeader("Access-Control-Allow-Methods", "GET,POST,OPTIONS");
  res.setHeader(
    "Access-Control-Allow-Headers",
    "Content-Type, Authorization, MCP-Protocol-Version"
  );

  if (req.method === "OPTIONS") {
    res.sendStatus(204);
    return;
  }

  next();
});

async function requireBearerToken(req, res, next) {
  if (!AUTH_REQUIRED || (req.path !== "/sse" && req.path !== "/messages")) {
    next();
    return;
  }

  if (!AUTH_AUDIENCE) {
    res.status(500).json({ error: "Server auth misconfigured: AUTH_AUDIENCE missing" });
    return;
  }

  if (!AUTH_TENANT_ID || !jwks || !jwtIssuer) {
    res.status(500).json({ error: "Server auth misconfigured: AUTH_TENANT_ID missing" });
    return;
  }

  const authHeader = req.headers.authorization;
  if (!authHeader?.startsWith("Bearer ")) {
    res.status(401).json({ error: "Missing or invalid Authorization header" });
    return;
  }

  const token = authHeader.slice("Bearer ".length);

  try {
    const acceptedIssuers = [jwtIssuer, jwtIssuerV1].filter(Boolean);
    const acceptedAudiences = getAcceptedAudiences();

    // First verify signature, then apply explicit issuer/audience checks.
    const { payload } = await jwtVerify(token, jwks, {
      clockTolerance: 5,
    });

    const tokenIssuer = typeof payload.iss === "string" ? payload.iss : "";
    const tokenAudiences = normalizeAudienceClaim(payload.aud);

    const issuerOk = acceptedIssuers.includes(tokenIssuer);
    const audienceOk = tokenAudiences.some((aud) => acceptedAudiences.includes(aud));

    if (!issuerOk || !audienceOk) {
      throw new Error(
        `Token issuer/audience mismatch iss=${tokenIssuer} aud=${JSON.stringify(tokenAudiences)} acceptedIssuers=${JSON.stringify(acceptedIssuers)} acceptedAudiences=${JSON.stringify(acceptedAudiences)}`
      );
    }

    req.auth = payload;
    next();
  } catch (error) {
    console.log(`[AUTH] Token validation failed: ${error}`);
    res.status(401).json({ error: "Unauthorized" });
  }
}

app.use(requireBearerToken);

// ─────────────────────────────────────────────────────────────────────────────
// Full request logging middleware
// Logs every inbound HTTP request in full so the Entra ID / managed-identity
// token sent by Microsoft Foundry can be inspected for troubleshooting.
// ─────────────────────────────────────────────────────────────────────────────
app.use((req, _res, next) => {
  const timestamp = new Date().toISOString();
  const logEntry = {
    timestamp,
    remoteAddress: req.headers["x-forwarded-for"] ?? req.socket.remoteAddress,
    method: req.method,
    url: req.url,
    headers: req.headers,
    body: req.body,
  };
  console.log(`[REQUEST] ${JSON.stringify(logEntry, null, 2)}`);
  next();
});

function createMcpServer() {
  const server = new McpServer({
    name: "weather-mcp-server",
    version: "1.0.0",
  });

  // Tool: get_weather
  server.tool(
    "get_weather",
    "Get the current weather for a given location",
    {
      location: z
        .string()
        .describe("City and country/state, e.g. 'Dublin, Ireland'"),
    },
    async ({ location }) => {
      console.log(
        `[TOOL] get_weather called – location="${location}" ts=${new Date().toISOString()}`
      );

      // Mock weather data – replace with a real weather API as needed
      const weather = {
        location,
        temperature: "18°C (64°F)",
        condition: "Partly cloudy",
        humidity: "68%",
        wind: "15 km/h SW",
        uvIndex: 3,
        timestamp: new Date().toISOString(),
      };

      return {
        content: [
          {
            type: "text",
            text: JSON.stringify(weather, null, 2),
          },
        ],
      };
    }
  );

  return server;
}

// ─────────────────────────────────────────────────────────────────────────────
// HTTP routes
// ─────────────────────────────────────────────────────────────────────────────

// Active sessions keyed by session id
const sessions = new Map();

// SSE endpoint – MCP clients open a persistent connection here
app.get("/sse", async (req, res) => {
  console.log(
    `[SSE] New connection from ${req.headers["x-forwarded-for"] ?? req.socket.remoteAddress}`
  );

  const mcpServer = createMcpServer();
  const transport = new SSEServerTransport("/messages", res);
  sessions.set(transport.sessionId, { transport, mcpServer });

  transport.onclose = () => {
    sessions.delete(transport.sessionId);
    console.log(`[SSE] Session closed: ${transport.sessionId}`);
  };

  try {
    await mcpServer.connect(transport);
  } catch (error) {
    console.error(`[SSE] Failed to connect transport: ${error}`);
    sessions.delete(transport.sessionId);
    if (!res.headersSent) {
      res.status(500).json({ error: "Failed to open SSE session" });
    }
  }
});

// Messages endpoint – MCP clients POST JSON-RPC messages here
app.post("/messages", async (req, res) => {
  const sessionId = req.query.sessionId;
  const session = sessions.get(sessionId);
  const transport = session?.transport;

  if (!transport) {
    console.warn(`[MESSAGES] Session not found: ${sessionId}`);
    res.status(400).json({ error: "Session not found" });
    return;
  }

  await transport.handlePostMessage(req, res);
});

// Health-check endpoint (used by Container Apps liveness probe)
app.get("/health", (_req, res) => {
  res.json({
    status: "healthy",
    service: "weather-mcp-server",
    version: "1.0.0",
    timestamp: new Date().toISOString(),
    activeSessions: sessions.size,
  });
});

// ─────────────────────────────────────────────────────────────────────────────
// Start
// ─────────────────────────────────────────────────────────────────────────────
app.listen(PORT, () => {
  console.log(
    `[SERVER] Weather MCP Server listening on port ${PORT}`
  );
  console.log(`[SERVER] Endpoints:`);
  console.log(`[SERVER]   SSE      http://0.0.0.0:${PORT}/sse`);
  console.log(`[SERVER]   Messages http://0.0.0.0:${PORT}/messages`);
  console.log(`[SERVER]   Health   http://0.0.0.0:${PORT}/health`);
  console.log(`[SERVER] Auth required=${AUTH_REQUIRED} tenant=${AUTH_TENANT_ID || "<unset>"} audience=${AUTH_AUDIENCE || "<unset>"}`);
  console.log(`[SERVER] Allowed origins=${ALLOW_ANY_ORIGIN ? "*" : ALLOWED_ORIGINS.join(",")}`);
});
