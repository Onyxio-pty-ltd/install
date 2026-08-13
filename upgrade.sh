#!/usr/bin/env bash
set -euo pipefail

INSTALL_DIR="${ONYXIO_INSTALL_DIR:-/opt/onyxio}"
VERSION="${ONYXIO_VERSION:-latest}"
SERVER_IMAGE="${ONYXIO_SERVER_IMAGE:-ghcr.io/onyxio-pty-ltd/server:${VERSION}}"
REGISTRY="${ONYXIO_REGISTRY:-ghcr.io}"
REGISTRY_USERNAME="${ONYXIO_REGISTRY_USERNAME:-}"
REGISTRY_TOKEN="${ONYXIO_REGISTRY_TOKEN:-}"
SKIP_BACKUP="${ONYXIO_SKIP_UPGRADE_BACKUP:-false}"
VERSION_EXPLICIT="false"

if [ -n "${ONYXIO_VERSION:-}" ]; then
  VERSION_EXPLICIT="true"
fi

usage() {
  cat <<'EOF'
Usage: upgrade.sh [options]

Upgrades an existing Onyxio install by pulling a new server image and
recreating only the Onyxio backend container. Persistent Postgres data,
uploads, TLS files, and local config are kept.

Options:
  --version VERSION      Image tag to install. Defaults to ONYXIO_VERSION or latest.
  --image IMAGE          Full server image reference. Overrides --version.
  --install-dir PATH     Install directory. Defaults to /opt/onyxio.
  --skip-backup          Skip the pre-upgrade pg_dump backup.
  -h, --help             Show this help.

Environment:
  ONYXIO_INSTALL_DIR=/opt/onyxio
  ONYXIO_VERSION=2026.08.03
  ONYXIO_SERVER_IMAGE=ghcr.io/onyxio-pty-ltd/server:2026.08.03
  ONYXIO_REGISTRY=ghcr.io
  ONYXIO_REGISTRY_USERNAME=YOUR_GITHUB_USERNAME
  ONYXIO_REGISTRY_TOKEN=TOKEN
  ONYXIO_SKIP_UPGRADE_BACKUP=true
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
    --image)
      if [ "$#" -lt 2 ]; then
        echo "--image requires a value." >&2
        exit 1
      fi
      SERVER_IMAGE="$2"
      shift 2
      ;;
    --install-dir)
      if [ "$#" -lt 2 ]; then
        echo "--install-dir requires a path." >&2
        exit 1
      fi
      INSTALL_DIR="$2"
      shift 2
      ;;
    --skip-backup)
      SKIP_BACKUP="true"
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

require_root() {
  if [ "$(id -u)" -ne 0 ]; then
    echo "Run this upgrader with sudo:" >&2
    echo "  curl -fsSL https://install.onyxio.com.au/upgrade.sh | sudo bash" >&2
    exit 1
  fi
}

require_docker() {
  if ! command -v docker >/dev/null 2>&1; then
    echo "Docker is required on this server before upgrading Onyxio." >&2
    exit 1
  fi
}

require_network_agent_dependencies() {
  local missing_packages=()

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
  echo "Install them, then run this upgrade again." >&2
  exit 1
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
Environment=ONYXIO_NETPLAN_LEGACY_FILE=/etc/netplan/90-onyxio-managed.yaml
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
  echo "Onyxio host network agent is running."
}

remove_old_network_env() {
  if grep -q '^ONYXIO_NETPLAN_COMMAND_MODE=' "$INSTALL_DIR/.env"; then
    sed -i.bak '/^ONYXIO_NETPLAN_COMMAND_MODE=/d' "$INSTALL_DIR/.env"
  fi
  set_env_value "$INSTALL_DIR/.env" ONYXIO_NETWORK_APPLY_MODE agent
  set_env_value "$INSTALL_DIR/.env" ONYXIO_NETWORK_AGENT_URL http://127.0.0.1:8097
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
  port="${port:-4000}"

  echo "Waiting for Onyxio backend to accept connections on port ${port}."
  local start_time
  start_time="$(date +%s)"

  while [ $(( $(date +%s) - start_time )) -lt "$timeout_seconds" ]; do
    local container_id
    container_id="$(run_compose ps -q onyxio 2>/dev/null || true)"

    if [ -n "$container_id" ]; then
      local running
      running="$(docker inspect -f '{{.State.Running}}' "$container_id" 2>/dev/null || echo false)"
      if [ "$running" != "true" ]; then
        echo "Onyxio backend container is not running." >&2
        return 1
      fi

      if ( : > "/dev/tcp/127.0.0.1/${port}" ) >/dev/null 2>&1; then
        echo "Onyxio backend is accepting connections."
        return 0
      fi
    fi

    sleep 2
  done

  echo "Onyxio backend did not accept connections within ${timeout_seconds} seconds." >&2
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
  echo "  docker compose up -d onyxio"
}

main() {
  require_root
  require_docker
  require_network_agent_dependencies
  require_install
  install_network_agent
  remove_old_network_env
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

  backup_database

  set_env_value "$env_file" ONYXIO_VERSION "$VERSION"
  set_env_value "$env_file" ONYXIO_SERVER_IMAGE "$SERVER_IMAGE"

  echo "Pulling target image..."
  if ! run_compose pull onyxio; then
    set_env_value "$env_file" ONYXIO_VERSION "$previous_version"
    set_env_value "$env_file" ONYXIO_SERVER_IMAGE "$previous_image"
    echo "Image pull failed; restored previous image settings." >&2
    exit 1
  fi

  echo "Recreating Onyxio backend container..."
  if ! run_compose up -d onyxio; then
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

  echo
  echo "Onyxio upgrade complete."
  echo "Previous image: ${previous_image}"
  echo "Current image:  ${SERVER_IMAGE}"
  print_rollback_instructions "$previous_version" "$previous_image"
}

main "$@"
