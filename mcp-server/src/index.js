import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { SSEServerTransport } from "@modelcontextprotocol/sdk/server/sse.js";
import express from "express";
import { z } from "zod";

const PORT = parseInt(process.env.PORT ?? "3000", 10);

const app = express();
app.use(express.json());

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

// ─────────────────────────────────────────────────────────────────────────────
// MCP server
// ─────────────────────────────────────────────────────────────────────────────
const mcpServer = new McpServer({
  name: "weather-mcp-server",
  version: "1.0.0",
});

// Tool: get_weather
mcpServer.tool(
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

// ─────────────────────────────────────────────────────────────────────────────
// HTTP routes
// ─────────────────────────────────────────────────────────────────────────────

// Active SSE transports keyed by session id
const transports = new Map();

// SSE endpoint – MCP clients open a persistent connection here
app.get("/sse", async (req, res) => {
  console.log(
    `[SSE] New connection from ${req.headers["x-forwarded-for"] ?? req.socket.remoteAddress}`
  );

  const transport = new SSEServerTransport("/messages", res);
  transports.set(transport.sessionId, transport);

  transport.onclose = () => {
    transports.delete(transport.sessionId);
    console.log(`[SSE] Session closed: ${transport.sessionId}`);
  };

  await mcpServer.connect(transport);
});

// Messages endpoint – MCP clients POST JSON-RPC messages here
app.post("/messages", async (req, res) => {
  const sessionId = req.query.sessionId;
  const transport = transports.get(sessionId);

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
    activeSessions: transports.size,
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
});
