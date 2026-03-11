# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

Clawbox — a single-command setup for running OpenClaw (AI agent gateway) with self-hosted SearXNG web search. Targets non-technical users who want a working OpenClaw instance without manual configuration.

## Architecture

```
Browser → OpenClaw Gateway (:18789)
              ↓ (bash tool)
           mcporter → mcp-searxng (stdio) → SearXNG (:8080 internal)
```

Three Docker Compose services:
- `openclaw-gateway` — runs the agent, also hosts mcporter + mcp-searxng (installed at setup time via npm)
- `searxng` — local metasearch engine with JSON API, internal-only by default
- `openclaw-cli` — ephemeral container for running config commands (shares network with gateway)

Key constraint: MCP servers configured under `plugins.entries.acpx.config.mcpServers` only work for ACP sub-agents, NOT the main OpenClaw agent. The workaround is mcporter (CLI MCP bridge) invoked via bash tool, instructed through workspace files (`TOOLS.md` and `skills/search/SKILL.md`).

## Key Files

- `setup.sh` / `setup.ps1` — main setup scripts (bash/PowerShell), hardened by default, `--open` / `-Open` flag disables hardening
- `docker-compose.yml` — single compose file, uses `BIND_HOST` env var for port security
- `oc` — bash helper wrapping `docker compose run --rm openclaw-cli`
- `.env.example` — template for ports, image tag, data dirs, bind host
- `workspace/TOOLS.md` — loaded into agent's system context, tells it to use mcporter for search
- `workspace/skills/search/SKILL.md` — workspace skill injected into agent prompt
- `searxng/settings.yml` — SearXNG config with JSON API enabled (`formats: [html, json]`)

## Important Patterns

- **Port security**: Controlled via `BIND_HOST` env variable in `.env` (not overlay compose files). `127.0.0.1` = localhost only, `0.0.0.0` = LAN-accessible. The gateway always binds to `lan` internally (required for Docker port forwarding to work).
- **Gateway config seed**: `setup.sh` creates `data/config/openclaw.json` with `gateway.mode: "local"`, auth token, and `controlUi.allowedOrigins` before first start. Without this seed, the gateway crashes.
- **Health checks**: Use `docker exec` with Node.js fetch inside the container, not host-side curl, so it works regardless of `BIND_HOST` setting.
- **npm permissions**: Must `docker exec -u root` for npm install, then `chown -R node:node /home/node/.npm`.
- **Token delivery**: Dashboard URL includes token in hash (`/#token=...`) for auto-authentication.
- **Container name**: Hardcoded as `clawbox-openclaw-gateway-1` (derived from directory + service name).

## Testing Changes

No automated tests. To test the setup flow end-to-end:

```bash
# Tear down existing setup
docker compose down -v

# Remove data directory
rm -rf data/

# Remove .env to test fresh
rm -f .env

# Run setup
./setup.sh
```

Verify: gateway healthy, SearXNG search works (`mcporter call searxng.searxng_web_search query="test"`), browser opens with token, agent can search via bash tool.
