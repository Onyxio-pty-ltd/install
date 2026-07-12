#!/usr/bin/env bash
set -euo pipefail

INSTALL_DIR="${ONYXIO_INSTALL_DIR:-/opt/onyxio}"
VERSION="${ONYXIO_VERSION:-latest}"
SERVER_IMAGE="${ONYXIO_SERVER_IMAGE:-ghcr.io/onyxio-pty-ltd/server:${VERSION}}"
POSTGRES_IMAGE="${ONYXIO_POSTGRES_IMAGE:-postgres:15}"
REGISTRY="${ONYXIO_REGISTRY:-ghcr.io}"
REGISTRY_USERNAME="${ONYXIO_REGISTRY_USERNAME:-}"
REGISTRY_TOKEN="${ONYXIO_REGISTRY_TOKEN:-}"

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

prompt_server_ip() {
  if [ -n "${SERVER_IP:-}" ]; then
    echo "$SERVER_IP"
    return
  fi

  echo "Choose the IP address TVs and phones should use to reach this server." >&2
  mapfile -t IPS < <(detect_ips)
  if [ "${#IPS[@]}" -gt 0 ]; then
    for i in "${!IPS[@]}"; do
      printf "  [%s] %s\n" "$((i + 1))" "${IPS[$i]}" >&2
    done
    default_ip="${IPS[0]}"
  else
    default_ip="127.0.0.1"
  fi

  read -r -p "Server IP [${default_ip}]: " selected_ip >&2
  echo "${selected_ip:-$default_ip}"
}

docker_login_if_needed() {
  if [ -z "$REGISTRY_TOKEN" ]; then
    echo "ONYXIO_REGISTRY_TOKEN is not set."
    read -r -s -p "Registry token for ${REGISTRY} (leave blank if image is public): " REGISTRY_TOKEN
    echo
  fi

  if [ -n "$REGISTRY_TOKEN" ]; then
    if [ -z "$REGISTRY_USERNAME" ]; then
      read -r -p "Registry username [onyxio-pty-ltd]: " REGISTRY_USERNAME
      REGISTRY_USERNAME="${REGISTRY_USERNAME:-onyxio-pty-ltd}"
    fi
    echo "$REGISTRY_TOKEN" | docker login "$REGISTRY" -u "$REGISTRY_USERNAME" --password-stdin
  fi
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
EOF
}

main() {
  require_root
  require_docker

  mkdir -p "$INSTALL_DIR/data/postgres" "$INSTALL_DIR/data/uploads"
  local server_ip
  server_ip="$(prompt_server_ip)"

  write_compose_file
  write_env_file "$server_ip"
  docker_login_if_needed

  cd "$INSTALL_DIR"
  echo "Pulling Onyxio images..."
  compose -f docker-compose.yml pull
  echo "Starting Onyxio..."
  compose -f docker-compose.yml up -d

  echo
  echo "Onyxio is starting."
  echo "Admin:  http://${server_ip}:4000/admin/"
  echo "TV:     http://${server_ip}:4000/tv/"
  echo "Mobile: http://${server_ip}:4000/mobile/"
  echo "Philips WebServices: http://${server_ip}/webservices.php"
  echo
  echo "Install directory: ${INSTALL_DIR}"
  echo "View logs with:"
  echo "  cd ${INSTALL_DIR} && docker compose logs -f onyxio"
}

main "$@"
