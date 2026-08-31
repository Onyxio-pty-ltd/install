#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

PLATFORM_SERVICE_NAME="platform"

compose() {
  if docker compose version >/dev/null 2>&1; then
    docker compose "$@"
  elif command -v docker-compose >/dev/null 2>&1; then
    docker-compose "$@"
  else
    echo "Docker Compose is required." >&2
    exit 1
  fi
}

random_secret() {
  if command -v openssl >/dev/null 2>&1; then
    openssl rand -hex 32
  else
    date +%s%N | sha256sum | awk '{print $1}'
  fi
}

detect_ips() {
  hostname -I 2>/dev/null | tr ' ' '\n' | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' | grep -v '^127\.' || true
}

prompt() {
  local message="$1"
  local default_value="${2:-}"
  local value=""

  if [ -r /dev/tty ]; then
    if [ -n "$default_value" ]; then
      read -r -p "${message} [${default_value}]: " value </dev/tty
      echo "${value:-$default_value}"
    else
      read -r -p "${message}: " value </dev/tty
      echo "$value"
    fi
    return
  fi

  echo "$default_value"
}

prompt_yes_no() {
  local message="$1"
  local default_value="${2:-n}"
  local value=""

  if [ ! -r /dev/tty ]; then
    echo "$default_value"
    return
  fi

  read -r -p "${message} [${default_value}]: " value </dev/tty
  value="${value:-$default_value}"
  case "$(printf '%s' "$value" | tr '[:upper:]' '[:lower:]')" in
    y | yes | true | 1)
      echo "y"
      ;;
    *)
      echo "n"
      ;;
  esac
}

set_env_value() {
  local file="$1"
  local key="$2"
  local value="$3"

  if grep -q "^${key}=" "$file"; then
    local tmp
    tmp="$(mktemp)"
    awk -v key="$key" -v value="$value" '
      BEGIN { replaced = 0 }
      $0 ~ "^" key "=" {
        print key "=" value
        replaced = 1
        next
      }
      { print }
      END {
        if (!replaced) print key "=" value
      }
    ' "$file" > "$tmp"
    mv "$tmp" "$file"
  else
    printf '%s=%s\n' "$key" "$value" >> "$file"
  fi
}

env_value() {
  local file="$1"
  local key="$2"
  grep "^${key}=" "$file" 2>/dev/null | tail -n 1 | cut -d= -f2- || true
}

install_license_public_key() {
  local target="data/uploads/license/public-key.pem"
  local source="$SCRIPT_DIR/license/public-key.pem"

  if [ -s "$target" ]; then
    echo "Existing Onyxio license public key found; keeping it."
    return
  fi

  if [ ! -s "$source" ]; then
    echo "Bundled Onyxio license public key is missing; license verification will require manual setup." >&2
    return
  fi

  mkdir -p "$(dirname "$target")"
  cp "$source" "$target"
  chmod 0644 "$target"
  echo "Installed Onyxio license public key."
}

require_network_agent_dependencies() {
  local missing_packages=()

  if ! command -v curl >/dev/null 2>&1; then
    missing_packages+=(curl)
  fi
  if ! command -v python3 >/dev/null 2>&1; then
    missing_packages+=(python3)
  fi
  if ! command -v netplan >/dev/null 2>&1; then
    missing_packages+=(netplan.io)
  fi
  if ! command -v ip >/dev/null 2>&1; then
    missing_packages+=(iproute2)
  fi

  if [ "${#missing_packages[@]}" -eq 0 ]; then
    return
  fi

  if command -v apt-get >/dev/null 2>&1; then
    echo "Installing host packages for the Onyxio network agent: ${missing_packages[*]}"
    apt-get update
    apt-get install -y "${missing_packages[@]}"
    return
  fi

  echo "Missing host packages required for the Onyxio network agent: ${missing_packages[*]}" >&2
  echo "Install them, then run this installer again." >&2
  exit 1
}

wait_for_network_agent() {
  local health_url="http://127.0.0.1:8097/health"
  local status_url="http://127.0.0.1:8097/status"
  local timeout_seconds=20
  local deadline=$((SECONDS + timeout_seconds))

  while [ "$SECONDS" -lt "$deadline" ]; do
    if curl -fsS "$health_url" >/dev/null 2>&1 && curl -fsS "$status_url" >/dev/null 2>&1; then
      echo "Onyxio host network agent is running."
      return
    fi

    if ! systemctl is-active --quiet onyxio-network-agent.service; then
      echo "Onyxio network agent failed to start." >&2
      systemctl status onyxio-network-agent.service --no-pager >&2 || true
      journalctl -u onyxio-network-agent.service -n 80 --no-pager >&2 || true
      exit 1
    fi

    sleep 1
  done

  echo "Onyxio network agent started, but did not become ready within ${timeout_seconds} seconds." >&2
  systemctl status onyxio-network-agent.service --no-pager >&2 || true
  journalctl -u onyxio-network-agent.service -n 80 --no-pager >&2 || true
  exit 1
}

install_network_agent() {
  local agent_source service_file
  agent_source="$SCRIPT_DIR/network-agent.py"
  service_file="/etc/systemd/system/onyxio-network-agent.service"

  if ! command -v systemctl >/dev/null 2>&1; then
    echo "systemd is required for the Onyxio host network agent." >&2
    exit 1
  fi

  mkdir -p "$SCRIPT_DIR/network-agent"
  if [ -f "$agent_source" ]; then
    cp "$agent_source" "$SCRIPT_DIR/network-agent/agent.py"
  else
    curl -fsSL "${ONYXIO_INSTALL_BASE_URL:-https://install.onyxio.com.au}/network-agent.py" \
      -o "$SCRIPT_DIR/network-agent/agent.py"
  fi
  chmod 0755 "$SCRIPT_DIR/network-agent/agent.py"

  cat > "$service_file" <<EOF
[Unit]
Description=Onyxio Network Agent
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
Environment=ONYXIO_NETWORK_AGENT_HOST=127.0.0.1
Environment=ONYXIO_NETWORK_AGENT_PORT=8097
Environment=ONYXIO_NETPLAN_FILE=/etc/netplan/99-onyxio.yaml
ExecStart=/usr/bin/env python3 ${SCRIPT_DIR}/network-agent/agent.py
Restart=on-failure
RestartSec=3
User=root
Group=root

[Install]
WantedBy=multi-user.target
EOF

  systemctl daemon-reload
  systemctl enable --now onyxio-network-agent.service >/dev/null
  systemctl restart onyxio-network-agent.service
  wait_for_network_agent
}

configure_https_env() {
  local server_ip="$1"
  local allow_prompt="${2:-false}"
  local enable_https="${ONYXIO_ENABLE_HTTPS:-}"

  if [ -z "$enable_https" ] && grep -q '^ONYXIO_ENABLE_HTTPS=true' .env 2>/dev/null; then
    enable_https="true"
  fi

  if [ -z "$enable_https" ] && [ "$allow_prompt" = "true" ]; then
    enable_https="$(prompt_yes_no "Configure optional HTTPS front door for mobile AI now?" "n")"
  fi

  case "$(printf '%s' "$enable_https" | tr '[:upper:]' '[:lower:]')" in
    y | yes | true | 1)
      ;;
    *)
      return
      ;;
  esac

  local https_host listen_addr https_port proxy_image
  https_host="${HTTPS_HOST:-$(env_value .env HTTPS_HOST)}"
  if [ -z "$https_host" ]; then
    https_host="$(prompt "HTTPS hostname for guest phones" "")"
  fi
  if [ -z "$https_host" ]; then
    echo "HTTPS was requested but no HTTPS_HOST was provided; skipping HTTPS proxy setup." >&2
    return
  fi

  listen_addr="${HTTPS_LISTEN_ADDR:-$(env_value .env HTTPS_LISTEN_ADDR)}"
  listen_addr="${listen_addr:-$server_ip}"
  https_port="${HTTPS_PORT:-$(env_value .env HTTPS_PORT)}"
  https_port="${https_port:-443}"
  proxy_image="${HTTPS_PROXY_IMAGE:-$(env_value .env HTTPS_PROXY_IMAGE)}"
  proxy_image="${proxy_image:-nginx:1.27-alpine}"

  set_env_value .env ONYXIO_ENABLE_HTTPS true
  set_env_value .env HTTPS_HOST "$https_host"
  set_env_value .env HTTPS_LISTEN_ADDR "$listen_addr"
  set_env_value .env HTTPS_PORT "$https_port"
  set_env_value .env HTTPS_PROXY_IMAGE "$proxy_image"
  set_env_value .env MOBILE_APP_PUBLIC_URL "https://${https_host}/mobile/"
}

tls_certificates_available() {
  [ -s data/tls/fullchain.pem ] && [ -s data/tls/privkey.pem ]
}

https_configured() {
  grep -q '^ONYXIO_ENABLE_HTTPS=true' .env 2>/dev/null &&
    [ -n "$(env_value .env HTTPS_HOST)" ] &&
    [ -f docker-compose.https.yml ]
}

start_compose() {
  if https_configured && tls_certificates_available; then
    compose -f docker-compose.yml -f docker-compose.https.yml up -d
    return
  fi

  compose -f docker-compose.yml up -d
}

print_onyxio_startup_logs() {
  echo
  echo "Recent Onyxio backend logs:"
  compose -f docker-compose.yml logs --tail=160 "$PLATFORM_SERVICE_NAME" || true
}

wait_for_onyxio_startup() {
  local timeout_seconds="${ONYXIO_INSTALL_STARTUP_TIMEOUT_SECONDS:-120}"
  local port
  port="$(env_value .env PORT)"
  port="${port:-4000}"

  echo "Waiting for Onyxio backend startup checks to pass."
  local start_time
  start_time="$(date +%s)"
  local initial_restart_count=""

  while [ $(( $(date +%s) - start_time )) -lt "$timeout_seconds" ]; do
    local container_id
    container_id="$(compose -f docker-compose.yml ps -q "$PLATFORM_SERVICE_NAME" 2>/dev/null || true)"

    if [ -n "$container_id" ]; then
      local running restarting restart_count
      running="$(docker inspect -f '{{.State.Running}}' "$container_id" 2>/dev/null || echo false)"
      restarting="$(docker inspect -f '{{.State.Restarting}}' "$container_id" 2>/dev/null || echo false)"
      restart_count="$(docker inspect -f '{{.RestartCount}}' "$container_id" 2>/dev/null || echo 0)"
      case "$restart_count" in
        '' | *[!0-9]*)
          restart_count=0
          ;;
      esac

      if [ -z "$initial_restart_count" ]; then
        initial_restart_count="$restart_count"
      fi

      if [ "$restarting" = "true" ] || [ "$restart_count" -gt "$initial_restart_count" ]; then
        echo "Onyxio backend restarted during startup; install did not complete cleanly." >&2
        print_onyxio_startup_logs >&2
        return 1
      fi

      if [ "$running" != "true" ]; then
        echo "Onyxio backend container stopped during startup; install did not complete cleanly." >&2
        print_onyxio_startup_logs >&2
        return 1
      fi

      if ( : > "/dev/tcp/127.0.0.1/${port}" ) >/dev/null 2>&1; then
        echo "Onyxio backend is accepting connections on port ${port}."
        return 0
      fi
    fi

    sleep 2
  done

  echo "Onyxio backend did not accept connections on port ${port} within ${timeout_seconds} seconds." >&2
  print_onyxio_startup_logs >&2
  return 1
}

print_https_summary() {
  if ! https_configured; then
    return
  fi

  local https_host listen_addr https_port
  https_host="$(env_value .env HTTPS_HOST)"
  listen_addr="$(env_value .env HTTPS_LISTEN_ADDR)"
  https_port="$(env_value .env HTTPS_PORT)"
  https_port="${https_port:-443}"

  echo
  echo "HTTPS front door:"
  echo "  DNS/split DNS: ${https_host} -> ${listen_addr}"
  echo "  Firewall: allow guest clients to ${listen_addr} TCP ${https_port}"
  echo "  Admin: HTTPS activation is managed from Settings > Network."

  if tls_certificates_available; then
    echo "  Proxy: running via docker-compose.https.yml"
    echo "  Mobile HTTPS: https://${https_host}/mobile/"
  else
    echo "  Proxy: not started because TLS files are missing."
    echo "  Put certificates at:"
    echo "    ./data/tls/fullchain.pem"
    echo "    ./data/tls/privkey.pem"
    echo "  Then start nginx with:"
    echo "    docker compose -f docker-compose.yml -f docker-compose.https.yml up -d"
  fi
}

run_preflight() {
  case "$(printf '%s' "${ONYXIO_SKIP_PREFLIGHT:-}" | tr '[:upper:]' '[:lower:]')" in
    y | yes | true | 1)
      echo "Skipping preflight because ONYXIO_SKIP_PREFLIGHT=true."
      return
      ;;
  esac

  if [ ! -x ./preflight.sh ]; then
    echo "preflight.sh is missing or not executable." >&2
    exit 1
  fi

  ./preflight.sh --mode "$1"
}

if ! command -v docker >/dev/null 2>&1; then
  echo "Docker is required on this server. Install Docker first, then run this installer again." >&2
  echo "On Ubuntu, install Docker Engine and the Docker Compose plugin, then retry ./install.sh." >&2
  exit 1
fi

VERSION="$(cat VERSION 2>/dev/null || echo local)"
SERVER_IMAGE="${ONYXIO_SERVER_IMAGE:-ghcr.io/onyxio-pty-ltd/server:${VERSION}}"
POSTGRES_IMAGE="${ONYXIO_POSTGRES_IMAGE:-postgres:15}"

prompt_server_ip() {
  if [ -n "${SERVER_IP:-}" ]; then
    echo "$SERVER_IP"
    return
  fi

  echo
  echo "Choose the IP address TVs and phones should use to reach this server."
  detected_ips="$(detect_ips)"
  if [ -n "$detected_ips" ]; then
    i=1
    while IFS= read -r ip; do
      [ -z "$ip" ] && continue
      if [ "$i" -eq 1 ]; then
        default_ip="$ip"
      fi
      printf "  [%s] %s\n" "$i" "$ip"
      i=$((i + 1))
    done <<EOF
$detected_ips
EOF
  else
    default_ip="127.0.0.1"
  fi

  read -r -p "Server IP [${default_ip}]: " selected_ip
  echo "${selected_ip:-$default_ip}"
}

pull_image() {
  local image="$1"
  echo
  echo "Pulling ${image}"
  echo "This can take several minutes on the first install."
  docker pull "$image"
}

ENV_CREATED=false
if [ ! -f .env ]; then
  ENV_CREATED=true
  SERVER_IP="$(prompt_server_ip)"

  POSTGRES_PASSWORD="$(random_secret)"
  JWT_SECRET="$(random_secret)"
  CASTING_HOST_TOKEN="$(random_secret)"

  cat > .env <<EOF
ONYXIO_VERSION=${VERSION}
ONYXIO_SERVER_IMAGE=${SERVER_IMAGE}
POSTGRES_IMAGE=${POSTGRES_IMAGE}

SERVER_IP=${SERVER_IP}
PUBLIC_SERVER_URL=http://${SERVER_IP}:4000
PUBLIC_APP_URL=http://${SERVER_IP}:4000
PUBLIC_TV_APP_URL=http://${SERVER_IP}:4000/tv/
MOBILE_APP_PUBLIC_URL=http://${SERVER_IP}:4000/mobile/
PHILIPS_WEBSERVICES_PUBLIC_URL=http://${SERVER_IP}/webservices.php
PHILIPS_WEBSERVICES_BOOTSTRAP_PUBLIC_URL=http://${SERVER_IP}

PORT=4000
WEB_SOCKET_PORT=8081
PHILIPS_WEBSERVICES_PORT=80
PHILIPS_WEBSERVICES_BOOTSTRAP_PORT=false
ONYXIO_NETWORK_APPLY_MODE=agent
ONYXIO_NETWORK_AGENT_URL=http://127.0.0.1:8097

CASTING_CONTROL_PLANE_WS_URL=ws://127.0.0.1:4000
CASTING_HOST_ID=onprem-main
CASTING_HOST_NAME=On-prem Main
CASTING_HOST_ORGANIZATION_IDS=org-1
CASTING_HOST_TOKEN=${CASTING_HOST_TOKEN}

# Casting pairings are normally cleared on checkout. This cleanup removes
# pairings whose mobile app has not reconnected within the expiry window.
# Set CASTING_PAIRING_STALE_EXPIRY_HOURS=0 to disable.
# CASTING_PAIRING_STALE_EXPIRY_HOURS=48
# CASTING_PAIRING_STALE_CLEANUP_INTERVAL_MINUTES=60

POSTGRES_USER=postgres
POSTGRES_PASSWORD=${POSTGRES_PASSWORD}
POSTGRES_DB=onyxio
POSTGRES_PORT=5432

JWT_SECRET=${JWT_SECRET}
GRAPHQL_BODY_LIMIT=150mb

ONYXIO_LICENSE_DIR=/app/backend/uploads/license
ONYXIO_LICENSE_PUBLIC_KEY_FILE=/app/backend/uploads/license/public-key.pem
ONYXIO_INSTALLATION_ID=${ONYXIO_INSTALLATION_ID:-}
EOF
else
  echo "Onyxio is already installed in this directory." >&2
  echo "Run ./uninstall.sh first, or install into a clean directory." >&2
  exit 1
fi

require_network_agent_dependencies
mkdir -p data/postgres data/uploads/license data/tls
install_network_agent
install_license_public_key
SERVER_IP="$(grep '^SERVER_IP=' .env | cut -d= -f2-)"
configure_https_env "$SERVER_IP" "$ENV_CREATED"

run_preflight online

pull_image "$SERVER_IMAGE"
pull_image "$POSTGRES_IMAGE"
if https_configured; then
  pull_image "$(env_value .env HTTPS_PROXY_IMAGE)"
fi

echo "Starting Onyxio."
start_compose
wait_for_onyxio_startup

SERVER_IP="$(grep '^SERVER_IP=' .env | cut -d= -f2-)"
echo
echo "Onyxio is running."
echo "Admin:  http://${SERVER_IP}:4000/"
echo "TV:     http://${SERVER_IP}:4000/tv/"
echo "Mobile: http://${SERVER_IP}:4000/mobile/"
echo "Philips WebServices: http://${SERVER_IP}/webservices.php"
print_https_summary
echo
echo "License activation:"
echo "  1. The Onyxio license public key is installed at ./data/uploads/license/public-key.pem."
if grep -q '^ONYXIO_INSTALLATION_ID=onyxio-' .env; then
  echo "  2. This server is seeded with $(grep '^ONYXIO_INSTALLATION_ID=' .env | cut -d= -f2-)."
else
  echo "  2. Open Admin > Settings > License and copy the generated installation ID."
fi
echo "  3. Upload the signed license in Admin > Settings > License."
echo "TV and mobile apps stay locked until the license is valid."
echo
echo "View logs with:"
echo "  docker compose -f docker-compose.yml logs -f ${PLATFORM_SERVICE_NAME}"
echo "Casting module logs:"
echo "  docker compose -f docker-compose.yml logs -f casting-host"
