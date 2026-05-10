#!/usr/bin/env bash
set -Eeuo pipefail

CONFIG_PATH="${CONFIG_PATH:-/etc/xboard-node/config.yml}"
LOG_DIR="${LOG_DIR:-/var/log/xboard-node-cf}"
XBOARD_NODE_ARGS=()

mkdir -p "$(dirname "$CONFIG_PATH")" "$LOG_DIR"

value_of() {
  local name="$1"
  local fallback="${2:-}"
  printenv "$name" 2>/dev/null || printf '%s' "$fallback"
}

first_env() {
  local name
  for name in "$@"; do
    if [ -n "${!name:-}" ]; then
      printf '%s' "${!name}"
      return 0
    fi
  done
  return 1
}

split_csv() {
  local raw="$1"
  raw="${raw// /}"
  IFS=',' read -r -a SPLIT_CSV_RESULT <<< "$raw"
}

write_config_from_env() {
  local panel_url panel_token machine_id machine_token node_ids node_type log_level kernel_type instance_name
  local cert_file key_file domain cert_mode
  panel_url="$(first_env PANEL_URL API_HOST apiHost || true)"
  panel_token="$(first_env PANEL_TOKEN API_KEY apiKey SERVER_TOKEN || true)"
  machine_id="$(first_env MACHINE_ID machineID || true)"
  machine_token="$(first_env MACHINE_TOKEN machineToken || true)"
  node_ids="$(first_env NODE_IDS NODE_ID nodeID || true)"
  node_type="$(first_env NODE_TYPE nodeType || true)"
  log_level="$(first_env LOG_LEVEL logLevel || true)"
  kernel_type="$(first_env KERNEL_TYPE kernel nodeKernel || true)"
  instance_name="$(first_env INSTANCE_NAME || true)"
  cert_file="$(first_env CERT_FILE certFile || true)"
  key_file="$(first_env KEY_FILE keyFile || true)"
  domain="$(first_env DOMAIN domain || true)"
  cert_mode="$(first_env CERT_MODE certMode || true)"

  if [ -z "$panel_url" ]; then
    echo "CONFIG_PATH does not exist and PANEL_URL/API_HOST/apiHost is empty." >&2
    exit 64
  fi

  if [ -z "$panel_token" ] && { [ -z "$machine_id" ] || [ -z "$machine_token" ]; }; then
    echo "Set PANEL_TOKEN/API_KEY/apiKey or MACHINE_ID + MACHINE_TOKEN." >&2
    exit 64
  fi

  if [ -z "$machine_id" ] && [ -z "$node_ids" ]; then
    echo "Set NODE_ID/NODE_IDS/nodeID when not using machine mode." >&2
    exit 64
  fi

  {
    echo "log:"
    echo "  level: ${log_level:-info}"
    if [ -n "$kernel_type" ]; then
      echo "kernel:"
      echo "  type: ${kernel_type}"
    fi
    if [ -n "$cert_file" ] || [ -n "$key_file" ] || [ -n "$domain" ] || [ -n "$cert_mode" ]; then
      echo "cert:"
      if [ -n "$cert_mode" ]; then
        echo "  cert_mode: ${cert_mode}"
      fi
      if [ -n "$domain" ]; then
        echo "  domain: ${domain}"
        echo "  auto_tls: true"
      fi
      if [ -n "$cert_file" ]; then
        echo "  cert_file: ${cert_file}"
      fi
      if [ -n "$key_file" ]; then
        echo "  key_file: ${key_file}"
      fi
    fi
    echo "instances:"
    echo "  - name: ${instance_name:-xboard-node-cf}"
    echo "    panel:"
    echo "      url: ${panel_url}"
    if [ -n "$panel_token" ]; then
      echo "      token: ${panel_token}"
    fi
    if [ -n "$machine_id" ]; then
      echo "    machine:"
      echo "      machine_id: ${machine_id}"
      echo "      token: ${machine_token}"
    else
      echo "    nodes:"
      split_csv "$node_ids"
      local id
      for id in "${SPLIT_CSV_RESULT[@]}"; do
        if [ -n "$id" ]; then
          echo "      - node_id: ${id}"
          if [ -n "$node_type" ]; then
            echo "        node_type: ${node_type}"
          fi
        fi
      done
    fi
    :
  } > "$CONFIG_PATH"
}

start_cloudflared() {
  local token credentials argo_auth domain url protocol extra_args
  token="$(first_env CF_TUNNEL_TOKEN ARGO_TOKEN TUNNEL_TOKEN || true)"
  credentials="$(first_env CF_TUNNEL_CREDENTIALS_JSON || true)"
  argo_auth="$(first_env ARGO_AUTH || true)"
  domain="$(first_env CF_TUNNEL_HOSTNAME ARGO_HOST ARGO_DOMAIN || true)"
  url="$(first_env CF_TUNNEL_URL TUNNEL_URL URL || true)"
  protocol="$(first_env CF_TUNNEL_PROTOCOL ARGO_PROTOCOL || true)"
  extra_args="${CF_TUNNEL_EXTRA_ARGS:-${ARGO_EXTRA_ARGS:-}}"

  if [ -z "$token" ] && [ -z "$credentials" ] && [ -n "$argo_auth" ]; then
    if [[ "$argo_auth" == *TunnelSecret* || "$argo_auth" == \{* ]]; then
      credentials="$argo_auth"
    else
      token="$argo_auth"
    fi
  fi

  if [ -z "$url" ]; then
    url="http://localhost:${TUNNEL_LOCAL_PORT:-${PORT:-8080}}"
  fi

  if [ -n "$token" ]; then
    if [ -n "$domain" ]; then
      echo "Starting cloudflared with tunnel token for ${domain}."
    else
      echo "Starting cloudflared with tunnel token. Set ARGO_HOST to document the expected public hostname."
    fi
    cloudflared tunnel --edge-ip-version auto --no-autoupdate --protocol "${protocol:-http2}" run --token "$token" $extra_args &
    CLOUDFLARED_PID="$!"
    return 0
  fi

  if [ -n "$credentials" ] && [ -n "$domain" ]; then
    local tunnel_dir credentials_file config_file tunnel_id
    tunnel_dir="/etc/cloudflared"
    credentials_file="${tunnel_dir}/tunnel.json"
    config_file="${tunnel_dir}/config.yml"
    mkdir -p "$tunnel_dir"
    printf '%s' "$credentials" > "$credentials_file"
    tunnel_id="$(python3 - <<'PY' "$credentials_file"
import json, sys
with open(sys.argv[1], "r", encoding="utf-8") as f:
    data=json.load(f)
print(data.get("TunnelID") or data.get("tunnel_id") or "")
PY
)"
    if [ -z "$tunnel_id" ]; then
      echo "CF_TUNNEL_CREDENTIALS_JSON/ARGO_AUTH is set, but TunnelID was not found." >&2
      exit 64
    fi
    cat > "$config_file" <<EOF
tunnel: ${tunnel_id}
credentials-file: ${credentials_file}
protocol: ${protocol:-http2}
ingress:
  - hostname: ${domain}
    service: ${url}
    originRequest:
      noTLSVerify: true
  - service: http_status:404
EOF
    echo "Starting cloudflared with credentials for ${domain} -> ${url}"
    cloudflared tunnel --edge-ip-version auto --config "$config_file" run $extra_args &
    CLOUDFLARED_PID="$!"
    return 0
  fi

  if [ "${CF_TUNNEL_REQUIRED:-${ARGO_REQUIRED:-false}}" = "true" ]; then
    echo "Cloudflare tunnel is required, but no token or credentials were provided." >&2
    exit 64
  fi

  echo "Cloudflare tunnel disabled; set CF_TUNNEL_TOKEN or ARGO_TOKEN to enable it."
}

shutdown() {
  local code=$?
  trap - INT TERM EXIT
  if [ -n "${XBOARD_NODE_PID:-}" ]; then
    kill "$XBOARD_NODE_PID" 2>/dev/null || true
  fi
  if [ -n "${CLOUDFLARED_PID:-}" ]; then
    kill "$CLOUDFLARED_PID" 2>/dev/null || true
  fi
  wait 2>/dev/null || true
  exit "$code"
}

trap shutdown INT TERM EXIT

if [ "$#" -gt 0 ]; then
  case "$1" in
    -v|--version|-h|--help|help|version)
      exec xboard-node "$@"
      ;;
  esac

  for ((i = 1; i <= $#; i++)); do
    arg="${!i}"
    if [ "$arg" = "-c" ]; then
      next_index=$((i + 1))
      if [ "$next_index" -le "$#" ]; then
        CONFIG_PATH="${!next_index}"
      fi
      break
    fi
    case "$arg" in
      -c=*)
        CONFIG_PATH="${arg#-c=}"
        break
        ;;
    esac
  done
fi

if [ ! -s "$CONFIG_PATH" ]; then
  echo "No config file at ${CONFIG_PATH}; generating one from environment variables."
  write_config_from_env
fi

if [ "$#" -gt 0 ]; then
  XBOARD_NODE_ARGS=("$@")
else
  XBOARD_NODE_ARGS=("-c" "$CONFIG_PATH")
fi

CLOUDFLARED_PID=""
start_cloudflared

echo "Starting xboard-node ${XBOARD_NODE_ARGS[*]}"
xboard-node "${XBOARD_NODE_ARGS[@]}" &
XBOARD_NODE_PID="$!"

wait -n "$XBOARD_NODE_PID" ${CLOUDFLARED_PID:-}
