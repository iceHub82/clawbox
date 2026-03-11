#Requires -Version 5.1
<#
.SYNOPSIS
    OpenClaw Docker Kit Setup (Windows)
.PARAMETER Open
    Disable hardening (LAN-accessible, no exec approvals)
#>
param(
    [switch]$Open
)

$ErrorActionPreference = "Stop"
Set-Location $PSScriptRoot

$GatewayContainer = "clawbox-openclaw-gateway-1"
$Hardened = -not $Open

Write-Host ""
Write-Host "  ╔══════════════════════════════════════╗"
Write-Host "  ║     OpenClaw Docker Kit Setup        ║"
if ($Hardened) {
    Write-Host "  ║          (hardened mode)             ║"
}
Write-Host "  ╚══════════════════════════════════════╝"
Write-Host ""

# --- .env ---
if (-not (Test-Path .env)) {
    Copy-Item .env.example .env
    Write-Host "[1/9] Created .env from .env.example"
} else {
    Write-Host "[1/9] .env already exists, skipping"
}

# Apply mode overrides
$envContent = Get-Content .env -Raw
if ($Hardened) {
    if ($envContent -match "BIND_HOST=") {
        $envContent = $envContent -replace "BIND_HOST=.*", "BIND_HOST=127.0.0.1"
    } else {
        $envContent += "`nBIND_HOST=127.0.0.1"
    }
    Write-Host "     Hardened: ports bound to localhost only"
} else {
    if ($envContent -match "BIND_HOST=") {
        $envContent = $envContent -replace "BIND_HOST=.*", "BIND_HOST=0.0.0.0"
    } else {
        $envContent += "`nBIND_HOST=0.0.0.0"
    }
    Write-Host "     Open: ports bound to all interfaces (LAN-accessible)"
}
Set-Content .env $envContent -NoNewline

# Parse .env into variables
Get-Content .env | ForEach-Object {
    if ($_ -match "^([^#][^=]+)=(.*)$") {
        Set-Variable -Name $matches[1].Trim() -Value $matches[2].Trim() -Scope Script
    }
}

# --- Data dirs ---
$ConfigDir = if ($OPENCLAW_CONFIG_DIR) { $OPENCLAW_CONFIG_DIR } else { "./data/config" }
$WorkspaceDir = if ($OPENCLAW_WORKSPACE_DIR) { $OPENCLAW_WORKSPACE_DIR } else { "./data/workspace" }
New-Item -ItemType Directory -Force -Path $ConfigDir | Out-Null
New-Item -ItemType Directory -Force -Path $WorkspaceDir | Out-Null
Write-Host "[2/9] Data directories ready"

# --- Seed gateway config ---
$configPath = Join-Path $ConfigDir "openclaw.json"
if (-not (Test-Path $configPath)) {
    $token = -join ((1..24) | ForEach-Object { "{0:x2}" -f (Get-Random -Maximum 256) })
    $config = @"
{
  "gateway": {
    "mode": "local",
    "auth": {
      "token": "$token"
    },
    "controlUi": {
      "allowedOrigins": [
        "http://localhost:18789",
        "http://127.0.0.1:18789"
      ]
    }
  }
}
"@
    Set-Content $configPath $config
    Write-Host "[3/9] Seeded initial gateway config (token generated)"
} else {
    Write-Host "[3/9] Gateway config already exists"
}

# --- Copy workspace files ---
$toolsMd = Join-Path $WorkspaceDir "TOOLS.md"
if (-not (Test-Path $toolsMd)) {
    Copy-Item -Recurse -Force workspace\* $WorkspaceDir
    Write-Host "[4/9] Seeded workspace with TOOLS.md and skills"
} else {
    $skillDir = Join-Path $WorkspaceDir "skills\search"
    New-Item -ItemType Directory -Force -Path $skillDir | Out-Null
    Copy-Item -Force workspace\skills\search\SKILL.md $skillDir\
    Write-Host "[4/9] Workspace exists, synced search skill"
}

# --- Pull images ---
Write-Host "[5/9] Pulling images..."
docker compose pull --quiet

# --- Start containers ---
Write-Host "[6/9] Starting containers..."
docker compose up -d searxng
Start-Sleep -Seconds 3
docker compose up -d openclaw-gateway

Write-Host "     Waiting for gateway to become healthy..."
$healthy = $false
for ($i = 1; $i -le 30; $i++) {
    try {
        docker exec $GatewayContainer node -e "fetch('http://127.0.0.1:18789/healthz').then(r=>process.exit(r.ok?0:1)).catch(()=>process.exit(1))" 2>$null
        if ($LASTEXITCODE -eq 0) {
            Write-Host "     Gateway is healthy"
            $healthy = $true
            break
        }
    } catch {}
    Start-Sleep -Seconds 2
}
if (-not $healthy) {
    Write-Host "ERROR: Gateway did not become healthy in time"
    docker compose logs openclaw-gateway
    exit 1
}

# --- Install mcporter + mcp-searxng ---
Write-Host "[7/9] Installing search tools in gateway container..."
docker exec -u root $GatewayContainer npm install -g mcporter mcp-searxng --loglevel=error 2>&1 | Select-Object -Last 1
docker exec -u root $GatewayContainer chown -R node:node /home/node/.npm 2>$null

docker exec $GatewayContainer mcporter config add searxng `
    --command mcp-searxng `
    --env SEARXNG_URL=http://searxng:8080 `
    --scope home `
    --description "Local SearXNG web search" 2>$null

$result = docker exec $GatewayContainer mcporter call searxng.searxng_web_search query="test" --output json 2>&1 | Select-Object -First 3
if ($result -match "content") {
    Write-Host "     SearXNG search verified"
} else {
    Write-Host "     WARNING: SearXNG search test failed"
}

# --- Hardening ---
Write-Host "[8/9] Applying security settings..."
if ($Hardened) {
    docker compose run -T --rm openclaw-cli config set agents.defaults.approvals.mode always 2>$null
    Write-Host "     Exec approvals: always"
    docker compose run -T --rm openclaw-cli config set agents.defaults.sandbox.mode docker 2>$null
    Write-Host "     Sandbox: enabled"
    docker compose run -T --rm openclaw-cli config set gateway.controlUi.allowedOrigins '["http://localhost:18789","http://127.0.0.1:18789"]' 2>$null
    Write-Host "     Control UI: localhost only"

    Write-Host "     Waiting for gateway to restart with new settings..."
    Start-Sleep -Seconds 5
    for ($i = 1; $i -le 15; $i++) {
        try {
            docker exec $GatewayContainer node -e "fetch('http://127.0.0.1:18789/healthz').then(r=>process.exit(r.ok?0:1)).catch(()=>process.exit(1))" 2>$null
            if ($LASTEXITCODE -eq 0) { break }
        } catch {}
        Start-Sleep -Seconds 2
    }
} else {
    Write-Host "     Using default security settings (LAN-accessible)"
}

# --- Pre-configure workspace ---
docker compose run -T --rm openclaw-cli config set agents.defaults.workspace /home/node/.openclaw/workspace 2>$null

# --- AI provider setup ---
Write-Host "[9/9] Configuring AI provider..."
docker compose run --rm openclaw-cli configure

# --- Restart and get token ---
docker compose restart openclaw-gateway 2>$null
Start-Sleep -Seconds 5

$Token = docker exec $GatewayContainer node -e "
  const c = JSON.parse(require('fs').readFileSync('/home/node/.openclaw/openclaw.json','utf8'));
  process.stdout.write(c?.gateway?.auth?.token || '');
" 2>$null

$Port = if ($OPENCLAW_GATEWAY_PORT) { $OPENCLAW_GATEWAY_PORT } else { "18789" }
$DashboardUrl = "http://127.0.0.1:${Port}/#token=${Token}"

# --- Done ---
Write-Host ""
Write-Host "  ╔══════════════════════════════════════╗"
Write-Host "  ║          Setup Complete!             ║"
Write-Host "  ╚══════════════════════════════════════╝"
Write-Host ""
Write-Host "  Opening OpenClaw in your browser..."
Write-Host "  $DashboardUrl"
if ($Hardened) {
    Write-Host ""
    Write-Host "  Security: hardened (localhost only, exec approvals, sandbox)"
}
Write-Host ""
Write-Host "  Commands:"
Write-Host "    .\oc configure    # change AI provider or settings"
Write-Host "    .\oc token        # show gateway token"
Write-Host "    docker compose stop        # stop all"
Write-Host "    docker compose up -d       # start all"
Write-Host ""

# Open browser
Start-Process $DashboardUrl

# --- Auto-approve browser device pairing ---
Write-Host "  Waiting for browser to connect..."
Start-Sleep -Seconds 5
$approved = $false
for ($i = 1; $i -le 30; $i++) {
    $pending = docker exec $GatewayContainer node dist/index.js devices list --json 2>$null
    if ($pending -match '"requestId":"([^"]+)"') {
        docker exec $GatewayContainer node dist/index.js devices approve $matches[1] 2>$null | Out-Null
        Write-Host "  Browser device paired automatically"
        $approved = $true
        break
    }
    Start-Sleep -Seconds 2
}
if (-not $approved) {
    Write-Host "  Tip: if the browser shows 'Pairing required', run: .\oc devices list"
}
