# Plan: App-role authorization for MCP server

## Goal
Authorize `/sse` and `/messages` using Entra app roles in the incoming bearer token (for example `mcp-srv-001`), in addition to existing issuer/audience token validation.

## Phase 1: Design and config surface
1. Add new server config env vars:
   - `AUTH_REQUIRED_ROLES` (comma-separated, default `mcp-srv-001`)
   - `AUTH_ACCEPT_SCOPES` (comma-separated, default empty) as optional delegated-token fallback
2. Keep response behavior explicit:
   - Missing/invalid token => `401`
   - Valid token but missing required role/scope => `403`
   - Misconfiguration (auth enabled but required role unset) => `500`
3. Document prerequisites and Entra setup requirements:
   - API app registration and app ID URI (`MCP_AUTH_AUDIENCE`)
   - app role value (`mcp-srv-001`) with `allowedMemberTypes` including `Application`
   - Foundry project MI role assignment on the API service principal
   - Foundry connection audience aligned to API app ID URI

## Phase 2: Server implementation
1. Extend token claim parsing helpers for `roles`, `scp`, and CSV env values.
2. After signature/issuer/audience checks, enforce role authorization.
3. If configured, allow delegated-scope fallback.
4. Log auth decisions without logging raw token values.

## Phase 3: Infrastructure wiring
1. Add parameters to `infra/main.parameters.json`:
   - `authRequiredRoles` default `${MCP_AUTH_REQUIRED_ROLES=mcp-srv-001}`
   - `authAcceptScopes` default `${MCP_AUTH_ACCEPT_SCOPES=}`
2. Pass those params through `infra/main.bicep` to `infra/modules/mcp-server.bicep`.
3. Emit container env vars `AUTH_REQUIRED_ROLES` and `AUTH_ACCEPT_SCOPES`.

## Phase 4: Documentation
1. Update README security settings with the new environment variables.
2. Document `401` vs `403` and token-refresh caveat for new role assignments.

## Phase 5: Validation
1. Positive: token with required role can access `/sse` and `/messages`.
2. Negative: missing token => `401`; bad issuer/audience => `401`; missing role/scope => `403`.
3. Deploy and verify through Foundry Playground and ACA logs.
4. Decode forwarded token claims and confirm:
   - `aud` equals configured audience
   - `roles` contains `mcp-srv-001`
5. If assignment is recent and role is missing, re-test after token refresh window.
