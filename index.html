#!/usr/bin/env bash
set -euo pipefail

INSTALL_DIR="${ONYXIO_INSTALL_DIR:-/opt/onyxio}"
VERSION="${ONYXIO_VERSION:-latest}"
SERVER_IMAGE="${ONYXIO_SERVER_IMAGE:-ghcr.io/onyxio-pty-ltd/server:${VERSION}}"
POSTGRES_IMAGE="${ONYXIO_POSTGRES_IMAGE:-postgres:15}"
REGISTRY="${ONYXIO_REGISTRY:-ghcr.io}"
REGISTRY_USERNAME="${ONYXIO_REGISTRY_USERNAME:-}"
REGISTRY_TOKEN="${ONYXIO_REGISTRY_TOKEN:-}"

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

require_root() {
  if [ "$(id -u)" -ne 0 ]; then
    echo "Run this installer with sudo:" >&2
    echo "  curl -fsSL https://install.onyxio.com.au | sudo bash" >&2
    exit 1
  fi
}

require_docker() {
  if ! command -v docker >/dev/null 2>&1; then
    echo "Docker is required on this server before installing Onyxio." >&2
    echo "Install Docker Engine and the Docker Compose plugin, then run this installer again." >&2
    exit 1
  fi
}

log_step() {
  echo
  echo "[Onyxio installer] $1"
}

pull_image() {
  local image="$1"
  log_step "Pulling ${image}"
  echo "This can take several minutes on the first install. Docker will show layer progress when the registry starts sending data."
  docker pull "$image"
}

prompt_server_ip() {
  if [ -n "${SERVER_IP:-}" ]; then
    echo "$SERVER_IP"
    return
  fi

  echo "Choose the IP address TVs and phones should use to reach this server." >&2
  detected_ips="$(detect_ips)"
  if [ -n "$detected_ips" ]; then
    i=1
    while IFS= read -r ip; do
      [ -z "$ip" ] && continue
      if [ "$i" -eq 1 ]; then
        default_ip="$ip"
      fi
      printf "  [%s] %s\n" "$i" "$ip" >&2
      i=$((i + 1))
    done <<EOF
$detected_ips
EOF
  else
    default_ip="127.0.0.1"
  fi

  prompt "Server IP" "$default_ip"
}

docker_login_if_needed() {
  if [ -z "$REGISTRY_TOKEN" ]; then
    log_step "Skipping registry login"
    echo "ONYXIO_REGISTRY_TOKEN is not set. Docker will use any existing login, or pull anonymously if the image is public."
    return
  fi

  if [ -z "$REGISTRY_USERNAME" ]; then
    REGISTRY_USERNAME="imannorouzi"
  fi

  log_step "Logging in to ${REGISTRY} as ${REGISTRY_USERNAME}"
  echo "$REGISTRY_TOKEN" | docker login "$REGISTRY" -u "$REGISTRY_USERNAME" --password-stdin
}

write_compose_file() {
  cat > "$INSTALL_DIR/docker-compose.yml" <<'EOF'
services:
  postgres:
    image: ${POSTGRES_IMAGE:-postgres:15}
    restart: unless-stopped
    environment:
      POSTGRES_USER: ${POSTGRES_USER:-postgres}
      POSTGRES_PASSWORD: ${POSTGRES_PASSWORD}
      POSTGRES_DB: ${POSTGRES_DB:-onyxio}
    ports:
      - "127.0.0.1:${POSTGRES_PORT:-5432}:5432"
    volumes:
      - ./data/postgres:/var/lib/postgresql/data
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U ${POSTGRES_USER:-postgres} -d ${POSTGRES_DB:-onyxio}"]
      interval: 10s
      timeout: 5s
      retries: 12

  onyxio:
    image: ${ONYXIO_SERVER_IMAGE}
    restart: unless-stopped
    network_mode: host
    depends_on:
      postgres:
        condition: service_healthy
    env_file:
      - .env
    environment:
      DATABASE_URL: postgresql://${POSTGRES_USER:-postgres}:${POSTGRES_PASSWORD}@127.0.0.1:${POSTGRES_PORT:-5432}/${POSTGRES_DB:-onyxio}
      PORT: ${PORT:-4000}
      WEB_SOCKET_PORT: ${WEB_SOCKET_PORT:-8081}
      PHILIPS_WEBSERVICES_PORT: ${PHILIPS_WEBSERVICES_PORT:-8080}
      PHILIPS_WEBSERVICES_BOOTSTRAP_PORT: ${PHILIPS_WEBSERVICES_BOOTSTRAP_PORT:-80}
    volumes:
      - ./data/uploads:/app/backend/uploads
EOF
}

write_env_file() {
  local server_ip="$1"
  if [ -f "$INSTALL_DIR/.env" ]; then
    echo "Existing ${INSTALL_DIR}/.env found; keeping existing configuration."
    return
  fi

  local postgres_password jwt_secret
  postgres_password="$(random_secret)"
  jwt_secret="$(random_secret)"

  cat > "$INSTALL_DIR/.env" <<EOF
ONYXIO_VERSION=${VERSION}
ONYXIO_SERVER_IMAGE=${SERVER_IMAGE}
POSTGRES_IMAGE=${POSTGRES_IMAGE}

SERVER_IP=${server_ip}
PUBLIC_SERVER_URL=http://${server_ip}:4000
PUBLIC_APP_URL=http://${server_ip}:4000
PUBLIC_TV_APP_URL=http://${server_ip}:4000/tv/
MOBILE_APP_PUBLIC_URL=http://${server_ip}:4000/mobile/
PHILIPS_WEBSERVICES_PUBLIC_URL=http://${server_ip}/webservices.php
PHILIPS_WEBSERVICES_BOOTSTRAP_PUBLIC_URL=http://${server_ip}

PORT=4000
WEB_SOCKET_PORT=8081
PHILIPS_WEBSERVICES_PORT=8080
PHILIPS_WEBSERVICES_BOOTSTRAP_PORT=80

POSTGRES_USER=postgres
POSTGRES_PASSWORD=${postgres_password}
POSTGRES_DB=onyxio
POSTGRES_PORT=5432

JWT_SECRET=${jwt_secret}
GRAPHQL_BODY_LIMIT=150mb

ONYXIO_LICENSE_DIR=/app/backend/uploads/license
ONYXIO_LICENSE_PUBLIC_KEY_FILE=/app/backend/uploads/license/public-key.pem
ONYXIO_INSTALLATION_ID=${ONYXIO_INSTALLATION_ID:-}
EOF
}

main() {
  log_step "Starting Onyxio installer"
  require_root
  require_docker

  log_step "Preparing install directory: ${INSTALL_DIR}"
  mkdir -p "$INSTALL_DIR/data/postgres" "$INSTALL_DIR/data/uploads/license"
  local server_ip
  server_ip="$(prompt_server_ip)"

  log_step "Writing Docker Compose configuration"
  write_compose_file
  write_env_file "$server_ip"
  docker_login_if_needed

  cd "$INSTALL_DIR"
  pull_image "$SERVER_IMAGE"
  pull_image "$POSTGRES_IMAGE"

  log_step "Starting containers"
  compose -f docker-compose.yml up -d

  echo
  echo "Onyxio is starting."
  echo "Admin:  http://${server_ip}:4000/admin/"
  echo "TV:     http://${server_ip}:4000/tv/"
  echo "Mobile: http://${server_ip}:4000/mobile/"
  echo "Philips WebServices: http://${server_ip}/webservices.php"
  echo
  echo "License activation:"
  echo "  1. Put the Onyxio license public key at ${INSTALL_DIR}/data/uploads/license/public-key.pem."
  if grep -q '^ONYXIO_INSTALLATION_ID=onyxio-' "$INSTALL_DIR/.env"; then
    echo "  2. This server is seeded with $(grep '^ONYXIO_INSTALLATION_ID=' "$INSTALL_DIR/.env" | cut -d= -f2-)."
  else
    echo "  2. Open Admin > Settings > License and copy the generated installation ID."
  fi
  echo "  3. Upload the signed license in Admin > Settings > License."
  echo "TV and mobile apps stay locked until the license is valid."
  echo
  echo "Install directory: ${INSTALL_DIR}"
  echo "View logs with:"
  echo "  cd ${INSTALL_DIR} && docker compose logs -f onyxio"
}

main "$@"
