#!/usr/bin/env bash
set -euo pipefail

INSTALL_DIR="${ONYXIO_INSTALL_DIR:-/opt/onyxio}"
VERSION="${ONYXIO_VERSION:-latest}"
SERVER_IMAGE="${ONYXIO_SERVER_IMAGE:-ghcr.io/onyxio-pty-ltd/server:${VERSION}}"
REGISTRY="${ONYXIO_REGISTRY:-ghcr.io}"
REGISTRY_USERNAME="${ONYXIO_REGISTRY_USERNAME:-}"
REGISTRY_TOKEN="${ONYXIO_REGISTRY_TOKEN:-}"
SKIP_BACKUP="${ONYXIO_SKIP_UPGRADE_BACKUP:-false}"
SKIP_HOST_REFRESH="${ONYXIO_SKIP_HOST_REFRESH:-false}"
VERSION_EXPLICIT="false"

if [ -n "${ONYXIO_VERSION:-}" ]; then
  VERSION_EXPLICIT="true"
fi

usage() {
  cat <<'EOF'
Usage: upgrade.sh [options]

Upgrades an existing Onyxio install by refreshing host support files, pulling a
new server image, and recreating the Onyxio backend container. Persistent
Postgres data, uploads, TLS files, and local config are kept.

Options:
  --version VERSION       Image tag to install. Defaults to ONYXIO_VERSION or latest.
  --image IMAGE           Full server image reference. Overrides --version.
  --install-dir PATH      Install directory. Defaults to /opt/onyxio.
  --skip-backup           Skip the pre-upgrade pg_dump backup.
  --skip-host-refresh     Do not update compose files, helpers, or network agent.
  -h, --help              Show this help.

Environment:
  ONYXIO_INSTALL_DIR=/opt/onyxio
  ONYXIO_VERSION=2026.08.15
  ONYXIO_SERVER_IMAGE=ghcr.io/onyxio-pty-ltd/server:2026.08.15
  ONYXIO_REGISTRY=ghcr.io
  ONYXIO_REGISTRY_USERNAME=YOUR_GITHUB_USERNAME
  ONYXIO_REGISTRY_TOKEN=TOKEN
  ONYXIO_SKIP_UPGRADE_BACKUP=true
  ONYXIO_SKIP_HOST_REFRESH=true
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
      SERVER_IMAGE="ghcr.io/onyxio-pty-ltd/server:${VERSION}"
      VERSION_EXPLICIT="true"
      shift 2
      ;;
    --version=*)
      VERSION="${1#*=}"
      SERVER_IMAGE="ghcr.io/onyxio-pty-ltd/server:${VERSION}"
      VERSION_EXPLICIT="true"
      shift
      ;;
    --image)
      if [ "$#" -lt 2 ]; then
        echo "--image requires a value." >&2
        exit 1
      fi
      SERVER_IMAGE="$2"
      shift 2
      ;;
    --image=*)
      SERVER_IMAGE="${1#*=}"
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
    --skip-backup)
      SKIP_BACKUP="true"
      shift
      ;;
    --skip-host-refresh)
      SKIP_HOST_REFRESH="true"
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

env_value() {
  local file="$1"
  local key="$2"
  grep "^${key}=" "$file" 2>/dev/null | tail -n 1 | cut -d= -f2- || true
}

is_cloud_install() {
  local env_file="$INSTALL_DIR/.env"

  case "$(printf '%s' "${ONYXIO_DEPLOYMENT:-$(env_value "$env_file" ONYXIO_DEPLOYMENT)}" | tr '[:upper:]' '[:lower:]')" in
    cloud)
      return 0
      ;;
  esac

  case "$(printf '%s' "${ONYXIO_CLOUD_MODE:-$(env_value "$env_file" ONYXIO_CLOUD_MODE)}" | tr '[:upper:]' '[:lower:]')" in
    y | yes | true | 1)
      return 0
      ;;
  esac

  return 1
}

derive_image_tag() {
  local image="$1"
  local tag

  case "$image" in
    *@*)
      return
      ;;
  esac

  tag="${image##*:}"
  if [ "$tag" != "$image" ] && [ -n "$tag" ] && [ "${tag#*/}" = "$tag" ]; then
    printf '%s\n' "$tag"
  fi
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

set_env_default() {
  local file="$1"
  local key="$2"
  local value="$3"

  if ! grep -q "^${key}=" "$file"; then
    printf '%s=%s\n' "$key" "$value" >> "$file"
  fi
}

remove_env_value() {
  local file="$1"
  local key="$2"

  if ! grep -q "^${key}=" "$file"; then
    return
  fi

  local tmp
  tmp="$(mktemp)"
  awk -v key="$key" '$0 !~ "^" key "=" { print }' "$file" > "$tmp"
  mv "$tmp" "$file"
}

set_env_value_if_current() {
  local file="$1"
  local key="$2"
  local current="$3"
  local replacement="$4"

  if [ "$(env_value "$file" "$key")" = "$current" ]; then
    set_env_value "$file" "$key" "$replacement"
  fi
}

random_secret() {
  if command -v openssl >/dev/null 2>&1; then
    openssl rand -hex 32
  else
    date +%s%N | sha256sum | awk '{print $1}'
  fi
}

require_root() {
  if [ "$(id -u)" -ne 0 ]; then
    echo "Run this upgrader with sudo:" >&2
    echo "  curl -fsSL https://install.onyxio.com.au/upgrade.sh | sudo env ONYXIO_VERSION=2026.08.15 bash" >&2
    exit 1
  fi
}

require_docker() {
  if ! command -v docker >/dev/null 2>&1; then
    echo "Docker is required on this server before upgrading Onyxio." >&2
    exit 1
  fi
}

require_install() {
  if [ ! -d "$INSTALL_DIR" ]; then
    echo "Install directory does not exist: ${INSTALL_DIR}" >&2
    exit 1
  fi

  if [ ! -f "$INSTALL_DIR/docker-compose.yml" ]; then
    echo "Missing ${INSTALL_DIR}/docker-compose.yml; this does not look like an Onyxio install." >&2
    exit 1
  fi

  if [ ! -f "$INSTALL_DIR/.env" ]; then
    echo "Missing ${INSTALL_DIR}/.env; this does not look like an Onyxio install." >&2
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
  echo "Install them, then run this upgrader again." >&2
  exit 1
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
  local source_dir agent_source service_file
  source_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd || pwd)"
  agent_source="$source_dir/network-agent.py"
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

docker_login_if_requested() {
  if [ -z "$REGISTRY_TOKEN" ]; then
    return
  fi

  if [ -z "$REGISTRY_USERNAME" ]; then
    echo "ONYXIO_REGISTRY_USERNAME is required when ONYXIO_REGISTRY_TOKEN is set." >&2
    exit 1
  fi

  echo "Logging in to ${REGISTRY} as ${REGISTRY_USERNAME}..."
  if command -v timeout >/dev/null 2>&1; then
    printf '%s\n' "$REGISTRY_TOKEN" | timeout 60s docker login "$REGISTRY" -u "$REGISTRY_USERNAME" --password-stdin
  else
    printf '%s\n' "$REGISTRY_TOKEN" | docker login "$REGISTRY" -u "$REGISTRY_USERNAME" --password-stdin
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
      PORT: ${PORT:-80}
      ONYXIO_NETWORK_AGENT_URL: ${ONYXIO_NETWORK_AGENT_URL:-http://127.0.0.1:8097}
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
      PORT: ${PORT:-80}
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

write_enable_https_script() {
  mkdir -p "$INSTALL_DIR/bin"

  cat > "$INSTALL_DIR/bin/enable-https" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

INSTALL_DIR="${ONYXIO_INSTALL_DIR:-/opt/onyxio}"
HTTPS_PROXY_IMAGE_DEFAULT="${ONYXIO_HTTPS_PROXY_IMAGE:-nginx:1.27-alpine}"

usage() {
  cat <<'USAGE'
Usage:
  sudo /opt/onyxio/bin/enable-https --host HOST --listen-address IP [--port 443]

Starts or updates the Onyxio HTTPS proxy after onboarding has selected the
final network interface address.

Required:
  --host             Public HTTPS host phones will open.
  --listen-address   Local server IP the nginx proxy should bind to.

Optional:
  --port             HTTPS listen port. Default: 443.
  --proxy-image      nginx image. Default: nginx:1.27-alpine.
USAGE
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

host=""
listen_address=""
port="443"
proxy_image=""

while [ "$#" -gt 0 ]; do
  case "$1" in
    --host)
      host="${2:-}"
      shift 2
      ;;
    --host=*)
      host="${1#*=}"
      shift
      ;;
    --listen-address)
      listen_address="${2:-}"
      shift 2
      ;;
    --listen-address=*)
      listen_address="${1#*=}"
      shift
      ;;
    --port)
      port="${2:-}"
      shift 2
      ;;
    --port=*)
      port="${1#*=}"
      shift
      ;;
    --proxy-image)
      proxy_image="${2:-}"
      shift 2
      ;;
    --proxy-image=*)
      proxy_image="${1#*=}"
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

if [ "$(id -u)" -ne 0 ]; then
  echo "Run this command with sudo." >&2
  exit 1
fi

if [ -z "$host" ] || [ -z "$listen_address" ]; then
  usage >&2
  exit 1
fi

if [ ! -f "$INSTALL_DIR/.env" ]; then
  echo "Onyxio is not installed at ${INSTALL_DIR}; .env is missing." >&2
  exit 1
fi

if [ ! -f "$INSTALL_DIR/docker-compose.https.yml" ] || [ ! -f "$INSTALL_DIR/nginx/onyxio-https.conf.template" ]; then
  echo "HTTPS proxy files are missing. Re-run the latest Onyxio installer, then retry." >&2
  exit 1
fi

if [ ! -s "$INSTALL_DIR/data/tls/fullchain.pem" ] || [ ! -s "$INSTALL_DIR/data/tls/privkey.pem" ]; then
  echo "TLS certificates are missing." >&2
  echo "Copy them to:" >&2
  echo "  ${INSTALL_DIR}/data/tls/fullchain.pem" >&2
  echo "  ${INSTALL_DIR}/data/tls/privkey.pem" >&2
  echo "Then run this command again." >&2
  exit 1
fi

env_file="$INSTALL_DIR/.env"
proxy_image="${proxy_image:-$(env_value "$env_file" HTTPS_PROXY_IMAGE)}"
proxy_image="${proxy_image:-$HTTPS_PROXY_IMAGE_DEFAULT}"

set_env_value "$env_file" ONYXIO_ENABLE_HTTPS true
set_env_value "$env_file" HTTPS_HOST "$host"
set_env_value "$env_file" HTTPS_LISTEN_ADDR "$listen_address"
set_env_value "$env_file" HTTPS_PORT "$port"
set_env_value "$env_file" HTTPS_PROXY_IMAGE "$proxy_image"
set_env_value "$env_file" MOBILE_APP_PUBLIC_URL "https://${host}/mobile/"

cd "$INSTALL_DIR"
compose -f docker-compose.yml -f docker-compose.https.yml up -d https-proxy

echo
echo "Onyxio HTTPS proxy is running."
echo "  Mobile app URL: https://${host}/mobile/"
echo "  DNS/split DNS: ${host} -> ${listen_address}"
echo "  Firewall: allow guest clients to ${listen_address} TCP ${port}"
echo "  Admin: use Settings > Network to generate or rerun this command."
EOF

  chmod +x "$INSTALL_DIR/bin/enable-https"
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
  local service_file="/etc/systemd/system/onyxio-watchdog.service"

  if ! command -v systemctl >/dev/null 2>&1; then
    echo "systemd is required for the Onyxio watchdog." >&2
    exit 1
  fi

  cat > "$service_file" <<EOF
[Unit]
Description=Onyxio Server Watchdog
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
  systemctl enable --now onyxio-watchdog.service >/dev/null
  systemctl restart onyxio-watchdog.service
}

write_lifecycle_scripts() {
  cat > "$INSTALL_DIR/upgrade.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
curl -fsSL https://install.onyxio.com.au/upgrade.sh | bash -s -- "$@"
EOF
  chmod +x "$INSTALL_DIR/upgrade.sh"

  cat > "$INSTALL_DIR/uninstall.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
curl -fsSL https://install.onyxio.com.au/uninstall.sh | bash -s -- "$@"
EOF
  chmod +x "$INSTALL_DIR/uninstall.sh"
}

refresh_host_files() {
  case "$(printf '%s' "$SKIP_HOST_REFRESH" | tr '[:upper:]' '[:lower:]')" in
    y | yes | true | 1)
      echo "Skipping host support refresh because ONYXIO_SKIP_HOST_REFRESH is enabled."
      return
      ;;
  esac

  echo "Refreshing host support files."
  mkdir -p "$INSTALL_DIR/data/postgres" "$INSTALL_DIR/data/uploads/license" "$INSTALL_DIR/data/tls"
  if ! is_cloud_install; then
    require_network_agent_dependencies
    install_network_agent
  fi
  install_license_public_key
  write_compose_file
  write_https_files
  write_enable_https_script
  write_watchdog_script
  write_lifecycle_scripts
}

ensure_env_defaults() {
  local env_file="$INSTALL_DIR/.env"

  set_env_default "$env_file" POSTGRES_IMAGE "${ONYXIO_POSTGRES_IMAGE:-postgres:15}"
  set_env_default "$env_file" HTTPS_PROXY_IMAGE "${ONYXIO_HTTPS_PROXY_IMAGE:-nginx:1.27-alpine}"
  if is_cloud_install; then
    set_env_value "$env_file" ONYXIO_CLOUD_MODE true
    set_env_value "$env_file" ONYXIO_DEPLOYMENT cloud
    set_env_value "$env_file" ONYXIO_NETWORK_APPLY_MODE disabled
    set_env_value "$env_file" CASTING_ENABLED false
    set_env_value "$env_file" PHILIPS_WEBSERVICES_ENABLED false
  else
    set_env_default "$env_file" ONYXIO_NETWORK_APPLY_MODE agent
    set_env_default "$env_file" ONYXIO_NETWORK_AGENT_URL http://127.0.0.1:8097
  fi
  set_env_default "$env_file" CASTING_HOST_TOKEN "$(random_secret)"
  set_env_default "$env_file" GRAPHQL_BODY_LIMIT 150mb
  set_env_default "$env_file" ONYXIO_LICENSE_DIR /app/backend/uploads/license
  set_env_default "$env_file" ONYXIO_LICENSE_PUBLIC_KEY_FILE /app/backend/uploads/license/public-key.pem
}

migrate_single_port_env() {
  local env_file="$INSTALL_DIR/.env"
  local server_ip

  server_ip="$(env_value "$env_file" SERVER_IP)"

  set_env_value_if_current "$env_file" PORT 4000 80
  if [ -n "$server_ip" ]; then
    set_env_value_if_current "$env_file" PUBLIC_SERVER_URL "http://${server_ip}:4000" "http://${server_ip}"
    set_env_value_if_current "$env_file" PUBLIC_APP_URL "http://${server_ip}:4000" "http://${server_ip}"
    set_env_value_if_current "$env_file" PUBLIC_TV_APP_URL "http://${server_ip}:4000/tv/" "http://${server_ip}/tv/"
    set_env_value_if_current "$env_file" MOBILE_APP_PUBLIC_URL "http://${server_ip}:4000/mobile/" "http://${server_ip}/mobile/"
  fi
  set_env_value_if_current "$env_file" CASTING_CONTROL_PLANE_WS_URL "ws://127.0.0.1:4000" "ws://127.0.0.1"

  remove_env_value "$env_file" WEB_SOCKET_PORT
  remove_env_value "$env_file" PHILIPS_WEBSERVICES_PORT
  remove_env_value "$env_file" PHILIPS_WEBSERVICES_BOOTSTRAP_PORT
}

compose_files() {
  printf '%s\n' "-f" "docker-compose.yml"
  if https_configured && tls_certificates_available; then
    printf '%s\n' "-f" "docker-compose.https.yml"
  fi
}

https_configured() {
  grep -q '^ONYXIO_ENABLE_HTTPS=true' "$INSTALL_DIR/.env" 2>/dev/null &&
    [ -n "$(env_value "$INSTALL_DIR/.env" HTTPS_HOST)" ] &&
    [ -f "$INSTALL_DIR/docker-compose.https.yml" ]
}

tls_certificates_available() {
  [ -s "$INSTALL_DIR/data/tls/fullchain.pem" ] && [ -s "$INSTALL_DIR/data/tls/privkey.pem" ]
}

run_compose() {
  local files
  mapfile -t files < <(compose_files)
  compose "${files[@]}" "$@"
}

remove_legacy_default_casting_host() {
  if [ ! -f docker-compose.yml ]; then
    return
  fi

  if compose -f docker-compose.yml config --services 2>/dev/null | grep -qx 'casting-host'; then
    echo "Removing legacy default casting-host container. Add on-prem bridges from Admin > Settings > Casting."
    compose -f docker-compose.yml rm -sf casting-host >/dev/null 2>&1 || true
  fi
}

backup_database() {
  case "$(printf '%s' "$SKIP_BACKUP" | tr '[:upper:]' '[:lower:]')" in
    y | yes | true | 1)
      echo "Skipping database backup because ONYXIO_SKIP_UPGRADE_BACKUP is enabled."
      return
      ;;
  esac

  local backup_dir backup_file postgres_user postgres_db
  backup_dir="$INSTALL_DIR/backups"
  backup_file="$backup_dir/onyxio-$(date +%Y%m%d-%H%M%S).sql"
  postgres_user="$(env_value "$INSTALL_DIR/.env" POSTGRES_USER)"
  postgres_db="$(env_value "$INSTALL_DIR/.env" POSTGRES_DB)"
  postgres_user="${postgres_user:-postgres}"
  postgres_db="${postgres_db:-onyxio}"

  mkdir -p "$backup_dir"
  chmod 0700 "$backup_dir"

  echo "Creating database backup: ${backup_file}"
  if ! run_compose exec -T postgres pg_dump -U "$postgres_user" "$postgres_db" > "$backup_file"; then
    rm -f "$backup_file"
    echo "Database backup failed; upgrade aborted." >&2
    echo "Use ONYXIO_SKIP_UPGRADE_BACKUP=true only if you have another verified backup." >&2
    exit 1
  fi

  chmod 0600 "$backup_file"
}

wait_for_onyxio_startup() {
  local timeout_seconds="${ONYXIO_UPGRADE_STARTUP_TIMEOUT_SECONDS:-120}"
  local port
  port="$(env_value "$INSTALL_DIR/.env" PORT)"
  port="${port:-80}"

  echo "Waiting for Onyxio backend startup checks to pass."
  local start_time
  start_time="$(date +%s)"
  local initial_restart_count=""

  while [ $(( $(date +%s) - start_time )) -lt "$timeout_seconds" ]; do
    local container_id
    container_id="$(run_compose ps -q onyxio 2>/dev/null || true)"

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
        echo "Onyxio backend restarted during startup; upgrade did not complete cleanly." >&2
        return 1
      fi

      if [ "$running" != "true" ]; then
        echo "Onyxio backend container is not running." >&2
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
  return 1
}

print_logs() {
  echo
  echo "Recent Onyxio backend logs:"
  run_compose logs --tail=160 onyxio || true
}

print_rollback_instructions() {
  local previous_version="$1"
  local previous_image="$2"

  echo
  echo "Rollback commands:"
  echo "  cd ${INSTALL_DIR}"
  echo "  sudo sed -i.bak 's#^ONYXIO_VERSION=.*#ONYXIO_VERSION=${previous_version}#' .env"
  echo "  sudo sed -i.bak 's#^ONYXIO_SERVER_IMAGE=.*#ONYXIO_SERVER_IMAGE=${previous_image}#' .env"
    echo "  docker compose pull onyxio"
    if https_configured && tls_certificates_available; then
    echo "  docker compose -f docker-compose.yml -f docker-compose.https.yml up -d onyxio https-proxy"
    else
    echo "  docker compose up -d onyxio"
    fi
}

main() {
  require_root
  require_docker
  require_install
  docker_login_if_requested

  cd "$INSTALL_DIR"

  if [ "$VERSION_EXPLICIT" != "true" ]; then
    local derived_version
    derived_version="$(derive_image_tag "$SERVER_IMAGE")"
    if [ -n "$derived_version" ]; then
      VERSION="$derived_version"
    fi
  fi

  local env_file previous_version previous_image
  env_file="$INSTALL_DIR/.env"
  previous_version="$(env_value "$env_file" ONYXIO_VERSION)"
  previous_image="$(env_value "$env_file" ONYXIO_SERVER_IMAGE)"
  previous_version="${previous_version:-unknown}"
  previous_image="${previous_image:-ghcr.io/onyxio-pty-ltd/server:${previous_version}}"

  echo "Current Onyxio image: ${previous_image}"
  echo "Target Onyxio image:  ${SERVER_IMAGE}"

  if [ "$previous_image" = "$SERVER_IMAGE" ]; then
    echo "Target image matches the current image. Pulling anyway in case the tag moved."
  fi

  remove_legacy_default_casting_host
  refresh_host_files
  migrate_single_port_env
  ensure_env_defaults
  backup_database

  set_env_value "$env_file" ONYXIO_VERSION "$VERSION"
  set_env_value "$env_file" ONYXIO_SERVER_IMAGE "$SERVER_IMAGE"

  echo "Pulling target image."
  if ! run_compose pull onyxio; then
    set_env_value "$env_file" ONYXIO_VERSION "$previous_version"
    set_env_value "$env_file" ONYXIO_SERVER_IMAGE "$previous_image"
    echo "Image pull failed; restored previous image settings." >&2
    exit 1
  fi

  if https_configured; then
    docker pull "$(env_value "$env_file" HTTPS_PROXY_IMAGE)" || true
  fi

  echo "Recreating Onyxio backend container."
  if https_configured && tls_certificates_available; then
    if ! run_compose up -d onyxio https-proxy; then
      set_env_value "$env_file" ONYXIO_VERSION "$previous_version"
      set_env_value "$env_file" ONYXIO_SERVER_IMAGE "$previous_image"
      echo "Container recreate failed; restored previous image settings." >&2
      print_rollback_instructions "$previous_version" "$previous_image" >&2
      exit 1
    fi
  elif ! run_compose up -d onyxio; then
    set_env_value "$env_file" ONYXIO_VERSION "$previous_version"
    set_env_value "$env_file" ONYXIO_SERVER_IMAGE "$previous_image"
    echo "Container recreate failed; restored previous image settings." >&2
    print_rollback_instructions "$previous_version" "$previous_image" >&2
    exit 1
  fi

  if ! wait_for_onyxio_startup; then
    print_logs >&2
    print_rollback_instructions "$previous_version" "$previous_image" >&2
    exit 1
  fi
  install_watchdog_service

  echo
  echo "Onyxio upgrade complete."
  echo "Previous image: ${previous_image}"
  echo "Current image:  ${SERVER_IMAGE}"
  echo "Host support files refreshed in ${INSTALL_DIR}."
  print_rollback_instructions "$previous_version" "$previous_image"
}

main "$@"
