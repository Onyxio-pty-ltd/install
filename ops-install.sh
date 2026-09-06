#!/usr/bin/env bash
set -euo pipefail

INSTALL_DIR="${ONYXIO_INSTALL_DIR:-/opt/onyxio-management}"
VERSION="${ONYXIO_MANAGEMENT_VERSION:-latest}"
APP_IMAGE="${ONYXIO_MANAGEMENT_IMAGE:-ghcr.io/onyxio-pty-ltd/management:${VERSION}}"
POSTGRES_IMAGE="${ONYXIO_POSTGRES_IMAGE:-postgres:15}"
HTTPS_PROXY_IMAGE="${ONYXIO_HTTPS_PROXY_IMAGE:-nginx:1.27-alpine}"
REGISTRY="${ONYXIO_REGISTRY:-ghcr.io}"
REGISTRY_USERNAME="${ONYXIO_REGISTRY_USERNAME:-}"
REGISTRY_TOKEN="${ONYXIO_REGISTRY_TOKEN:-}"
PUBLIC_SERVER_URL="${PUBLIC_SERVER_URL:-}"
# Keep the management stack separate from the platform's host ports.
PORT="${PORT:-8081}"
POSTGRES_PORT="${POSTGRES_PORT:-5433}"
HTTPS_PORT="${HTTPS_PORT:-8443}"
SKIP_WATCHDOG="${ONYXIO_SKIP_WATCHDOG:-false}"

usage() {
  cat <<'EOF'
Usage: ops-install.sh [options]

Installs the Onyxio management console as a cloud-only Docker Compose stack.
This installer does not configure on-prem services, casting hosts, Philips
WebServices, or host network agents.

Required:
  PUBLIC_SERVER_URL=https://console.example.com

Options:
  --version VERSION       Image tag to install. Defaults to latest.
  --image IMAGE           Full app image reference. Overrides --version.
  --install-dir PATH      Install directory. Defaults to /opt/onyxio-management.
  --public-url URL        Public cloud URL for the console.
  --port PORT             Host HTTP port. Defaults to 8081.
  --skip-watchdog         Do not install the systemd watchdog.
  -h, --help              Show this help.

Environment:
  PUBLIC_SERVER_URL=https://console.example.com
  ONYXIO_INSTALL_DIR=/opt/onyxio-management
  ONYXIO_MANAGEMENT_VERSION=latest
  ONYXIO_MANAGEMENT_IMAGE=ghcr.io/onyxio-pty-ltd/management:latest
  ONYXIO_POSTGRES_IMAGE=postgres:15
  PORT=8081
  POSTGRES_PORT=5433
  ONYXIO_REGISTRY=ghcr.io
  ONYXIO_REGISTRY_USERNAME=YOUR_GITHUB_USERNAME
  ONYXIO_REGISTRY_TOKEN=TOKEN
  ONYXIO_ENABLE_HTTPS=true
  HTTPS_HOST=console.example.com
  HTTPS_LISTEN_ADDR=0.0.0.0
  HTTPS_PORT=8443
  ONYXIO_SKIP_WATCHDOG=true

Optional team invitation email (PUBLIC_URL is set from the public cloud URL):
  EMAIL_PROVIDER=smtp
  EMAIL_FROM='Onyxio <no-reply@example.com>'
  SMTP_HOST=smtp.example.com
  SMTP_PORT=587
  SMTP_SECURE=false
  SMTP_USER=YOUR_SMTP_USERNAME
  SMTP_PASSWORD=YOUR_SMTP_PASSWORD
  Provider and TLS mode are detected automatically when omitted.
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
      APP_IMAGE="ghcr.io/onyxio-pty-ltd/management:${VERSION}"
      shift 2
      ;;
    --version=*)
      VERSION="${1#*=}"
      APP_IMAGE="ghcr.io/onyxio-pty-ltd/management:${VERSION}"
      shift
      ;;
    --image)
      if [ "$#" -lt 2 ]; then
        echo "--image requires a value." >&2
        exit 1
      fi
      APP_IMAGE="$2"
      shift 2
      ;;
    --image=*)
      APP_IMAGE="${1#*=}"
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
    --public-url)
      if [ "$#" -lt 2 ]; then
        echo "--public-url requires a URL." >&2
        exit 1
      fi
      PUBLIC_SERVER_URL="$2"
      shift 2
      ;;
    --public-url=*)
      PUBLIC_SERVER_URL="${1#*=}"
      shift
      ;;
    --port)
      if [ "$#" -lt 2 ]; then
        echo "--port requires a value." >&2
        exit 1
      fi
      PORT="$2"
      shift 2
      ;;
    --port=*)
      PORT="${1#*=}"
      shift
      ;;
    --skip-watchdog)
      SKIP_WATCHDOG="true"
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

strip_trailing_slash() {
  local value="$1"
  while [ "${value%/}" != "$value" ]; do
    value="${value%/}"
  done
  echo "$value"
}

require_http_url() {
  local name="$1"
  local value="$2"

  case "$value" in
    http://* | https://*)
      return
      ;;
    *)
      echo "${name} must start with http:// or https://." >&2
      exit 1
      ;;
  esac
}

valid_port() {
  local value="$1"
  [[ "$value" =~ ^[0-9]+$ ]] && [ "$value" -ge 1 ] && [ "$value" -le 65535 ]
}

require_safe_install_dir() {
  case "$INSTALL_DIR" in
    /*)
      ;;
    *)
      echo "Install directory must be an absolute path." >&2
      exit 1
      ;;
  esac

  case "$INSTALL_DIR" in
    '' | / | /bin | /boot | /dev | /etc | /home | /lib | /lib64 | /opt | /proc | /root | /run | /sbin | /sys | /tmp | /usr | /var)
      echo "Refusing unsafe install directory: ${INSTALL_DIR:-<empty>}" >&2
      exit 1
      ;;
  esac

  case "$INSTALL_DIR" in
    *[!A-Za-z0-9_./-]*)
      echo "Install directory may only contain letters, numbers, dots, underscores, dashes, and slashes." >&2
      exit 1
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

bool_true() {
  case "$(printf '%s' "${1:-}" | tr '[:upper:]' '[:lower:]')" in
    y | yes | true | 1)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

require_root() {
  if [ "$(id -u)" -ne 0 ]; then
    echo "Run this installer with sudo:" >&2
    echo "  curl -fsSL https://install.onyxio.com.au/ops-install.sh | sudo env PUBLIC_SERVER_URL=https://console.example.com bash" >&2
    exit 1
  fi
}

docker_host_os() {
  local ID=""
  if [ -r /etc/os-release ]; then
    . /etc/os-release
  fi
  printf '%s\n' "$ID"
}

require_docker() {
  local missing_engine=false
  local missing_compose=false
  local packages=()
  local package

  command -v docker >/dev/null 2>&1 || missing_engine=true
  if ! docker compose version >/dev/null 2>&1 && ! docker-compose version >/dev/null 2>&1; then
    missing_compose=true
  fi

  if [ "$missing_engine" = true ] || [ "$missing_compose" = true ]; then
    if [ "$(docker_host_os)" != ubuntu ] || ! command -v apt-get >/dev/null 2>&1; then
      echo "Automatic Docker installation requires Ubuntu with apt-get." >&2
      echo "Install Docker Engine and Compose for this operating system, then rerun the installer." >&2
      exit 1
    fi

    echo "Downloading and installing missing Docker prerequisites from package repositories..."
    apt-get update
    if [ "$missing_engine" = true ]; then
      packages+=(docker.io)
    fi
    if [ "$missing_compose" = true ]; then
      # Reuse Docker's repository when it is already configured for an existing engine.
      if [ "$missing_engine" = false ] && apt-cache show docker-compose-plugin >/dev/null 2>&1; then
        packages+=(docker-compose-plugin)
      else
        packages+=(docker-compose-v2)
      fi
    fi
    for package in "${packages[@]}"; do
      if ! apt-cache show "$package" >/dev/null 2>&1; then
        DEBIAN_FRONTEND=noninteractive apt-get install --no-remove -y software-properties-common
        add-apt-repository -y universe
        apt-get update
        break
      fi
    done
    # Do not replace/remove an existing engine when only Compose is missing.
    DEBIAN_FRONTEND=noninteractive apt-get install --no-install-recommends --no-remove -y "${packages[@]}" ca-certificates curl
  fi

  if ! command -v docker >/dev/null 2>&1; then
    echo "Docker installation did not provide the docker command." >&2
    exit 1
  fi
  if ! docker compose version >/dev/null 2>&1 && ! docker-compose version >/dev/null 2>&1; then
    echo "Docker Compose is still unavailable after installing prerequisites." >&2
    exit 1
  fi
  if ! docker info >/dev/null 2>&1; then
    if command -v systemctl >/dev/null 2>&1; then
      systemctl enable --now docker
    fi
    if ! docker info >/dev/null 2>&1; then
      echo "Docker is installed, but its daemon is not reachable. Start Docker and rerun the installer." >&2
      exit 1
    fi
  fi
}

require_clean_install_dir() {
  if [ -f "$INSTALL_DIR/.env" ]; then
    echo "Onyxio management is already installed at ${INSTALL_DIR}." >&2
    echo "Run ${INSTALL_DIR}/uninstall.sh first, or choose a different ONYXIO_INSTALL_DIR." >&2
    exit 1
  fi
}

resolve_public_server_url() {
  local public_url="$PUBLIC_SERVER_URL"

  if [ -z "$public_url" ] && [ -n "${HTTPS_HOST:-}" ]; then
    public_url="https://${HTTPS_HOST}"
  fi

  if [ -z "$public_url" ]; then
    public_url="$(prompt "Public cloud URL" "")"
  fi

  public_url="$(strip_trailing_slash "$public_url")"
  require_http_url "PUBLIC_SERVER_URL" "$public_url"
  echo "$public_url"
}

docker_login_if_needed() {
  if [ -z "$REGISTRY_TOKEN" ]; then
    if [ -r /dev/tty ]; then
      echo "ONYXIO_REGISTRY_TOKEN is not set."
      REGISTRY_TOKEN="$(prompt_secret "Registry token for ${REGISTRY} (leave blank if image is public)")"
    else
      echo "ONYXIO_REGISTRY_TOKEN is not set; skipping registry login."
    fi
  fi

  if [ -n "$REGISTRY_TOKEN" ]; then
    if [ -z "$REGISTRY_USERNAME" ]; then
      REGISTRY_USERNAME="$(prompt "Registry username" "onyxio-pty-ltd")"
    fi
    if [ -z "$REGISTRY_USERNAME" ]; then
      echo "Registry username is required when ONYXIO_REGISTRY_TOKEN is set." >&2
      exit 1
    fi
    echo "Logging in to ${REGISTRY} as ${REGISTRY_USERNAME}..."
    if command -v timeout >/dev/null 2>&1; then
      printf '%s\n' "$REGISTRY_TOKEN" | timeout 60s docker login "$REGISTRY" -u "$REGISTRY_USERNAME" --password-stdin
    else
      printf '%s\n' "$REGISTRY_TOKEN" | docker login "$REGISTRY" -u "$REGISTRY_USERNAME" --password-stdin
    fi
  fi
}

generate_license_private_key() {
  local key_file="$INSTALL_DIR/data/backend/license/private-key.pem"

  if [ -s "$key_file" ]; then
    chmod 0600 "$key_file"
    echo "Existing management license private key found; keeping it."
    return
  fi

  if ! command -v openssl >/dev/null 2>&1; then
    echo "OpenSSL is required to generate the management license signing key." >&2
    exit 1
  fi

  mkdir -p "$(dirname "$key_file")"
  openssl genpkey -algorithm ED25519 -out "$key_file" >/dev/null 2>&1
  chmod 0600 "$key_file"
  echo "Generated management license private key."
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
      POSTGRES_DB: ${POSTGRES_DB:-onyxio_management}
    ports:
      - "127.0.0.1:${POSTGRES_PORT:-5433}:5432"
    volumes:
      - ./data/postgres:/var/lib/postgresql/data
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U ${POSTGRES_USER:-postgres} -d ${POSTGRES_DB:-onyxio_management}"]
      interval: 10s
      timeout: 5s
      retries: 12

  onyxio:
    image: ${ONYXIO_MANAGEMENT_IMAGE}
    restart: unless-stopped
    network_mode: host
    depends_on:
      postgres:
        condition: service_healthy
    env_file:
      - .env
    environment:
      NODE_ENV: production
      DATABASE_URL: postgresql://${POSTGRES_USER:-postgres}:${POSTGRES_PASSWORD}@127.0.0.1:${POSTGRES_PORT:-5433}/${POSTGRES_DB:-onyxio_management}
      PORT: ${PORT:-8081}
    volumes:
      - ./data/backend:/app/backend/data
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
      HTTPS_PORT: ${HTTPS_PORT:-8443}
      PORT: ${PORT:-8081}
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

# Quote values for Docker Compose dotenv parsing, including literal dollars in
# SMTP credentials. Escape backslashes first so later escapes stay intact.
quote_compose_env_value() {
  local value="$1"
  value="${value//\\/\\\\}"
  value="${value//\"/\\\"}"
  value="${value//\$/\$\$}"
  value="${value//$'\n'/\\n}"
  value="${value//$'\r'/\\r}"
  printf '"%s"' "$value"
}

write_env_file() {
  local public_url="$1"
  local postgres_password jwt_secret
  postgres_password="$(random_secret)"
  jwt_secret="$(random_secret)"

  cat > "$INSTALL_DIR/.env" <<EOF
ONYXIO_MANAGEMENT_VERSION=${VERSION}
ONYXIO_MANAGEMENT_IMAGE=${APP_IMAGE}
POSTGRES_IMAGE=${POSTGRES_IMAGE}

PUBLIC_SERVER_URL=${public_url}
PUBLIC_APP_URL=${public_url}
PUBLIC_URL=${public_url}
CORS_ORIGIN=${public_url}

PORT=${PORT}
DATA_FILE=/app/backend/data/app-data.json
UPLOADS_DIR=/app/backend/uploads
FRONTEND_DIST_DIR=/app/frontend/dist
GRAPHQL_BODY_LIMIT=150mb
TELEGRAM_BOT_TOKEN=${TELEGRAM_BOT_TOKEN:-}

EMAIL_PROVIDER=$(quote_compose_env_value "${EMAIL_PROVIDER:-}")
EMAIL_FROM=$(quote_compose_env_value "${EMAIL_FROM:-}")
SMTP_HOST=$(quote_compose_env_value "${SMTP_HOST:-}")
SMTP_PORT=$(quote_compose_env_value "${SMTP_PORT:-587}")
SMTP_SECURE=$(quote_compose_env_value "${SMTP_SECURE:-}")
SMTP_USER=$(quote_compose_env_value "${SMTP_USER:-}")
SMTP_PASSWORD=$(quote_compose_env_value "${SMTP_PASSWORD:-}")

ONYXIO_CLOUD_MODE=true
ONYXIO_DEPLOYMENT=cloud
ONYXIO_NETWORK_APPLY_MODE=disabled
CASTING_ENABLED=false
CASTING_HOST_RUNTIME_ENABLED=false
PHILIPS_WEBSERVICES_ENABLED=false

POSTGRES_USER=postgres
POSTGRES_PASSWORD=${postgres_password}
POSTGRES_DB=onyxio_management
POSTGRES_PORT=${POSTGRES_PORT}
DATABASE_URL=postgresql://postgres:${postgres_password}@127.0.0.1:${POSTGRES_PORT}/onyxio_management

JWT_SECRET=${jwt_secret}
ONYXIO_LICENSE_PRIVATE_KEY_FILE=/app/backend/data/license/private-key.pem
EOF
  chmod 0600 "$INSTALL_DIR/.env"
}

configure_https_env() {
  local env_file="$INSTALL_DIR/.env"
  local enable_https="${ONYXIO_ENABLE_HTTPS:-}"

  case "$(printf '%s' "$enable_https" | tr '[:upper:]' '[:lower:]')" in
    y | yes | true | 1)
      ;;
    *)
      return
      ;;
  esac

  local https_host listen_addr https_port proxy_image
  https_host="${HTTPS_HOST:-}"
  if [ -z "$https_host" ]; then
    https_host="$(prompt "HTTPS hostname" "")"
  fi
  if [ -z "$https_host" ]; then
    echo "HTTPS was requested but no HTTPS_HOST was provided; skipping HTTPS proxy setup." >&2
    return
  fi

  listen_addr="${HTTPS_LISTEN_ADDR:-0.0.0.0}"
  https_port="${HTTPS_PORT:-8443}"
  proxy_image="${HTTPS_PROXY_IMAGE:-$HTTPS_PROXY_IMAGE}"

  set_env_value "$env_file" ONYXIO_ENABLE_HTTPS true
  set_env_value "$env_file" HTTPS_HOST "$https_host"
  set_env_value "$env_file" HTTPS_LISTEN_ADDR "$listen_addr"
  set_env_value "$env_file" HTTPS_PORT "$https_port"
  set_env_value "$env_file" HTTPS_PROXY_IMAGE "$proxy_image"
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

print_startup_logs() {
  echo
  echo "Recent Onyxio management logs:"
  compose -f docker-compose.yml logs --tail=160 onyxio || true
}

wait_for_startup() {
  local timeout_seconds="${ONYXIO_INSTALL_STARTUP_TIMEOUT_SECONDS:-120}"
  local port
  port="$(env_value "$INSTALL_DIR/.env" PORT)"
  port="${port:-8081}"

  echo "Waiting for Onyxio management startup checks to pass."
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
        echo "Onyxio management restarted during startup; install did not complete cleanly." >&2
        print_startup_logs >&2
        return 1
      fi

      if [ "$running" != "true" ]; then
        echo "Onyxio management container stopped during startup; install did not complete cleanly." >&2
        print_startup_logs >&2
        return 1
      fi

      if ( : > "/dev/tcp/127.0.0.1/${port}" ) >/dev/null 2>&1; then
        echo "Onyxio management is accepting connections on port ${port}."
        return 0
      fi
    fi

    sleep 2
  done

  echo "Onyxio management did not accept connections on port ${port} within ${timeout_seconds} seconds." >&2
  print_startup_logs >&2
  return 1
}

write_watchdog_script() {
  local source_dir watchdog_source
  source_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd || pwd)"
  watchdog_source="$source_dir/watchdog.sh"

  mkdir -p "$INSTALL_DIR/bin"
  if [ -f "$watchdog_source" ]; then
    cp "$watchdog_source" "$INSTALL_DIR/bin/watchdog"
  else
    curl -fsSL "${ONYXIO_INSTALL_BASE_URL:-https://install.onyxio.com.au}/watchdog.sh" \
      -o "$INSTALL_DIR/bin/watchdog"
  fi
  chmod +x "$INSTALL_DIR/bin/watchdog"
}

install_watchdog_service() {
  local service_file="/etc/systemd/system/onyxio-management-watchdog.service"

  if bool_true "$SKIP_WATCHDOG"; then
    return
  fi

  if ! command -v systemctl >/dev/null 2>&1; then
    echo "systemd is not available; skipping watchdog service."
    return
  fi

  cat > "$service_file" <<EOF
[Unit]
Description=Onyxio Management Watchdog
After=docker.service network-online.target
Wants=docker.service network-online.target

[Service]
Type=simple
Environment=ONYXIO_INSTALL_DIR=${INSTALL_DIR}
ExecStart=${INSTALL_DIR}/bin/watchdog
Restart=always
RestartSec=10
User=root
Group=root

[Install]
WantedBy=multi-user.target
EOF

  systemctl daemon-reload
  systemctl enable --now onyxio-management-watchdog.service >/dev/null
  systemctl restart onyxio-management-watchdog.service
}

write_lifecycle_scripts() {
  cat > "$INSTALL_DIR/uninstall.sh" <<EOF
#!/usr/bin/env bash
set -euo pipefail
export ONYXIO_INSTALL_DIR="${INSTALL_DIR}"
curl -fsSL https://install.onyxio.com.au/uninstall.sh | bash -s -- "\$@"
EOF
  chmod +x "$INSTALL_DIR/uninstall.sh"
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
  https_port="${https_port:-8443}"

  echo
  echo "HTTPS front door:"
  echo "  DNS: ${https_host} -> ${listen_addr}"
  echo "  Firewall: allow clients to ${listen_addr} TCP ${https_port}"

  if tls_certificates_available; then
    echo "  Proxy: running via docker-compose.https.yml"
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
  require_safe_install_dir
  require_clean_install_dir
  require_docker

  if ! valid_port "$PORT"; then
    echo "PORT must be an integer from 1 to 65535." >&2
    exit 1
  fi
  if ! valid_port "$POSTGRES_PORT"; then
    echo "POSTGRES_PORT must be an integer from 1 to 65535." >&2
    exit 1
  fi
  if ! valid_port "$HTTPS_PORT"; then
    echo "HTTPS_PORT must be an integer from 1 to 65535." >&2
    exit 1
  fi

  local public_url
  public_url="$(resolve_public_server_url)"

  mkdir -p \
    "$INSTALL_DIR/data/backend/license" \
    "$INSTALL_DIR/data/postgres" \
    "$INSTALL_DIR/data/tls" \
    "$INSTALL_DIR/data/uploads"

  write_compose_file
  write_https_files
  write_env_file "$public_url"
  configure_https_env
  generate_license_private_key
  write_watchdog_script
  write_lifecycle_scripts
  docker_login_if_needed

  cd "$INSTALL_DIR"
  echo "Pulling Onyxio management images..."
  compose -f docker-compose.yml pull
  if https_configured; then
    docker pull "$(env_value "$INSTALL_DIR/.env" HTTPS_PROXY_IMAGE)"
  fi

  echo "Starting Onyxio management..."
  start_compose
  wait_for_startup
  install_watchdog_service

  echo
  echo "Onyxio management is running."
  echo "Console: $(env_value "$INSTALL_DIR/.env" PUBLIC_APP_URL)/"
  print_https_summary
  echo
  echo "Install directory: ${INSTALL_DIR}"
  echo "Cloud mode: enabled"
  echo "View logs with:"
  echo "  cd ${INSTALL_DIR} && docker compose logs -f onyxio"
  if ! bool_true "$SKIP_WATCHDOG"; then
    echo "Watchdog logs:"
    echo "  journalctl -u onyxio-management-watchdog.service -f"
  fi
}

main "$@"
