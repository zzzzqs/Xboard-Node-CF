# Xboard-Node-CF

Xboard-Node-CF extends the official `ghcr.io/cedar2025/xboard-node:latest`
image with `cloudflared`, so a node can run on platforms such as Northflank
behind Cloudflare Tunnel.

The original Xboard-Node config remains compatible. Mount
`/etc/xboard-node/config.yml` exactly as before, or let the entrypoint generate
one from environment variables.

The image also serves a small public web page on port `3000`, which is useful
for platforms that require one exposed HTTP port.

## Supported Use Case

This image is intended for HTTP/WebSocket based nodes:

- VLESS + WebSocket
- VMess + WebSocket
- Trojan + WebSocket

It is not suitable for Reality, Hysteria2, TUIC, or native AnyTLS through
Cloudflare Tunnel.

## Xboard Node Settings

For a Cloudflare Tunnel node, create a VLESS node similar to:

```text
Host: v-nf-us-1.199655.xyz
User port: 443
Server port: 8080
Security: TLS, not Reality
Transport: WebSocket
Path: /vless-argo
Host header: v-nf-us-1.199655.xyz
Flow: empty
VLESS encryption: off
Certificate config: none
```

Cloudflare terminates TLS. Xboard-Node listens on plain WebSocket inside the
container.

## Environment Variables

For Northflank + Cloudflare Tunnel token mode, only these variables are needed:

```text
PANEL_URL=https://proxy.199655.xyz
PANEL_TOKEN=your-xboard-communication-key
NODE_ID=9
ARGO_HOST=v-nf-us-1.199655.xyz
ARGO_TOKEN=your-cloudflare-tunnel-token
```

The image still accepts the official Xboard-Node aliases such as `apiHost`,
`apiKey`, `nodeID`, `NODE_IDS`, and advanced Cloudflare variables such as
`ARGO_AUTH`, but you normally do not need them.

In Cloudflare Zero Trust, configure the tunnel public hostname separately:

```text
Hostname: v-nf-us-1.199655.xyz
Service: http://localhost:8080
```

`ARGO_HOST` must match both the Xboard node host and the Cloudflare Tunnel
public hostname. Use a different hostname and tunnel token for each deployed
node.

Port `3000` is only the public environmental page for Northflank. Do not point
the Cloudflare Tunnel service to `3000`; keep the tunnel service on
`http://localhost:8080`.

## Northflank

Use the built image:

```text
ghcr.io/zzzzqs/xboard-node-cf:latest
```

Set environment variables:

```text
PANEL_URL=https://proxy.199655.xyz
PANEL_TOKEN=your-xboard-communication-key
NODE_ID=9
ARGO_HOST=v-nf-us-1.199655.xyz
ARGO_TOKEN=your-cloudflare-tunnel-token
```

Expose port `3000` as HTTP in Northflank. Visiting the Northflank public URL
will show a simple environmental page. Cloudflare Tunnel connects outbound to
the node service on `localhost:8080`, so clients do not use the Northflank URL.

## Local Test

```bash
docker build -t xboard-node-cf:local .
docker run --rm --env-file .env xboard-node-cf:local
```

## Image Build

GitHub Actions builds and pushes a multi-arch image to:

```text
ghcr.io/zzzzqs/xboard-node-cf:latest
```
