#!/usr/bin/env bash
set -euo pipefail

INSTALL_DIR="${ONYXIO_INSTALL_DIR:-/opt/onyxio}"
ASSUME_YES="${ONYXIO_UNINSTALL_CONFIRM:-false}"
KEEP_DATA="false"
REMOVE_IMAGES="false"

usage() {
  cat <<'EOF'
Usage: uninstall.sh [options]

Stops and removes the Onyxio Compose stack, then removes the install directory.

Options:
  -y, --yes         Do not prompt for confirmation.
  --keep-data      Keep the install directory and persistent data.
  --remove-images  Also remove Onyxio Docker images after containers stop.
  --install-dir    Install directory. Defaults to /opt/onyxio.
  -h, --help       Show this help.

Environment:
  ONYXIO_INSTALL_DIR=/opt/onyxio
  ONYXIO_UNINSTALL_CONFIRM=true
EOF
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    -y | --yes)
      ASSUME_YES="true"
      shift
      ;;
    --keep-data)
      KEEP_DATA="true"
      shift
      ;;
    --remove-images)
      REMOVE_IMAGES="true"
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

docker_available() {
  command -v docker >/dev/null 2>&1
}

compose_available() {
  docker_available &&
    { docker compose version >/dev/null 2>&1 || command -v docker-compose >/dev/null 2>&1; }
}

confirm() {
  case "$(printf '%s' "$ASSUME_YES" | tr '[:upper:]' '[:lower:]')" in
    y | yes | true | 1)
      return
      ;;
  esac

  echo "This will uninstall Onyxio from:"
  echo "  ${INSTALL_DIR}"
  if [ "$KEEP_DATA" = "true" ]; then
    echo "Persistent data will be kept."
  else
    echo "Persistent data, uploads, TLS certificates, and config will be deleted."
  fi
  echo
  printf "Type 'uninstall onyxio' to continue: "
  local answer
  if [ -r /dev/tty ]; then
    read -r answer </dev/tty
  else
    echo
    echo "Cannot prompt for confirmation; rerun with --yes or ONYXIO_UNINSTALL_CONFIRM=true." >&2
    exit 1
  fi
  if [ "$answer" != "uninstall onyxio" ]; then
    echo "Uninstall cancelled."
    exit 1
  fi
}

require_root() {
  if [ "$(id -u)" -ne 0 ]; then
    echo "Run this uninstaller with sudo." >&2
    exit 1
  fi
}

assert_safe_install_dir() {
  if [ -z "$INSTALL_DIR" ] || [ "$INSTALL_DIR" = "/" ]; then
    echo "Refusing to uninstall from unsafe install directory: ${INSTALL_DIR:-<empty>}" >&2
    exit 1
  fi

  case "$INSTALL_DIR" in
    /bin | /boot | /dev | /etc | /home | /lib | /lib64 | /opt | /proc | /root | /run | /sbin | /sys | /tmp | /usr | /var)
      echo "Refusing to uninstall from unsafe install directory: ${INSTALL_DIR}" >&2
      exit 1
      ;;
  esac

  if [ -d "$INSTALL_DIR" ] &&
    [ ! -f "$INSTALL_DIR/docker-compose.yml" ] &&
    [ ! -f "$INSTALL_DIR/docker-compose.gateway.yml" ] &&
    [ ! -f "$INSTALL_DIR/.env" ] &&
    [ ! -d "$INSTALL_DIR/data" ]; then
    echo "Refusing to delete ${INSTALL_DIR}; it does not look like an Onyxio install directory." >&2
    exit 1
  fi
}

stop_compose_stack() {
  if [ ! -d "$INSTALL_DIR" ]; then
    echo "Install directory does not exist: ${INSTALL_DIR}"
    return
  fi

  if ! compose_available; then
    echo "Docker Compose is not available; skipping Compose shutdown."
    return
  fi

  cd "$INSTALL_DIR"
  if [ -f docker-compose.yml ] && [ -f docker-compose.https.yml ]; then
    compose -f docker-compose.yml -f docker-compose.https.yml down --remove-orphans
  elif [ -f docker-compose.yml ]; then
    compose -f docker-compose.yml down --remove-orphans
  elif [ -f docker-compose.gateway.yml ]; then
    compose -f docker-compose.gateway.yml down --remove-orphans
  else
    echo "No Compose file found in ${INSTALL_DIR}; skipping Compose shutdown."
  fi
}

remove_leftover_containers() {
  if ! docker_available; then
    echo "Docker is not available; skipping container cleanup."
    return
  fi

  local project_name
  project_name="$(basename "$INSTALL_DIR" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9_-]/-/g')"

  docker ps -a \
    --filter "label=com.docker.compose.project=${project_name}" \
    --format '{{.ID}}' |
    while IFS= read -r container_id; do
      [ -n "$container_id" ] && docker rm -f "$container_id" >/dev/null
    done

  docker ps -a --format '{{.ID}} {{.Names}}' |
    awk -v project="$project_name" '$2 ~ "^" project "([-_]|$)" { print $1 }' |
    while IFS= read -r container_id; do
      [ -n "$container_id" ] && docker rm -f "$container_id" >/dev/null
    done
}

remove_watchdog() {
  if ! command -v systemctl >/dev/null 2>&1; then
    rm -f "$INSTALL_DIR/bin/watchdog"
    return
  fi

  systemctl disable --now onyxio-watchdog.service >/dev/null 2>&1 || true
  rm -f /etc/systemd/system/onyxio-watchdog.service
  rm -f "$INSTALL_DIR/bin/watchdog"
  systemctl daemon-reload >/dev/null 2>&1 || true
  systemctl reset-failed onyxio-watchdog.service >/dev/null 2>&1 || true
  echo "Removed Onyxio watchdog service and files."
}

remove_network_agent() {
  if ! command -v systemctl >/dev/null 2>&1; then
    return
  fi

  systemctl disable --now onyxio-network-agent.service >/dev/null 2>&1 || true
  rm -f /etc/systemd/system/onyxio-network-agent.service
  rm -rf "$INSTALL_DIR/network-agent"
  systemctl daemon-reload >/dev/null 2>&1 || true
  systemctl reset-failed onyxio-network-agent.service >/dev/null 2>&1 || true
  echo "Removed Onyxio host network agent service and files."
}

remove_images() {
  if ! docker_available; then
    echo "Docker is not available; skipping image cleanup."
    return
  fi

  docker images --format '{{.Repository}}:{{.Tag}}' |
    awk '$1 ~ /(^|\/)onyxio\// || $1 ~ /^ghcr\.io\/onyxio-pty-ltd\/server:/ { print $1 }' |
    while IFS= read -r image; do
      [ -n "$image" ] && docker rmi "$image" >/dev/null || true
    done
}

remove_install_dir() {
  if [ "$KEEP_DATA" = "true" ]; then
    echo "Keeping install directory: ${INSTALL_DIR}"
    return
  fi

  if [ -d "$INSTALL_DIR" ]; then
    rm -rf "$INSTALL_DIR"
    echo "Removed install directory: ${INSTALL_DIR}"
  fi
}

main() {
  require_root
  assert_safe_install_dir
  confirm

  remove_watchdog
  stop_compose_stack
  remove_leftover_containers
  remove_network_agent
  remove_install_dir

  if [ "$REMOVE_IMAGES" = "true" ]; then
    remove_images
  fi

  echo
  echo "Onyxio uninstall complete."
  echo "Docker itself was not removed."
}

main "$@"
