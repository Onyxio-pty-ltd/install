#!/usr/bin/env bash
set -euo pipefail

INSTALL_DIR="${ONYXIO_INSTALL_DIR:-/opt/onyxio}"
VERSION="${ONYXIO_VERSION:-latest}"
SERVER_IMAGE="${ONYXIO_SERVER_IMAGE:-ghcr.io/onyxio-pty-ltd/server:${VERSION}}"
POSTGRES_IMAGE="${ONYXIO_POSTGRES_IMAGE:-postgres:15}"
HTTPS_PROXY_IMAGE="${ONYXIO_HTTPS_PROXY_IMAGE:-nginx:1.27-alpine}"
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
  local target="$INSTALL_DIR/data/uploads/license/public-key.pem"

  if [ -s "$target" ]; then
    echo "Existing Onyxio license public key found; keeping it."
    return
  fi

  mkdir -p "$(dirname "$target")"
  cat > "$target" <<'EOF'
-----BEGIN PUBLIC KEY-----
MCowBQYDK2VwAyEArEdXtD7u5kZwxS4Rr5rBbr5pEr6qXT3PnO0cfGO7Ztw=
-----END PUBLIC KEY-----
EOF
  chmod 0644 "$target"
  echo "Installed Onyxio license public key."
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
    echo "ONYXIO_REGISTRY_TOKEN is not set."
    REGISTRY_TOKEN="$(prompt_secret "Registry token for ${REGISTRY} (leave blank if image is public)")"
  fi

  if [ -n "$REGISTRY_TOKEN" ]; then
    if [ -z "$REGISTRY_USERNAME" ]; then
      REGISTRY_USERNAME="$(prompt "Registry username" "onyxio-pty-ltd")"
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

write_https_files() {
  mkdir -p "$INSTALL_DIR/nginx"

  cat > "$INSTALL_DIR/docker-compose.https.yml" <<'EOF'
services:
  https-proxy:
    image: ${HTTPS_PROXY_IMAGE:-nginx:1.27-alpine}
    restart: unless-stopped
    network_mode: host
    depends_on:
      - onyxio
    environment:
      HTTPS_HOST: ${HTTPS_HOST:-_}
      HTTPS_LISTEN_ADDR: ${HTTPS_LISTEN_ADDR:-0.0.0.0}
      HTTPS_PORT: ${HTTPS_PORT:-443}
      PORT: ${PORT:-4000}
      TLS_CERT_FILE: ${TLS_CERT_FILE:-/etc/onyxio/tls/fullchain.pem}
      TLS_KEY_FILE: ${TLS_KEY_FILE:-/etc/onyxio/tls/privkey.pem}
      NGINX_ENVSUBST_FILTER: "^(HTTPS_HOST|HTTPS_LISTEN_ADDR|HTTPS_PORT|PORT|TLS_CERT_FILE|TLS_KEY_FILE)$"
    volumes:
      - ./nginx/onyxio-https.conf.template:/etc/nginx/templates/default.conf.template:ro
      - ./data/tls:/etc/onyxio/tls:ro
EOF

  cat > "$INSTALL_DIR/nginx/onyxio-https.conf.template" <<'EOF'
map $http_upgrade $connection_upgrade {
  default upgrade;
  '' close;
}

server {
  listen ${HTTPS_LISTEN_ADDR}:${HTTPS_PORT} ssl;
  server_name ${HTTPS_HOST};

  ssl_certificate ${TLS_CERT_FILE};
  ssl_certificate_key ${TLS_KEY_FILE};
  ssl_protocols TLSv1.2 TLSv1.3;
  ssl_prefer_server_ciphers off;

  client_max_body_size 150m;

  location / {
    proxy_http_version 1.1;
    proxy_set_header Upgrade $http_upgrade;
    proxy_set_header Connection $connection_upgrade;
    proxy_set_header Host $host;
    proxy_set_header X-Real-IP $remote_addr;
    proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto https;
    proxy_read_timeout 1h;
    proxy_send_timeout 1h;
    proxy_pass http://127.0.0.1:${PORT};
  }
}
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

configure_https_env() {
  local server_ip="$1"
  local allow_prompt="${2:-false}"
  local env_file="$INSTALL_DIR/.env"
  local enable_https="${ONYXIO_ENABLE_HTTPS:-}"

  if [ -z "$enable_https" ] && grep -q '^ONYXIO_ENABLE_HTTPS=true' "$env_file" 2>/dev/null; then
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
  https_host="${HTTPS_HOST:-$(env_value "$env_file" HTTPS_HOST)}"
  if [ -z "$https_host" ]; then
    https_host="$(prompt "HTTPS hostname for guest phones" "")"
  fi
  if [ -z "$https_host" ]; then
    echo "HTTPS was requested but no HTTPS_HOST was provided; skipping HTTPS proxy setup." >&2
    return
  fi

  listen_addr="${HTTPS_LISTEN_ADDR:-$(env_value "$env_file" HTTPS_LISTEN_ADDR)}"
  listen_addr="${listen_addr:-$server_ip}"
  https_port="${HTTPS_PORT:-$(env_value "$env_file" HTTPS_PORT)}"
  https_port="${https_port:-443}"
  proxy_image="${HTTPS_PROXY_IMAGE:-$(env_value "$env_file" HTTPS_PROXY_IMAGE)}"
  proxy_image="${proxy_image:-$HTTPS_PROXY_IMAGE}"

  set_env_value "$env_file" ONYXIO_ENABLE_HTTPS true
  set_env_value "$env_file" HTTPS_HOST "$https_host"
  set_env_value "$env_file" HTTPS_LISTEN_ADDR "$listen_addr"
  set_env_value "$env_file" HTTPS_PORT "$https_port"
  set_env_value "$env_file" HTTPS_PROXY_IMAGE "$proxy_image"
  set_env_value "$env_file" MOBILE_APP_PUBLIC_URL "https://${https_host}/mobile/"
}

tls_certificates_available() {
  [ -s "$INSTALL_DIR/data/tls/fullchain.pem" ] && [ -s "$INSTALL_DIR/data/tls/privkey.pem" ]
}

https_configured() {
  grep -q '^ONYXIO_ENABLE_HTTPS=true' "$INSTALL_DIR/.env" 2>/dev/null &&
    [ -n "$(env_value "$INSTALL_DIR/.env" HTTPS_HOST)" ] &&
    [ -f "$INSTALL_DIR/docker-compose.https.yml" ]
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
  compose -f docker-compose.yml logs --tail=160 onyxio || true
}

wait_for_onyxio_startup() {
  local timeout_seconds="${ONYXIO_INSTALL_STARTUP_TIMEOUT_SECONDS:-120}"
  local port
  port="$(env_value "$INSTALL_DIR/.env" PORT)"
  port="${port:-4000}"

  echo "Waiting for Onyxio backend startup checks to pass."
  local start_time
  start_time="$(date +%s)"
  local initial_restart_count=""

  while [ $(( $(date +%s) - start_time )) -lt "$timeout_seconds" ]; do
    local container_id
    container_id="$(compose -f docker-compose.yml ps -q onyxio 2>/dev/null || true)"

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

  local env_file="$INSTALL_DIR/.env"
  local https_host listen_addr https_port
  https_host="$(env_value "$env_file" HTTPS_HOST)"
  listen_addr="$(env_value "$env_file" HTTPS_LISTEN_ADDR)"
  https_port="$(env_value "$env_file" HTTPS_PORT)"
  https_port="${https_port:-443}"

  echo
  echo "HTTPS front door:"
  echo "  DNS/split DNS: ${https_host} -> ${listen_addr}"
  echo "  Firewall: allow guest clients to ${listen_addr} TCP ${https_port}"
  echo "  Admin setting: Settings > Network > Mobile HTTPS URL = https://${https_host}/mobile/"

  if tls_certificates_available; then
    echo "  Proxy: running via docker-compose.https.yml"
    echo "  Mobile HTTPS: https://${https_host}/mobile/"
  else
    echo "  Proxy: not started because TLS files are missing."
    echo "  Put certificates at:"
    echo "    ${INSTALL_DIR}/data/tls/fullchain.pem"
    echo "    ${INSTALL_DIR}/data/tls/privkey.pem"
    echo "  Then start nginx with:"
    echo "    cd ${INSTALL_DIR} && docker compose -f docker-compose.yml -f docker-compose.https.yml up -d"
  fi
}

main() {
  require_root
  require_docker

  mkdir -p "$INSTALL_DIR/data/postgres" "$INSTALL_DIR/data/uploads/license" "$INSTALL_DIR/data/tls"
  install_license_public_key
  local server_ip
  server_ip="$(prompt_server_ip)"
  local env_created="false"
  if [ ! -f "$INSTALL_DIR/.env" ]; then
    env_created="true"
  fi

  write_compose_file
  write_https_files
  write_env_file "$server_ip"
  configure_https_env "$server_ip" "$env_created"
  docker_login_if_needed

  cd "$INSTALL_DIR"
  echo "Pulling Onyxio images..."
  compose -f docker-compose.yml pull
  if https_configured; then
    docker pull "$(env_value "$INSTALL_DIR/.env" HTTPS_PROXY_IMAGE)"
  fi
  echo "Starting Onyxio..."
  start_compose
  wait_for_onyxio_startup

  echo
  echo "Onyxio is running."
  echo "Admin:  http://${server_ip}:4000/admin/"
  echo "TV:     http://${server_ip}:4000/tv/"
  echo "Mobile: http://${server_ip}:4000/mobile/"
  echo "Philips WebServices: http://${server_ip}/webservices.php"
  print_https_summary
  echo
  echo "License activation:"
  echo "  1. The Onyxio license public key is installed at ${INSTALL_DIR}/data/uploads/license/public-key.pem."
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
