# Skill: Azure Container App Worker — Tailscale + SQL Tunnel Pattern

## When to use this skill
Use when asked to set up a new Azure Container App **background worker** (no HTTP ingress) that needs to reach:
- A **private SQL Server** (MSSQL) not exposed to the internet
- A **private REST API** not exposed to the internet
- Optionally a **public SOAP/HTTP endpoint**

…using **Tailscale** as the private network overlay and a **socat TCP tunnel** to work around a .NET SqlClient limitation on Linux.

---

## Architecture Overview

```
[Worker .NET process]
    │
    ├─ HTTP/HTTPS (CRM, etc.)  → HTTP_PROXY=socks5://127.0.0.1:1055 (via tailscaled)
    │
    └─ SQL Server              → ConnectionString Server=<eth0-ip>:<TUNNEL_PORT>
                                      ↓
                               [socat] bind=<eth0-ip>:TUNNEL_PORT
                                      ↓  (via proxychains4 SOCKS5 → 127.0.0.1:1055)
                               [tailscaled] userspace-networking + SOCKS5 server
                                      ↓
                               [Tailscale exit node / relay node]
                                      ↓
                               Real SQL Server on private LAN
```

---

## Why socat + eth0 IP? (Critical knowledge)

`Microsoft.Data.SqlClient` ManagedSNI on Linux sets the socket to **non-blocking** and expects `connect()` to return `EINPROGRESS` (error code indicating connection is in progress).

On Linux, a `connect()` to **loopback (127.x.x.x)** completes **synchronously** — returns `0` immediately. ManagedSNI does not handle a synchronous `0` return on a non-blocking socket, and throws:
> "Socket did not throw expected WouldBlock"

**Fix**: socat must **bind to the container's eth0 IP** (not `127.0.0.1`). A `connect()` to a non-loopback address always goes through the full kernel network stack and returns `EINPROGRESS`. The dotnet worker connects to `<eth0-ip>:<TUNNEL_PORT>` directly (NOT through proxychains) — socat handles the SOCKS5 forwarding to the real SQL Server.

---

## Checklist: What you need to set up

### Prerequisites
- [ ] Tailscale auth key (reusable/ephemeral from admin.tailscale.com) — store as Container App secret `tailscale-authkey`
- [ ] A Tailscale **exit node** or **subnet router** already running on the same private network as SQL Server
- [ ] Exit node IP (Tailscale IP, e.g. `100.x.x.x`) or MagicDNS hostname
- [ ] Target SQL Server private IP and port (e.g. `10.16.150.6:1433`)
- [ ] ACR name, resource group, image repository name

### Container App requirements
- **No ingress** — pure worker. Never add `ingress:` config; it auto-adds a TCP liveness probe that kills the container.
- `minReplicas: 1`, `maxReplicas: 1` for single-instance workers
- `activeRevisionsMode: Single`

---

## Dockerfile requirements

Base image: `mcr.microsoft.com/dotnet/aspnet:10.0-alpine` (or your .NET version + alpine)

Required Alpine packages:
```dockerfile
RUN apk add --no-cache \
  curl ca-certificates icu-libs iptables iproute2 jq proxychains-ng socat
```

Copy Tailscale binaries from the official image:
```dockerfile
COPY --from=tailscale/tailscale:stable /usr/local/bin/tailscaled /usr/local/bin/tailscaled
COPY --from=tailscale/tailscale:stable /usr/local/bin/tailscale /usr/local/bin/tailscale
```

Configure proxychains4:
```dockerfile
RUN printf '%s\n' \
  'strict_chain' \
  'remote_dns_subnet 224' \
  'tcp_read_time_out 15000' \
  'tcp_connect_time_out 8000' \
  '[ProxyList]' \
  'socks5 127.0.0.1 1055' \
  > /etc/proxychains.conf
```

Set the entrypoint to `start.sh`:
```dockerfile
COPY start.sh /app/start.sh
RUN chmod +x /app/start.sh
ENTRYPOINT ["/app/start.sh"]
```

---

## start.sh — Container Entrypoint Template

```sh
#!/bin/sh
set -eu

TAILSCALED_PID="" WORKER_PID="" SOCAT_PID=""

cleanup() {
    [ -n "$WORKER_PID" ] && kill "$WORKER_PID" 2>/dev/null || true
    [ -n "$SOCAT_PID" ] && kill "$SOCAT_PID" 2>/dev/null || true
    [ -n "$TAILSCALED_PID" ] && kill "$TAILSCALED_PID" 2>/dev/null || true
}
trap cleanup EXIT INT TERM

wait_for_socket() {
    i=0
    while [ ! -S /run/tailscale/tailscaled.sock ] && [ "$i" -lt 30 ]; do
        i=$((i+1)); sleep 1
    done
    [ -S /run/tailscale/tailscaled.sock ]
}

is_true() {
    case "$1" in true|TRUE|1|yes) return 0;; *) return 1;; esac
}

# --- 1. Start tailscaled ---
mkdir -p /tmp/tailscale /run/tailscale
tailscaled \
    --state=/tmp/tailscale/state.db \
    --socket=/run/tailscale/tailscaled.sock \
    --tun=userspace-networking \
    --socks5-server=127.0.0.1:1055 &
TAILSCALED_PID=$!
export TS_SOCKET=/run/tailscale/tailscaled.sock
wait_for_socket

# --- 2. Join tailnet ---
if [ -n "${TAILSCALE_AUTHKEY:-}" ]; then
    tailscale up \
        --auth-key "${TAILSCALE_AUTHKEY}" \
        --hostname "${TAILSCALE_HOSTNAME:-my-worker}" \
        --accept-routes --accept-dns=false --reset || true

    if [ -n "${TAILSCALE_EXIT_NODE:-}" ]; then
        tailscale set --exit-node="${TAILSCALE_EXIT_NODE}" || true
        TS_WARMUP="${TAILSCALE_EXIT_NODE_WARMUP_SECONDS:-10}"
        echo "Waiting ${TS_WARMUP}s for exit-node route to stabilise..."
        sleep "$TS_WARMUP"
    fi
fi

# --- 3. Set proxy env vars and SQL tunnel ---
if is_true "${TAILSCALE_ENFORCE_PROXY:-false}"; then
    export HTTP_PROXY="socks5://127.0.0.1:1055"
    export HTTPS_PROXY="socks5://127.0.0.1:1055"
    export ALL_PROXY="socks5://127.0.0.1:1055"

    # NO_PROXY: keep public cloud endpoints and the SOAP/internal endpoints off SOCKS5.
    # CRITICAL: App Insights MUST be in NO_PROXY or it floods the proxy → OOM.
    export NO_PROXY="localhost,127.0.0.1,.azure.com,.windows.net,.microsoft.com"
    # Add any additional public hostnames your service calls:
    # export NO_PROXY="${NO_PROXY},your-public-endpoint.example.com"
    export no_proxy="$NO_PROXY"

    if [ -n "${SQLSERVER_TUNNEL_TARGET:-}" ] && command -v socat >/dev/null 2>&1; then
        TUNNEL_PORT="${SQLSERVER_TUNNEL_PORT:-14330}"

        # MUST use eth0 IP — NOT loopback — due to SqlClient ManagedSNI EINPROGRESS requirement
        CONTAINER_IP=$(ip route get 8.8.8.8 2>/dev/null | grep -oE 'src [0-9.]+' | awk '{print $2}')
        [ -z "$CONTAINER_IP" ] && CONTAINER_IP=$(hostname -i 2>/dev/null | awk '{print $1}')

        proxychains4 -q -f /etc/proxychains.conf socat \
            "TCP4-LISTEN:${TUNNEL_PORT},bind=${CONTAINER_IP},fork,reuseaddr" \
            "TCP:${SQLSERVER_TUNNEL_TARGET}" &
        SOCAT_PID=$!

        # Wait for socat to start listening
        j=0
        while [ "$j" -lt 10 ] && ! (echo "" | nc -w1 "${CONTAINER_IP}" "${TUNNEL_PORT}" >/dev/null 2>&1); do
            j=$((j+1)); sleep 1
        done

        # Rewrite connection strings so the app connects to the tunnel
        # Pattern matches any Server= value (hostname or IP, case-insensitive)
        export ConnectionStrings__DefaultConnection="$(echo "${ConnectionStrings__DefaultConnection:-}" | \
            sed "s|[Ss]erver=[^;]*|Server=${CONTAINER_IP},${TUNNEL_PORT}|g")"
        export ConnectionStrings__SqlServerConnection="$(echo "${ConnectionStrings__SqlServerConnection:-}" | \
            sed "s|[Ss]erver=[^;]*|Server=${CONTAINER_IP},${TUNNEL_PORT}|g")"
    fi
fi

export ASPNETCORE_ENVIRONMENT="${ASPNETCORE_ENVIRONMENT:-Production}"
export DOTNET_RUNNING_IN_CONTAINER=true

# Start .NET worker WITHOUT proxychains — SQL uses socat tunnel, HTTP uses HTTP_PROXY env vars
dotnet YourWorker.dll &
WORKER_PID=$!
wait "$WORKER_PID"
```

**Key rule**: Do NOT wrap `dotnet` with `proxychains4`. SqlClient ManagedSNI breaks when `LD_PRELOAD` intercepts `connect()`. Only socat runs under proxychains.

---

## Bicep parameters to add

Add these to your `main.bicep`:

```bicep
@description('Tailscale auth key')
@secure()
param tailscaleAuthKey string

param tailscaleHostname string = 'my-worker-${environment}'
param tailscaleExitNode string = ''           // Tailscale IP of exit node
param tailscaleExitNodeAllowLanAccess bool = false
param tailscaleEnforceProxy bool = true

@description('socat target: host:port of the real SQL Server')
param sqlServerTunnelTarget string = ''

@description('socat local listener port')
param sqlServerTunnelPort int = 14330
```

Wire them as container env vars:
```bicep
{ name: 'TAILSCALE_AUTHKEY',               secretRef: 'tailscale-authkey' }
{ name: 'TAILSCALE_HOSTNAME',              value: tailscaleHostname }
{ name: 'TAILSCALE_EXIT_NODE',             value: tailscaleExitNode }
{ name: 'TAILSCALE_EXIT_NODE_ALLOW_LAN_ACCESS', value: string(tailscaleExitNodeAllowLanAccess) }
{ name: 'TAILSCALE_ENFORCE_PROXY',         value: string(tailscaleEnforceProxy) }
{ name: 'SQLSERVER_TUNNEL_TARGET',         value: sqlServerTunnelTarget }
{ name: 'SQLSERVER_TUNNEL_PORT',           value: string(sqlServerTunnelPort) }
```

Store `tailscaleAuthKey` as a secret:
```bicep
{ name: 'tailscale-authkey', value: tailscaleAuthKey }
```

**IMPORTANT**: Do NOT add an `ingress:` block in the Bicep for a pure worker. If you have one already:
```bash
az containerapp update --resource-group <rg> --name <app> --ingress disabled
```

---

## EF Core — SQL retry registration (Program.cs)

```csharp
options.UseSqlServer(sqlServerConnection, x =>
{
    x.CommandTimeout(commandTimeout);
    x.EnableRetryOnFailure(
        maxRetryCount: 5,
        maxRetryDelay: TimeSpan.FromSeconds(15),
        errorNumbersToAdd: [11001]);  // 11001 = DNS resolution failure
});
```

Error 11001 is needed because the socat tunnel can be briefly unavailable during the exit-node warmup period on the first cycle.

---

## Deployment: env var gotcha with ACA immutable revisions

Bicep incremental deploy will **not** create a new revision if the image tag is the same. Use `az containerapp update --yaml` for every deployment that changes env vars or image.

Minimal YAML template (`/tmp/ca-update.yaml`):
```yaml
properties:
  configuration:
    activeRevisionsMode: Single
    secrets:
      - name: tailscale-authkey
        value: "tskey-auth-XXXX"
      - name: default-db-connection
        value: "Server=...;Database=...;..."
      - name: sqlserver-connection
        value: "Server=...;..."
      # add other secrets here
  template:
    revisionSuffix: "v002"
    containers:
      - name: worker
        image: "youracr.azurecr.io/your-image:v002"
        resources:
          cpu: 0.5
          memory: 1.0Gi
        probes: []
        env:
          - name: ASPNETCORE_ENVIRONMENT
            value: Production
          - name: TAILSCALE_EXIT_NODE
            value: "100.x.x.x"
          - name: TAILSCALE_ENFORCE_PROXY
            value: "true"
          - name: SQLSERVER_TUNNEL_TARGET
            value: "10.x.x.x:1433"
          - name: SQLSERVER_TUNNEL_PORT
            value: "14330"
          - name: ConnectionStrings__SqlServerConnection
            secretRef: sqlserver-connection
          # ... all other env vars
    scale:
      minReplicas: 1
      maxReplicas: 1
```

Apply:
```bash
az containerapp update \
  --resource-group <rg> \
  --name <app> \
  --yaml /tmp/ca-update.yaml \
  --query properties.latestRevisionName -o tsv
```

---

## Build + push commands (with podman)

```bash
TAG=v002
ACR=youracr.azurecr.io
IMAGE=your-image-name

podman build \
  --file Backend/YourProject/Dockerfile \
  --tag ${ACR}/${IMAGE}:${TAG} .

ACR_TOKEN=$(az acr login --name youracr --expose-token --output tsv --query accessToken)
podman login ${ACR} --username 00000000-0000-0000-0000-000000000000 --password "$ACR_TOKEN"
podman push ${ACR}/${IMAGE}:${TAG}
```

---

## Common failure modes and fixes

| Symptom | Root cause | Fix |
|---|---|---|
| "Socket did not throw expected WouldBlock" | socat bound to 127.x.x.x loopback | Change socat `bind=` to eth0 IP |
| Container killed every ~4 min | ACA ingress auto-adds TCP liveness probe | `az containerapp update --ingress disabled` |
| OOM / massive memory growth | App Insights using SOCKS5 → thousands of pending connections | Add `*.azure.com` to `NO_PROXY` |
| DNS timeout on first SOAP/HTTP call | Exit node routing not stabilised | Add `sleep $TS_WARMUP` (10 s) after `tailscale set --exit-node` |
| SQL query timeout on cleanup / large table | No row cap on EF query | Add `.Take(maxRowsPerRun)` — use plain int, NOT `EF.Constant<T>` |
| Env var changes not applied | Bicep immutable revision, same tag | Use `az containerapp update --yaml` with bumped `revisionSuffix` |
| `probes: []` in Bicep doesn't clear probes | No-op in ARM for existing probes | Use `--yaml` or disable ingress |
| `EF.Constant<T>` build error with `.Take()` | Only valid inside LINQ lambdas | Use plain `.Take(intVariable)` |
| Connection string not rewritten | `sed` pattern matched hostname but env var had IP (or vice versa) | Use `[Ss]erver=[^;]*` pattern — matches any value |
| Worker not reaching private endpoint | No exit node configured or wrong IP | Verify `tailscale status` shows exit node as online |

---

## NO_PROXY must-haves

Always include:
```
localhost,127.0.0.1,.azure.com,.windows.net,.microsoft.com
```

Add any **public** SOAP/REST endpoints your service calls directly (not via private LAN) so they bypass SOCKS5:
```
,your-public-soap.example.com
```

---

## Alternative: NetBird + microsocks (Option B — ACA compatible)

> **Status**: Not yet tested — documented for future validation.  
> Use this when you want to replace Tailscale with NetBird as the overlay network.  
> The socat + eth0 IP workaround is **identical** — only the VPN daemon and SOCKS5 source change.

### Why Option B (not Option A)

Azure Container Apps do **not** grant `CAP_NET_ADMIN` or expose `/dev/net/tun`.  
NetBird's kernel WireGuard mode requires both → Option A (direct WireGuard interface) is blocked.  
Option B stays fully in userspace and needs no extra privileges.

```
[Worker .NET process]
    │
    ├─ HTTP_PROXY=socks5://127.0.0.1:1055  →  [microsocks]
    │                                               │
    └─ SQL via socat (eth0-bound)  → proxychains4  ┘
                                                    │
                                             [netbird daemon]  ← userspace WireGuard (wireguard-go)
                                                    │
                                          NetBird management server
                                                    │
                                         NetBird peer on private LAN
                                                    │
                                           Real SQL Server / CRM API
```

### Prerequisites

- [ ] NetBird account (cloud: `app.netbird.io`, or self-hosted)
- [ ] **Setup key** from NetBird admin → Settings → Setup Keys (create one, mark reusable)
- [ ] A NetBird **peer already enrolled** on the same private network as SQL Server (the machine that can reach `10.x.x.x`)  
  — this peer acts as a subnet router, advertising the private CIDR (e.g. `10.16.0.0/16`)
- [ ] That peer has **subnet routing enabled** in NetBird admin (Peers → peer → Routes)
- [ ] ACR, resource group, image repo name (same as Tailscale setup)

### Dockerfile changes

Replace the Tailscale section with NetBird + microsocks:

```dockerfile
# Remove Tailscale lines, add:

# Install microsocks (tiny SOCKS5 server, ~50KB, no deps)
# and NetBird runtime deps
RUN apk add --no-cache \
  curl ca-certificates icu-libs iptables iproute2 jq proxychains-ng socat \
  wireguard-tools

# Build microsocks from source (not in Alpine main repos as of 3.19)
# or use a pre-built binary. Using wget from a known release:
RUN wget -qO /usr/local/bin/microsocks \
      https://github.com/rofl0r/microsocks/releases/latest/download/microsocks-linux-x86_64 \
  && chmod +x /usr/local/bin/microsocks

# Copy NetBird binary from official image
COPY --from=netbirdio/netbird:latest /usr/local/bin/netbird /usr/local/bin/netbird
```

> **Note for testing**: Verify the `microsocks` release URL is current from https://github.com/rofl0r/microsocks/releases.  
> Alternative: build from source in the Dockerfile (`RUN apk add gcc musl-dev make && git clone ... && make`).  
> Alternative SOCKS5 daemons: `dante-server`, `3proxy` (heavier but more configurable).

The proxychains config stays identical:
```dockerfile
RUN printf '%s\n' \
  'strict_chain' \
  'remote_dns_subnet 224' \
  'tcp_read_time_out 15000' \
  'tcp_connect_time_out 8000' \
  '[ProxyList]' \
  'socks5 127.0.0.1 1055' \
  > /etc/proxychains.conf
```

### start.sh changes

Replace the tailscaled/tailscale blocks with:

```sh
NETBIRD_PID="" MICROSOCKS_PID="" WORKER_PID="" SOCAT_PID=""

cleanup() {
    [ -n "$WORKER_PID" ]     && kill "$WORKER_PID"     2>/dev/null || true
    [ -n "$SOCAT_PID" ]      && kill "$SOCAT_PID"      2>/dev/null || true
    [ -n "$MICROSOCKS_PID" ] && kill "$MICROSOCKS_PID" 2>/dev/null || true
    [ -n "$NETBIRD_PID" ]    && kill "$NETBIRD_PID"    2>/dev/null || true
}
trap cleanup EXIT INT TERM

is_true() {
    case "$1" in true|TRUE|1|yes) return 0;; *) return 1;; esac
}

echo "[1/4] Starting microsocks SOCKS5 server on 127.0.0.1:1055"
microsocks -i 127.0.0.1 -p 1055 &
MICROSOCKS_PID=$!
# Give it a moment to bind
sleep 1

echo "[2/4] Starting NetBird daemon (userspace WireGuard)"
mkdir -p /tmp/netbird
netbird up \
    --setup-key "${NETBIRD_SETUP_KEY}" \
    --hostname "${NETBIRD_HOSTNAME:-my-worker}" \
    --log-level info \
    --daemon-addr unix:///tmp/netbird/sock \
    &
NETBIRD_PID=$!

# Wait for NetBird to connect (peer status becomes Connected)
echo "Waiting for NetBird to connect..."
NB_WAIT="${NETBIRD_CONNECT_TIMEOUT_SECONDS:-30}"
i=0
while [ "$i" -lt "$NB_WAIT" ]; do
    if netbird status --daemon-addr unix:///tmp/netbird/sock 2>/dev/null | grep -q "Connected"; then
        echo "NetBird connected"
        break
    fi
    i=$((i+1)); sleep 1
done

# Additional stabilisation time for route advertisement to propagate
NB_WARMUP="${NETBIRD_WARMUP_SECONDS:-10}"
echo "Waiting ${NB_WARMUP}s for subnet routes to stabilise..."
sleep "$NB_WARMUP"

echo "[3/4] Setting proxy env vars and SQL tunnel"
if is_true "${NETBIRD_ENFORCE_PROXY:-false}"; then
    export HTTP_PROXY="socks5://127.0.0.1:1055"
    export HTTPS_PROXY="socks5://127.0.0.1:1055"
    export ALL_PROXY="socks5://127.0.0.1:1055"
    export NO_PROXY="localhost,127.0.0.1,.azure.com,.windows.net,.microsoft.com"
    # Add public endpoints that must bypass SOCKS5:
    # export NO_PROXY="${NO_PROXY},your-soap-endpoint.example.com"
    export no_proxy="$NO_PROXY"

    if [ -n "${SQLSERVER_TUNNEL_TARGET:-}" ] && command -v socat >/dev/null 2>&1; then
        TUNNEL_PORT="${SQLSERVER_TUNNEL_PORT:-14330}"
        CONTAINER_IP=$(ip route get 8.8.8.8 2>/dev/null | grep -oE 'src [0-9.]+' | awk '{print $2}')
        [ -z "$CONTAINER_IP" ] && CONTAINER_IP=$(hostname -i 2>/dev/null | awk '{print $1}')

        echo "Setting up SQL tunnel: ${CONTAINER_IP}:${TUNNEL_PORT} -> ${SQLSERVER_TUNNEL_TARGET}"
        proxychains4 -q -f /etc/proxychains.conf socat \
            "TCP4-LISTEN:${TUNNEL_PORT},bind=${CONTAINER_IP},fork,reuseaddr" \
            "TCP:${SQLSERVER_TUNNEL_TARGET}" &
        SOCAT_PID=$!

        j=0
        while [ "$j" -lt 10 ] && ! (echo "" | nc -w1 "${CONTAINER_IP}" "${TUNNEL_PORT}" >/dev/null 2>&1); do
            j=$((j+1)); sleep 1
        done
        echo "SQL tunnel ready (waited ${j}s)"

        export ConnectionStrings__DefaultConnection="$(echo "${ConnectionStrings__DefaultConnection:-}" | \
            sed "s|[Ss]erver=[^;]*|Server=${CONTAINER_IP},${TUNNEL_PORT}|g")"
        export ConnectionStrings__SqlServerConnection="$(echo "${ConnectionStrings__SqlServerConnection:-}" | \
            sed "s|[Ss]erver=[^;]*|Server=${CONTAINER_IP},${TUNNEL_PORT}|g")"
    fi
fi

export ASPNETCORE_ENVIRONMENT="${ASPNETCORE_ENVIRONMENT:-Production}"
export DOTNET_RUNNING_IN_CONTAINER=true

echo "[4/4] Starting worker"
dotnet YourWorker.dll &
WORKER_PID=$!
wait "$WORKER_PID"
```

### Bicep parameters (swap Tailscale → NetBird)

```bicep
@secure()
param netbirdSetupKey string

param netbirdHostname string = 'my-worker-${environment}'
param netbirdEnforceProxy bool = true
param netbirdConnectTimeoutSeconds int = 30
param netbirdWarmupSeconds int = 10

param sqlServerTunnelTarget string = ''
param sqlServerTunnelPort int = 14330
```

Env vars in container spec:
```bicep
{ name: 'NETBIRD_SETUP_KEY',                    secretRef: 'netbird-setup-key' }
{ name: 'NETBIRD_HOSTNAME',                     value: netbirdHostname }
{ name: 'NETBIRD_ENFORCE_PROXY',                value: string(netbirdEnforceProxy) }
{ name: 'NETBIRD_CONNECT_TIMEOUT_SECONDS',      value: string(netbirdConnectTimeoutSeconds) }
{ name: 'NETBIRD_WARMUP_SECONDS',               value: string(netbirdWarmupSeconds) }
{ name: 'SQLSERVER_TUNNEL_TARGET',              value: sqlServerTunnelTarget }
{ name: 'SQLSERVER_TUNNEL_PORT',                value: string(sqlServerTunnelPort) }
```

Secret:
```bicep
{ name: 'netbird-setup-key', value: netbirdSetupKey }
```

### Key unknowns to validate during testing

1. **NetBird userspace mode on ACA** — confirm it starts successfully without `/dev/net/tun` or `CAP_NET_ADMIN`. The flag `--no-iface` or netbird's built-in wireguard-go path may need to be forced explicitly.
2. **microsocks binary availability** — confirm the release URL is reachable from Docker build context, or switch to building from source.
3. **Subnet route advertisement delay** — the 10 s warmup may need tuning. NetBird advertises routes via its management server; the peer on the LAN side must have the route approved in the admin panel.
4. **proxychains4 + NetBird DNS** — NetBird may set up its own DNS resolver. Confirm `--accept-dns=false` equivalent flag, or ensure the resolver doesn't conflict with `remote_dns_subnet 224` in proxychains.conf.
5. **microsocks and SOCKS5 auth** — microsocks supports optional username/password. The proxychains.conf `[ProxyList]` line would need to change to `socks5 127.0.0.1 1055 user pass` if auth is enabled.
6. **`netbird status` command syntax** — verify the `--daemon-addr` flag and `Connected` grep string against the installed NetBird version.

### Comparison with Tailscale version

| | Tailscale | NetBird (Option B) |
|---|---|---|
| VPN daemon | `tailscaled` | `netbird` (wireguard-go built-in) |
| SOCKS5 source | Built into tailscaled | `microsocks` sidecar |
| Auth credential | `tskey-auth-xxx` | Setup Key from NetBird admin |
| Exit node concept | Exit node (any tailnet peer) | Subnet router (peer advertising CIDR) |
| Admin portal | admin.tailscale.com | app.netbird.io (or self-hosted) |
| Route approval | Automatic with exit node | Subnet routes must be approved in admin panel |
| `proxychains.conf` | Identical | Identical |
| socat eth0 binding | Required | Required (same reason) |
| `NO_PROXY` rules | Same | Same |
| Connection string rewrite | Same `sed` | Same `sed` |
| Tested on ACA | ✅ Confirmed working (dp33) | ⚠️ Not yet tested |

---

## Reference: existing implementation
- `Backend/CDM.NET.SyncService/CDM.NET.SyncService.Worker.Downloader/start.sh`
- `Backend/CDM.NET.SyncService/CDM.NET.SyncService.Worker.Downloader/Dockerfile`
- `Backend/CDM.NET.SyncService/CDM.NET.SyncService.Worker.Downloader/main.bicep`
- `Backend/CDM.NET.SyncService/CDM.NET.SyncService.Worker.Downloader/main.bicepparam`
- `Backend/CDM.NET.SyncService/CDM.NET.SyncService.Worker.Downloader/deploy.sh`
- `Backend/CDM.NET.SyncService/CDM.NET.SyncService.Worker.Downloader/Program.cs`
