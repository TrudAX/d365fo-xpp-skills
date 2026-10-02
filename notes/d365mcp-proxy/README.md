# D365 F&O MCP Proxy — Service Overview

A tiny local HTTP proxy that lets **Claude Code** talk to the **Dynamics 365 F&O ERP MCP server**
without doing any interactive sign-in.

## The problem it solves

- The D365 ERP MCP server (`https://<env>.operations.dynamics.com/mcp`) requires an OAuth token.
- Claude Code's built-in MCP connector only does the **interactive user sign-in** (auth-code + PKCE),
  which needs a redirect URI registered on the Entra app.
- The Entra app we have is a **client-credentials (app-only)** registration — it obtains a token from
  just a client ID + secret, has **no redirect URI**, and is mapped to a specific D365 user.
- Those two don't fit: Claude Code can't drive a client-credentials app directly.

## How it works

```
Claude Code  ──►  http://127.0.0.1:8899/mcp   (no auth)
                        │  proxy.py
                        │  • mints an app-only token (client_credentials)
                        │  • caches + refreshes it (~1h lifetime)
                        │  • injects "Authorization: Bearer <token>"
                        ▼
                  https://<env>.operations.dynamics.com/mcp
```

The proxy is a transparent pass-through: it forwards every MCP request/response (including
streamed Server-Sent Events) unchanged, only adding the bearer token. Claude Code sees a plain,
unauthenticated local MCP endpoint and never deals with tokens or expiry.

## Files

| File | Purpose |
|------|---------|
| `proxy.py` | The proxy. Stdlib only (Python 3). Binds `127.0.0.1` only. |
| `config.json` | Non-secret config: tenant, client ID, resource, upstream URL, port. |
| `MCP-REFERENCE.md` | Full reference for the D365 ERP MCP server and its 22 tools. |

## Running it

The **client secret is never stored on disk** — it is passed via an environment variable:

```powershell
$env:D365MCP_CLIENT_SECRET = "<secret>"
py G:\ClaudeStorage\d365mcp-proxy\proxy.py
```

Registered in Claude Code with:

```
claude mcp add --transport http d365fo-perf http://127.0.0.1:8899/mcp
```

## Things to remember

- **The proxy must stay running** for the connection to work (like keeping VS Code open).
- Every action runs as the **mapped D365 user** — currently `Admin` / **System administrator**,
  default company **DAT**. Treat all writes/deletes as high-impact.
- **Rotate the client secret** periodically; relaunch with the new value in `D365MCP_CLIENT_SECRET`.
- Not yet a background service — closing the terminal stops it.
