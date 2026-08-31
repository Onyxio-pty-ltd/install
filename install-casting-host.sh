#!/usr/bin/env bash
set -euo pipefail

INSTALL_DIR="${ONYXIO_INSTALL_DIR:-/opt/onyxio-casting-host}"
VERSION="${ONYXIO_VERSION:-latest}"
SERVER_IMAGE="${ONYXIO_SERVER_IMAGE:-}"
REGISTRY="${ONYXIO_REGISTRY:-ghcr.io}"
REGISTRY_USERNAME="${ONYXIO_REGISTRY_USERNAME:-}"
REGISTRY_TOKEN="${ONYXIO_REGISTRY_TOKEN:-}"
SOURCE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd || pwd)"
VERSION_EXPLICIT="false"
SERVER_IMAGE_EXPLICIT="false"

if [ -n "${ONYXIO_VERSION:-}" ]; then
  VERSION_EXPLICIT="true"
fi
if [ -n "${ONYXIO_SERVER_IMAGE:-}" ]; then
  SERVER_IMAGE_EXPLICIT="true"
fi

usage() {
  cat <<'EOF'
Usage: install-casting-host.sh [options]

Installs or updates an Onyxio casting host. The host runs the shared
Onyxio casting runtime only; it does not install Postgres or a full on-prem
backend. It also installs the local Onyxio network agent so Admin network
changes can be applied on this property-network host.

Options:
  --version VERSION             Image tag to install. Defaults to latest.
  --image IMAGE                 Full server image reference. Overrides --version.
  --install-dir PATH            Install directory. Defaults to /opt/onyxio-casting-host.
  --control-plane-url URL       Backend/control-plane HTTP(S), WS, or WSS URL.
  --host-id HOST_ID             Stable casting host id shown in cloud settings.
  --host-name NAME              Display name shown in cloud settings.
  --organization-ids ORG_IDS    Comma-separated cloud organization ids.
  --token TOKEN                 Casting host shared token.
  -h, --help                    Show this help.

Environment:
  ONYXIO_INSTALL_DIR=/opt/onyxio-casting-host
  ONYXIO_VERSION=2026.08.15
  ONYXIO_SERVER_IMAGE=ghcr.io/onyxio-pty-ltd/server:2026.08.15
  ONYXIO_REGISTRY=ghcr.io
  ONYXIO_REGISTRY_USERNAME=YOUR_GITHUB_USERNAME
  ONYXIO_REGISTRY_TOKEN=TOKEN
  CASTING_CONTROL_PLANE_WS_URL=wss://cloud.example.com
  CASTING_HOST_ID=property-a
  CASTING_HOST_NAME="Property A"
  CASTING_HOST_ORGANIZATION_IDS=org-1
  CASTING_HOST_TOKEN=shared-secret
  ONYXIO_NETWORK_AGENT_URL=http://127.0.0.1:8097
EOF
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --version)
      if [ "$#" -lt 2 ]; then
        echo "--version requires a value." >&2
        exit 1
      fi
      VERSION="$2"
      VERSION_EXPLICIT="true"
      shift 2
      ;;
    --version=*)
      VERSION="${1#*=}"
      VERSION_EXPLICIT="true"
      shift
      ;;
    --image)
      if [ "$#" -lt 2 ]; then
        echo "--image requires a value." >&2
        exit 1
      fi
      SERVER_IMAGE="$2"
      SERVER_IMAGE_EXPLICIT="true"
      shift 2
      ;;
    --image=*)
      SERVER_IMAGE="${1#*=}"
      SERVER_IMAGE_EXPLICIT="true"
      shift
      ;;
    --install-dir)
      if [ "$#" -lt 2 ]; then
        echo "--install-dir requires a path." >&2
        exit 1
      fi
      INSTALL_DIR="$2"
      shift 2
      ;;
    --install-dir=*)
      INSTALL_DIR="${1#*=}"
      shift
      ;;
    --control-plane-url)
      if [ "$#" -lt 2 ]; then
        echo "--control-plane-url requires a value." >&2
        exit 1
      fi
      CASTING_CONTROL_PLANE_WS_URL="${2:-}"
      shift 2
      ;;
    --control-plane-url=*)
      CASTING_CONTROL_PLANE_WS_URL="${1#*=}"
      shift
      ;;
    --host-id)
      if [ "$#" -lt 2 ]; then
        echo "--host-id requires a value." >&2
        exit 1
      fi
      CASTING_HOST_ID="${2:-}"
      shift 2
      ;;
    --host-id=*)
      CASTING_HOST_ID="${1#*=}"
      shift
      ;;
    --host-name)
      if [ "$#" -lt 2 ]; then
        echo "--host-name requires a value." >&2
        exit 1
      fi
      CASTING_HOST_NAME="${2:-}"
      shift 2
      ;;
    --host-name=*)
      CASTING_HOST_NAME="${1#*=}"
      shift
      ;;
    --organization-ids)
      if [ "$#" -lt 2 ]; then
        echo "--organization-ids requires a value." >&2
        exit 1
      fi
      CASTING_HOST_ORGANIZATION_IDS="${2:-}"
      shift 2
      ;;
    --organization-ids=*)
      CASTING_HOST_ORGANIZATION_IDS="${1#*=}"
      shift
      ;;
    --token)
      if [ "$#" -lt 2 ]; then
        echo "--token requires a value." >&2
        exit 1
      fi
      CASTING_HOST_TOKEN="${2:-}"
      shift 2
      ;;
    --token=*)
      CASTING_HOST_TOKEN="${1#*=}"
      shift
      ;;
    -h | --help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown option: $1" >&2
      usage >&2
      exit 1
      ;;
  esac
done

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

  if [ -n "$default_value" ]; then
    echo "$default_value"
    return
  fi

  echo "Cannot prompt for ${message}; provide it as an environment variable." >&2
  return 1
}

prompt_secret() {
  local message="$1"
  local value=""

  if [ -r /dev/tty ]; then
    read -r -s -p "${message}: " value </dev/tty
    echo >&2
    echo "$value"
    return
  fi

  echo "Cannot prompt for ${message}; provide it as an environment variable." >&2
  return 1
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

host_platform() {
  case "$(uname -m)" in
    x86_64 | amd64)
      echo "linux/amd64"
      ;;
    aarch64 | arm64)
      echo "linux/arm64"
      ;;
    *)
      echo "unknown/$(uname -m)"
      ;;
  esac
}

local_images_available() {
  find "$SOURCE_DIR/images" -name '*.tar' -type f -print -quit 2>/dev/null | grep -q .
}

resolve_server_image() {
  if [ "$SERVER_IMAGE_EXPLICIT" = "true" ]; then
    return
  fi

  if [ "$VERSION_EXPLICIT" != "true" ] && [ -f "$SOURCE_DIR/VERSION" ]; then
    VERSION="$(tr -d '[:space:]' < "$SOURCE_DIR/VERSION")"
  fi

  if local_images_available; then
    SERVER_IMAGE="onyxio/server:${VERSION}"
    return
  fi

  SERVER_IMAGE="ghcr.io/onyxio-pty-ltd/server:${VERSION}"
}

require_root() {
  if [ "$(id -u)" -ne 0 ]; then
    echo "Run this installer with sudo:" >&2
    echo "  curl -fsSL https://install.onyxio.com.au/install-casting-host.sh | sudo bash" >&2
    exit 1
  fi
}

require_docker() {
  if ! command -v docker >/dev/null 2>&1; then
    echo "Docker is required on this server before installing the Onyxio casting host." >&2
    exit 1
  fi
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
  agent_source="$SOURCE_DIR/network-agent.py"
  service_file="/etc/systemd/system/onyxio-network-agent.service"

  if ! command -v systemctl >/dev/null 2>&1; then
    echo "systemd is required for the Onyxio host network agent." >&2
    exit 1
  fi

  mkdir -p "$INSTALL_DIR/network-agent"
  if [ -f "$agent_source" ]; then
    cp "$agent_source" "$INSTALL_DIR/network-agent/agent.py"
  else
    curl -fsSL "${ONYXIO_INSTALL_BASE_URL:-https://install.onyxio.com.au}/network-agent.py" \
      -o "$INSTALL_DIR/network-agent/agent.py"
  fi
  chmod 0755 "$INSTALL_DIR/network-agent/agent.py"

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
ExecStart=/usr/bin/env python3 ${INSTALL_DIR}/network-agent/agent.py
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

require_safe_install_dir() {
  if [ -z "$INSTALL_DIR" ] || [ "$INSTALL_DIR" = "/" ]; then
    echo "Refusing unsafe install directory: ${INSTALL_DIR:-<empty>}" >&2
    exit 1
  fi
}

require_value() {
  local name="$1"
  local value="$2"

  if [ -z "$value" ]; then
    echo "${name} is required." >&2
    exit 1
  fi
}

validate_control_plane_url() {
  local control_plane_url="$1"

  case "$control_plane_url" in
    ws://* | wss://* | http://* | https://*)
      return
      ;;
    *)
      echo "CASTING_CONTROL_PLANE_WS_URL must start with ws://, wss://, http://, or https://." >&2
      exit 1
      ;;
  esac
}

docker_login_if_needed() {
  if [ -z "$REGISTRY_TOKEN" ]; then
    echo "ONYXIO_REGISTRY_TOKEN is not set."
    if [ ! -r /dev/tty ]; then
      echo "Skipping registry login; continuing as a public-image pull." >&2
      return
    fi
    REGISTRY_TOKEN="$(prompt_secret "Registry token for ${REGISTRY} (leave blank if image is public)")"
  fi

  if [ -n "$REGISTRY_TOKEN" ]; then
    if [ -z "$REGISTRY_USERNAME" ]; then
      REGISTRY_USERNAME="$(prompt "Registry username" "onyxio-pty-ltd")"
    fi
    echo "Logging in to ${REGISTRY} as ${REGISTRY_USERNAME}..."
    printf '%s\n' "$REGISTRY_TOKEN" | docker login "$REGISTRY" -u "$REGISTRY_USERNAME" --password-stdin
  fi
}

load_local_images_if_available() {
  if ! local_images_available; then
    return
  fi

  echo "Loading local Docker image tarballs..."
  find "$SOURCE_DIR/images" -name '*.tar' -type f -print | sort | while IFS= read -r image_tar; do
    docker load -i "$image_tar"
  done
}

require_package_platform() {
  if ! local_images_available || [ ! -f "$SOURCE_DIR/PLATFORM" ]; then
    return
  fi

  local package_platform current_platform
  package_platform="$(tr -d '[:space:]' < "$SOURCE_DIR/PLATFORM")"
  current_platform="$(host_platform)"

  if [ "$package_platform" = "$current_platform" ]; then
    return
  fi

  echo "This package contains ${package_platform} Docker images, but this server is ${current_platform}." >&2
  echo "Use a package built for ${current_platform}, or rebuild with:" >&2
  echo "  ONYXIO_PACKAGE_PLATFORM=${current_platform} backend/deploy/build-package.sh" >&2
  exit 1
}

pull_image_if_needed() {
  if local_images_available; then
    return
  fi

  docker_login_if_needed
  echo "Pulling ${SERVER_IMAGE}..."
  docker pull "$SERVER_IMAGE"
}

write_compose_file() {
  cat > "$INSTALL_DIR/docker-compose.casting-host.yml" <<'EOF'
services:
  casting-host:
    image: ${ONYXIO_SERVER_IMAGE}
    restart: unless-stopped
    network_mode: host
    env_file:
      - .env
    environment:
      NODE_ENV: production
      CASTING_HOST_ID: ${CASTING_HOST_ID}
      CASTING_HOST_NAME: ${CASTING_HOST_NAME}
      CASTING_HOST_ORGANIZATION_IDS: ${CASTING_HOST_ORGANIZATION_IDS}
      CASTING_HOST_TOKEN: ${CASTING_HOST_TOKEN}
      CASTING_CONTROL_PLANE_WS_URL: ${CASTING_CONTROL_PLANE_WS_URL}
      CASTING_HOST_UDP_BIND_ADDRESS: ${CASTING_HOST_UDP_BIND_ADDRESS:-0.0.0.0}
      ONYXIO_NETWORK_APPLY_MODE: ${ONYXIO_NETWORK_APPLY_MODE:-agent}
      ONYXIO_NETWORK_AGENT_URL: ${ONYXIO_NETWORK_AGENT_URL:-http://127.0.0.1:8097}
    command: ["yarn", "casting:host:start"]
EOF
}

install_self_if_possible() {
  if [ -f "$SOURCE_DIR/install-casting-host.sh" ]; then
    cp "$SOURCE_DIR/install-casting-host.sh" "$INSTALL_DIR/install-casting-host.sh"
  elif command -v curl >/dev/null 2>&1; then
    curl -fsSL "${ONYXIO_INSTALL_BASE_URL:-https://install.onyxio.com.au}/install-casting-host.sh" \
      -o "$INSTALL_DIR/install-casting-host.sh" || return
  else
    return
  fi

  chmod +x "$INSTALL_DIR/install-casting-host.sh"
}

check_control_plane_reachability() {
  local control_plane_url="$1"
  local probe_url=""

  case "$control_plane_url" in
    wss://*)
      probe_url="https://${control_plane_url#wss://}"
      ;;
    ws://*)
      probe_url="http://${control_plane_url#ws://}"
      ;;
    http://* | https://*)
      probe_url="$control_plane_url"
      ;;
  esac

  if [ -z "$probe_url" ] || ! command -v curl >/dev/null 2>&1; then
    return
  fi

  if ! curl -sS --max-time 10 -o /dev/null "$probe_url"; then
    echo "Warning: control plane endpoint was not reachable during install: ${probe_url}" >&2
  fi
}

wait_for_casting_host() {
  local container_id=""
  local deadline=$((SECONDS + 30))

  while [ "$SECONDS" -lt "$deadline" ]; do
    container_id="$(compose -f docker-compose.casting-host.yml ps -q casting-host 2>/dev/null || true)"
    if [ -n "$container_id" ] && [ "$(docker inspect -f '{{.State.Running}}' "$container_id" 2>/dev/null || true)" = "true" ]; then
      echo "Onyxio casting host is running."
      return
    fi
    sleep 1
  done

  echo "Onyxio casting host did not become ready. Recent logs:" >&2
  compose -f docker-compose.casting-host.yml logs --tail=160 casting-host >&2 || true
  exit 1
}

main() {
  require_root
  require_safe_install_dir
  require_docker
  require_network_agent_dependencies
  resolve_server_image
  require_package_platform

  mkdir -p "$INSTALL_DIR"
  touch "$INSTALL_DIR/.env"
  install_network_agent

  local env_file control_plane_url host_id host_name organization_ids host_token
  env_file="$INSTALL_DIR/.env"
  control_plane_url="${CASTING_CONTROL_PLANE_WS_URL:-$(env_value "$env_file" CASTING_CONTROL_PLANE_WS_URL)}"
  host_id="${CASTING_HOST_ID:-$(env_value "$env_file" CASTING_HOST_ID)}"
  host_name="${CASTING_HOST_NAME:-$(env_value "$env_file" CASTING_HOST_NAME)}"
  organization_ids="${CASTING_HOST_ORGANIZATION_IDS:-$(env_value "$env_file" CASTING_HOST_ORGANIZATION_IDS)}"
  host_token="${CASTING_HOST_TOKEN:-$(env_value "$env_file" CASTING_HOST_TOKEN)}"

  control_plane_url="$(prompt "Control plane URL" "$control_plane_url")"
  host_id="$(prompt "Casting host id" "$host_id")"
  host_name="$(prompt "Casting host name" "${host_name:-$host_id}")"
  organization_ids="$(prompt "Casting host organization ids" "$organization_ids")"
  if [ -z "$host_token" ]; then
    host_token="$(prompt_secret "Casting host token")"
  fi

  require_value "CASTING_CONTROL_PLANE_WS_URL" "$control_plane_url"
  require_value "CASTING_HOST_ID" "$host_id"
  require_value "CASTING_HOST_ORGANIZATION_IDS" "$organization_ids"
  require_value "CASTING_HOST_TOKEN" "$host_token"
  validate_control_plane_url "$control_plane_url"

  set_env_value "$env_file" ONYXIO_VERSION "$VERSION"
  set_env_value "$env_file" ONYXIO_SERVER_IMAGE "$SERVER_IMAGE"
  set_env_value "$env_file" CASTING_CONTROL_PLANE_WS_URL "$control_plane_url"
  set_env_value "$env_file" CASTING_HOST_ID "$host_id"
  set_env_value "$env_file" CASTING_HOST_NAME "$host_name"
  set_env_value "$env_file" CASTING_HOST_ORGANIZATION_IDS "$organization_ids"
  set_env_value "$env_file" CASTING_HOST_TOKEN "$host_token"
  set_env_value "$env_file" ONYXIO_NETWORK_APPLY_MODE agent
  set_env_value "$env_file" ONYXIO_NETWORK_AGENT_URL http://127.0.0.1:8097

  write_compose_file
  install_self_if_possible
  load_local_images_if_available
  pull_image_if_needed
  check_control_plane_reachability "$control_plane_url"

  cd "$INSTALL_DIR"
  compose -f docker-compose.casting-host.yml up -d
  wait_for_casting_host

  echo
  echo "Onyxio casting host install/update complete."
  echo "  Install directory: ${INSTALL_DIR}"
  echo "  Casting host logs: sudo docker compose -f ${INSTALL_DIR}/docker-compose.casting-host.yml logs -f casting-host"
  echo "  Network agent: sudo systemctl status onyxio-network-agent.service"
  echo "  The host will report detected interfaces to the control plane. Select guest/device roles in the casting module settings."
  echo "  Set the casting module public URL in Admin so TV QR codes can point at this host."
}

main "$@"
