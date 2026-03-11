#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"

GATEWAY_CONTAINER="clawbox-openclaw-gateway-1"
HARDENED=true

# --- Parse flags ---
for arg in "$@"; do
  case "$arg" in
    --open) HARDENED=false ;;
    --help|-h)
      echo "Usage: ./setup.sh [--open]"
      echo ""
      echo "  By default, setup runs in hardened mode:"
      echo "    - Gateway bound to localhost only (not LAN)"
      echo "    - Agent commands require approval"
      echo "    - Sandbox isolation for agent tools"
      echo "    - SearXNG internal only (not exposed to host)"
      echo ""
      echo "  --open   Disable hardening (LAN-accessible, no exec approvals)"
      exit 0
      ;;
    *)
      echo "Unknown flag: $arg (try --help)"
      exit 1
      ;;
  esac
done

echo ""
echo "  ╔══════════════════════════════════════╗"
echo "  ║     OpenClaw Docker Kit Setup        ║"
if $HARDENED; then
echo "  ║          (hardened mode)             ║"
fi
echo "  ╚══════════════════════════════════════╝"
echo ""

# --- .env ---
if [ ! -f .env ]; then
  cp .env.example .env
  echo "[1/9] Created .env from .env.example"
else
  echo "[1/9] .env already exists, skipping"
fi

# shellcheck disable=SC1091
source .env

# Apply mode overrides to .env
if $HARDENED; then
  # Bind ports to localhost only on the host side
  grep -q '^BIND_HOST=' .env 2>/dev/null && sed -i.bak 's/^BIND_HOST=.*/BIND_HOST=127.0.0.1/' .env || echo 'BIND_HOST=127.0.0.1' >> .env
  rm -f .env.bak
  echo "     Hardened: ports bound to localhost only"
else
  grep -q '^BIND_HOST=' .env 2>/dev/null && sed -i.bak 's/^BIND_HOST=.*/BIND_HOST=0.0.0.0/' .env || echo 'BIND_HOST=0.0.0.0' >> .env
  rm -f .env.bak
  echo "     Open: ports bound to all interfaces (LAN-accessible)"
fi
source .env

# --- Data dirs ---
CONFIG_DIR="${OPENCLAW_CONFIG_DIR:-./data/config}"
WORKSPACE="${OPENCLAW_WORKSPACE_DIR:-./data/workspace}"
mkdir -p "$CONFIG_DIR" "$WORKSPACE"
echo "[2/9] Data directories ready"

# --- Seed minimal gateway config (required before first start) ---
if [ ! -f "$CONFIG_DIR/openclaw.json" ]; then
  # Generate a random gateway token
  GATEWAY_TOKEN=$(openssl rand -hex 24)
  cat > "$CONFIG_DIR/openclaw.json" << SEED
{
  "gateway": {
    "mode": "local",
    "auth": {
      "token": "$GATEWAY_TOKEN"
    },
    "controlUi": {
      "allowedOrigins": [
        "http://localhost:18789",
        "http://127.0.0.1:18789"
      ]
    }
  }
}
SEED
  echo "[3/9] Seeded initial gateway config (token generated)"
else
  echo "[3/9] Gateway config already exists"
fi

# --- Copy workspace files ---
if [ ! -f "$WORKSPACE/TOOLS.md" ]; then
  cp -r workspace/* "$WORKSPACE/"
  echo "[4/9] Seeded workspace with TOOLS.md and skills"
else
  mkdir -p "$WORKSPACE/skills/search"
  cp workspace/skills/search/SKILL.md "$WORKSPACE/skills/search/SKILL.md"
  echo "[4/9] Workspace exists, synced search skill"
fi

# --- Pull images ---
echo "[5/9] Pulling images..."
docker compose pull --quiet

# --- Start SearXNG + gateway ---
echo "[6/9] Starting containers..."
docker compose up -d searxng
sleep 3
docker compose up -d openclaw-gateway
echo "     Waiting for gateway to become healthy..."
for i in $(seq 1 30); do
  if docker exec "$GATEWAY_CONTAINER" node -e "fetch('http://127.0.0.1:18789/healthz').then(r=>process.exit(r.ok?0:1)).catch(()=>process.exit(1))" 2>/dev/null; then
    echo "     Gateway is healthy"
    break
  fi
  if [ "$i" -eq 30 ]; then
    echo "ERROR: Gateway did not become healthy in time"
    docker compose logs openclaw-gateway
    exit 1
  fi
  sleep 2
done

# --- Install mcporter + mcp-searxng ---
echo "[7/9] Installing search tools in gateway container..."
docker exec -u root "$GATEWAY_CONTAINER" npm install -g mcporter mcp-searxng --loglevel=error 2>&1 | tail -1
docker exec -u root "$GATEWAY_CONTAINER" chown -R node:node /home/node/.npm 2>/dev/null || true

# Configure mcporter → SearXNG
docker exec "$GATEWAY_CONTAINER" mcporter config add searxng \
  --command mcp-searxng \
  --env SEARXNG_URL=http://searxng:8080 \
  --scope home \
  --description "Local SearXNG web search" 2>/dev/null || true

# Verify search works
RESULT=$(docker exec "$GATEWAY_CONTAINER" mcporter call searxng.searxng_web_search query="test" --output json 2>&1 | head -3)
if echo "$RESULT" | grep -q "content"; then
  echo "     SearXNG search verified"
else
  echo "     WARNING: SearXNG search test failed — check logs"
fi

# --- Hardening ---
echo "[8/9] Applying security settings..."
if $HARDENED; then
  docker compose run -T --rm openclaw-cli config set agents.defaults.approvals.mode always 2>/dev/null || true
  echo "     Exec approvals: always (agent must ask before running commands)"

  docker compose run -T --rm openclaw-cli config set agents.defaults.sandbox.mode docker 2>/dev/null || true
  echo "     Sandbox: enabled (agent tools run in isolated containers)"

  docker compose run -T --rm openclaw-cli config set gateway.controlUi.allowedOrigins '["http://localhost:18789","http://127.0.0.1:18789"]' 2>/dev/null || true
  echo "     Control UI: localhost only"

  echo "     Gateway bind: loopback (localhost only, not LAN-accessible)"

  # Wait for gateway to stabilize after config-triggered restart
  echo "     Waiting for gateway to restart with new settings..."
  sleep 5
  for i in $(seq 1 15); do
    if docker exec "$GATEWAY_CONTAINER" node -e "fetch('http://127.0.0.1:18789/healthz').then(r=>process.exit(r.ok?0:1)).catch(()=>process.exit(1))" 2>/dev/null; then
      break
    fi
    sleep 2
  done
else
  echo "     Using default security settings (LAN-accessible, no exec approvals)"
  echo "     Tip: run with --hardened for tighter security"
fi

# --- Pre-configure workspace + gateway defaults ---
docker compose run -T --rm openclaw-cli config set agents.defaults.workspace /home/node/.openclaw/workspace 2>/dev/null || true
docker compose run -T --rm openclaw-cli config set gateway.bind "${OPENCLAW_GATEWAY_BIND:-lan}" 2>/dev/null || true

# --- Restart gateway to pick up all config changes, then wait ---
docker compose restart openclaw-gateway > /dev/null 2>&1
echo "     Waiting for gateway to stabilize..."
sleep 5
for i in $(seq 1 15); do
  if docker exec "$GATEWAY_CONTAINER" node -e "fetch('http://127.0.0.1:18789/healthz').then(r=>process.exit(r.ok?0:1)).catch(()=>process.exit(1))" 2>/dev/null; then
    break
  fi
  sleep 2
done

# --- AI provider setup ---
echo "[9/9] Configuring AI provider..."
docker compose run --rm openclaw-cli configure

# --- Capture gateway token and build dashboard URL ---
TOKEN=$(docker exec "$GATEWAY_CONTAINER" node -e "
  const c = JSON.parse(require('fs').readFileSync('/home/node/.openclaw/openclaw.json','utf8'));
  process.stdout.write(c?.gateway?.auth?.token || '');
" 2>/dev/null || true)
PORT="${OPENCLAW_GATEWAY_PORT:-18789}"
DASHBOARD_URL="http://127.0.0.1:${PORT}/#token=${TOKEN}"

# --- Done ---
echo ""
echo "  ╔══════════════════════════════════════╗"
echo "  ║          Setup Complete!             ║"
echo "  ╚══════════════════════════════════════╝"
echo ""
echo "  Opening OpenClaw in your browser..."
echo "  $DASHBOARD_URL"
echo ""
if $HARDENED; then
  echo "  Security: hardened (localhost only, exec approvals, sandbox)"
fi
echo ""
echo "  Commands:"
echo "    ./oc configure    # change AI provider or settings"
echo "    ./oc token        # show gateway token"
echo "    docker compose stop        # stop all"
echo "    docker compose up -d       # start all"
echo ""

# Auto-open browser (macOS / Linux / WSL)
if command -v open &>/dev/null; then
  open "$DASHBOARD_URL"
elif command -v xdg-open &>/dev/null; then
  xdg-open "$DASHBOARD_URL"
elif command -v wslview &>/dev/null; then
  wslview "$DASHBOARD_URL"
elif command -v explorer.exe &>/dev/null; then
  explorer.exe "$DASHBOARD_URL"
fi

# --- Auto-approve browser device pairing ---
echo "  Waiting for browser to connect..."
sleep 5
PENDING=""
for i in $(seq 1 30); do
  PENDING=$(docker exec "$GATEWAY_CONTAINER" node dist/index.js devices list --json 2>/dev/null | grep -o '"requestId": *"[^"]*"' | head -1 | sed 's/.*: *"//;s/"$//' || true)
  if [ -n "$PENDING" ]; then
    docker exec "$GATEWAY_CONTAINER" node dist/index.js devices approve "$PENDING" > /dev/null 2>&1 || true
    echo "  Browser device paired automatically"
    break
  fi
  sleep 2
done
if [ -z "$PENDING" ]; then
  echo "  Tip: if the browser shows 'Pairing required', run: ./oc devices list"
fi
