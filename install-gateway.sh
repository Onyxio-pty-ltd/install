#!/usr/bin/env bash
set -euo pipefail

INSTALL_DIR="${ONYXIO_INSTALL_DIR:-/opt/onyxio-gateway}"
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
Usage: install-gateway.sh [options]

Installs or updates an Onyxio casting gateway. The gateway runs the shared
Onyxio casting runtime only; it does not install Postgres or a full on-prem
backend.

Options:
  --version VERSION             Image tag to install. Defaults to latest.
  --image IMAGE                 Full server image reference. Overrides --version.
  --install-dir PATH            Install directory. Defaults to /opt/onyxio-gateway.
  --cloud-url URL               Cloud HTTP(S), WS, or WSS URL for the gateway.
  --site-id SITE_ID             Cloud site/property id.
  --token TOKEN                 Gateway shared token.
  --guest-interfaces IPS        Optional guest interface IP/CIDR list.
  --device-interfaces IPS       Optional TV/device interface IP/CIDR list.
  -h, --help                    Show this help.

Environment:
  ONYXIO_INSTALL_DIR=/opt/onyxio-gateway
  ONYXIO_VERSION=2026.08.15
  ONYXIO_SERVER_IMAGE=ghcr.io/onyxio-pty-ltd/server:2026.08.15
  ONYXIO_REGISTRY=ghcr.io
  ONYXIO_REGISTRY_USERNAME=YOUR_GITHUB_USERNAME
  ONYXIO_REGISTRY_TOKEN=TOKEN
  CASTING_GATEWAY_WS_URL=wss://cloud.example.com
  CASTING_CLOUD_URL=https://cloud.example.com
  CASTING_GATEWAY_SITE_ID=site-1
  CASTING_GATEWAY_TOKEN=shared-secret
  CASTING_GATEWAY_GUEST_INTERFACE_IPS=172.20.0.10/255.255.255.0
  CASTING_GATEWAY_DEVICE_INTERFACE_IPS=10.10.0.10/255.255.255.0
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
    --cloud-url)
      if [ "$#" -lt 2 ]; then
        echo "--cloud-url requires a value." >&2
        exit 1
      fi
      CASTING_GATEWAY_WS_URL="${2:-}"
      shift 2
      ;;
    --cloud-url=*)
      CASTING_GATEWAY_WS_URL="${1#*=}"
      shift
      ;;
    --site-id)
      if [ "$#" -lt 2 ]; then
        echo "--site-id requires a value." >&2
        exit 1
      fi
      CASTING_GATEWAY_SITE_ID="${2:-}"
      shift 2
      ;;
    --site-id=*)
      CASTING_GATEWAY_SITE_ID="${1#*=}"
      shift
      ;;
    --token)
      if [ "$#" -lt 2 ]; then
        echo "--token requires a value." >&2
        exit 1
      fi
      CASTING_GATEWAY_TOKEN="${2:-}"
      shift 2
      ;;
    --token=*)
      CASTING_GATEWAY_TOKEN="${1#*=}"
      shift
      ;;
    --guest-interfaces)
      if [ "$#" -lt 2 ]; then
        echo "--guest-interfaces requires a value." >&2
        exit 1
      fi
      CASTING_GATEWAY_GUEST_INTERFACE_IPS="${2:-}"
      shift 2
      ;;
    --guest-interfaces=*)
      CASTING_GATEWAY_GUEST_INTERFACE_IPS="${1#*=}"
      shift
      ;;
    --device-interfaces)
      if [ "$#" -lt 2 ]; then
        echo "--device-interfaces requires a value." >&2
        exit 1
      fi
      CASTING_GATEWAY_DEVICE_INTERFACE_IPS="${2:-}"
      shift 2
      ;;
    --device-interfaces=*)
      CASTING_GATEWAY_DEVICE_INTERFACE_IPS="${1#*=}"
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

prompt_optional() {
  local message="$1"
  local default_value="${2:-}"
  local value=""

  if [ -r /dev/tty ]; then
    read -r -p "${message} [${default_value}]: " value </dev/tty
    echo "${value:-$default_value}"
    return
  fi

  echo "$default_value"
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

detect_ips() {
  {
    hostname -I 2>/dev/null | tr ' ' '\n' || true
    if command -v ip >/dev/null 2>&1; then
      ip -o -4 addr show scope global 2>/dev/null | awk '{ split($4, parts, "/"); print parts[1] }'
    fi
  } | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' | grep -v '^127\.' | sort -u || true
}

first_detected_ip() {
  detect_ips | head -n 1
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
    echo "  curl -fsSL https://install.onyxio.com.au/install-gateway.sh | sudo bash" >&2
    exit 1
  fi
}

require_docker() {
  if ! command -v docker >/dev/null 2>&1; then
    echo "Docker is required on this server before installing the Onyxio casting gateway." >&2
    exit 1
  fi
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

validate_cloud_url() {
  local cloud_url="$1"

  case "$cloud_url" in
    ws://* | wss://* | http://* | https://*)
      return
      ;;
    *)
      echo "CASTING_GATEWAY_WS_URL must start with ws://, wss://, http://, or https://." >&2
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
  cat > "$INSTALL_DIR/docker-compose.gateway.yml" <<'EOF'
services:
  casting-gateway:
    image: ${ONYXIO_SERVER_IMAGE}
    restart: unless-stopped
    network_mode: host
    env_file:
      - .env
    environment:
      NODE_ENV: production
      CASTING_GATEWAY_SITE_ID: ${CASTING_GATEWAY_SITE_ID}
      CASTING_GATEWAY_TOKEN: ${CASTING_GATEWAY_TOKEN}
      CASTING_GATEWAY_WS_URL: ${CASTING_GATEWAY_WS_URL}
      CASTING_GATEWAY_BIND_ADDRESS: ${CASTING_GATEWAY_BIND_ADDRESS:-0.0.0.0}
      CASTING_GATEWAY_GUEST_INTERFACE_IPS: ${CASTING_GATEWAY_GUEST_INTERFACE_IPS:-}
      CASTING_GATEWAY_DEVICE_INTERFACE_IPS: ${CASTING_GATEWAY_DEVICE_INTERFACE_IPS:-}
    command: ["yarn", "casting:gateway:start"]
EOF
}

install_self_if_possible() {
  if [ -f "$SOURCE_DIR/install-gateway.sh" ]; then
    cp "$SOURCE_DIR/install-gateway.sh" "$INSTALL_DIR/install-gateway.sh"
  elif command -v curl >/dev/null 2>&1; then
    curl -fsSL "${ONYXIO_INSTALL_BASE_URL:-https://install.onyxio.com.au}/install-gateway.sh" \
      -o "$INSTALL_DIR/install-gateway.sh" || return
  else
    return
  fi

  chmod +x "$INSTALL_DIR/install-gateway.sh"
}

check_cloud_reachability() {
  local cloud_url="$1"
  local probe_url=""

  case "$cloud_url" in
    wss://*)
      probe_url="https://${cloud_url#wss://}"
      ;;
    ws://*)
      probe_url="http://${cloud_url#ws://}"
      ;;
    http://* | https://*)
      probe_url="$cloud_url"
      ;;
  esac

  if [ -z "$probe_url" ] || ! command -v curl >/dev/null 2>&1; then
    return
  fi

  if ! curl -sS --max-time 10 -o /dev/null "$probe_url"; then
    echo "Warning: cloud endpoint was not reachable during install: ${probe_url}" >&2
  fi
}

wait_for_gateway() {
  local container_id=""
  local deadline=$((SECONDS + 30))

  while [ "$SECONDS" -lt "$deadline" ]; do
    container_id="$(compose -f docker-compose.gateway.yml ps -q casting-gateway 2>/dev/null || true)"
    if [ -n "$container_id" ] && [ "$(docker inspect -f '{{.State.Running}}' "$container_id" 2>/dev/null || true)" = "true" ]; then
      echo "Onyxio casting gateway is running."
      return
    fi
    sleep 1
  done

  echo "Onyxio casting gateway did not become ready. Recent logs:" >&2
  compose -f docker-compose.gateway.yml logs --tail=160 casting-gateway >&2 || true
  exit 1
}

main() {
  require_root
  require_safe_install_dir
  require_docker
  resolve_server_image
  require_package_platform

  mkdir -p "$INSTALL_DIR"
  touch "$INSTALL_DIR/.env"

  local env_file cloud_url site_id gateway_token guest_ips device_ips default_ip
  env_file="$INSTALL_DIR/.env"
  default_ip="$(first_detected_ip)"
  cloud_url="${CASTING_GATEWAY_WS_URL:-${CASTING_CLOUD_URL:-$(env_value "$env_file" CASTING_GATEWAY_WS_URL)}}"
  site_id="${CASTING_GATEWAY_SITE_ID:-$(env_value "$env_file" CASTING_GATEWAY_SITE_ID)}"
  gateway_token="${CASTING_GATEWAY_TOKEN:-$(env_value "$env_file" CASTING_GATEWAY_TOKEN)}"
  guest_ips="${CASTING_GATEWAY_GUEST_INTERFACE_IPS:-$(env_value "$env_file" CASTING_GATEWAY_GUEST_INTERFACE_IPS)}"
  device_ips="${CASTING_GATEWAY_DEVICE_INTERFACE_IPS:-$(env_value "$env_file" CASTING_GATEWAY_DEVICE_INTERFACE_IPS)}"

  cloud_url="$(prompt "Cloud URL" "$cloud_url")"
  site_id="$(prompt "Gateway site id" "$site_id")"
  if [ -z "$gateway_token" ]; then
    gateway_token="$(prompt_secret "Gateway token")"
  fi
  guest_ips="$(prompt_optional "Guest interface IPs, comma-separated" "${guest_ips:-$default_ip}")"
  device_ips="$(prompt_optional "TV/device interface IPs, comma-separated" "${device_ips:-$default_ip}")"

  require_value "CASTING_GATEWAY_WS_URL" "$cloud_url"
  require_value "CASTING_GATEWAY_SITE_ID" "$site_id"
  require_value "CASTING_GATEWAY_TOKEN" "$gateway_token"
  validate_cloud_url "$cloud_url"

  set_env_value "$env_file" ONYXIO_VERSION "$VERSION"
  set_env_value "$env_file" ONYXIO_SERVER_IMAGE "$SERVER_IMAGE"
  set_env_value "$env_file" CASTING_GATEWAY_WS_URL "$cloud_url"
  set_env_value "$env_file" CASTING_GATEWAY_SITE_ID "$site_id"
  set_env_value "$env_file" CASTING_GATEWAY_TOKEN "$gateway_token"
  set_env_value "$env_file" CASTING_GATEWAY_GUEST_INTERFACE_IPS "$guest_ips"
  set_env_value "$env_file" CASTING_GATEWAY_DEVICE_INTERFACE_IPS "$device_ips"

  write_compose_file
  install_self_if_possible
  load_local_images_if_available
  pull_image_if_needed
  check_cloud_reachability "$cloud_url"

  cd "$INSTALL_DIR"
  compose -f docker-compose.gateway.yml up -d
  wait_for_gateway

  echo
  echo "Onyxio casting gateway install/update complete."
  echo "  Install directory: ${INSTALL_DIR}"
  echo "  Gateway logs: sudo docker compose -f ${INSTALL_DIR}/docker-compose.gateway.yml logs -f casting-gateway"
}

main "$@"
