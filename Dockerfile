FROM ghcr.io/cedar2025/xboard-node:latest

USER root

RUN apk add --no-cache bash ca-certificates curl python3 tzdata \
    && arch="$(uname -m)" \
    && case "$arch" in \
      x86_64|amd64) cf_arch="amd64" ;; \
      aarch64|arm64) cf_arch="arm64" ;; \
      *) echo "unsupported architecture: $arch" >&2; exit 1 ;; \
    esac \
    && curl -fsSL -o /usr/local/bin/cloudflared \
      "https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-${cf_arch}" \
    && chmod +x /usr/local/bin/cloudflared \
    && cloudflared --version

COPY docker-entrypoint.sh /usr/local/bin/xboard-node-cf-entrypoint
COPY public /var/www/public
RUN chmod +x /usr/local/bin/xboard-node-cf-entrypoint \
    && mkdir -p /etc/xboard-node /var/log/xboard-node-cf /var/www/public

WORKDIR /etc/xboard-node

EXPOSE 3000

ENTRYPOINT ["xboard-node-cf-entrypoint"]
