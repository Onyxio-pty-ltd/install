#!/usr/bin/env bash
set -euo pipefail

INSTALL_DIR="${ONYXIO_INSTALL_DIR:-/opt/onyxio}"
CHECK_INTERVAL_SECONDS="${ONYXIO_WATCHDOG_INTERVAL_SECONDS:-30}"
FAILURE_THRESHOLD="${ONYXIO_WATCHDOG_FAILURE_THRESHOLD:-3}"
onyxio_tcp_failures=0

log() {
  printf '[%s] %s\n' "$(date '+%Y-%m-%dT%H:%M:%S%z')" "$*"
}

compose() {
  if docker compose version >/dev/null 2>&1; then
    docker compose "$@"
  elif command -v docker-compose >/dev/null 2>&1; then
    docker-compose "$@"
  else
    log "Docker Compose is required."
    return 1
  fi
}

env_value() {
  local file="$1"
  local key="$2"
  grep "^${key}=" "$file" 2>/dev/null | tail -n 1 | cut -d= -f2- || true
}

run_compose() {
  local files=(-f docker-compose.yml)

  compose "${files[@]}" "$@"
}

onyxio_container_running() {
  local service="$1"
  local container_id running

  container_id="$(run_compose ps -q "$service" 2>/dev/null || true)"
  if [ -z "$container_id" ]; then
    return 1
  fi

  running="$(docker inspect -f '{{.State.Running}}' "$container_id" 2>/dev/null || echo false)"
  [ "$running" = "true" ]
}

onyxio_accepting_connections() {
  local port
  port="$(env_value "$INSTALL_DIR/.env" PORT)"
  port="${port:-80}"

  ( : > "/dev/tcp/127.0.0.1/${port}" ) >/dev/null 2>&1
}

ensure_onyxio() {
  if ! onyxio_container_running onyxio; then
    log "onyxio is not running; attempting to relaunch it."
    onyxio_tcp_failures=0
    run_compose up -d onyxio
    return 0
  fi

  if onyxio_accepting_connections; then
    onyxio_tcp_failures=0
    return 0
  fi

  onyxio_tcp_failures=$((onyxio_tcp_failures + 1))
  if [ "$onyxio_tcp_failures" -lt "$FAILURE_THRESHOLD" ]; then
    log "onyxio is running but not accepting connections; retry ${onyxio_tcp_failures}/${FAILURE_THRESHOLD}."
    return 1
  fi

  log "onyxio is running but not accepting connections; restarting it."
  onyxio_tcp_failures=0
  run_compose restart onyxio || run_compose up -d onyxio
}

watch_once() {
  if ! command -v docker >/dev/null 2>&1; then
    log "Docker is not available yet."
    return 1
  fi

  if [ ! -f "$INSTALL_DIR/docker-compose.yml" ] || [ ! -f "$INSTALL_DIR/.env" ]; then
    log "Onyxio install files are not available at ${INSTALL_DIR}."
    return 1
  fi

  cd "$INSTALL_DIR"
  ensure_onyxio
}

if [ "${1:-}" = "--once" ]; then
  FAILURE_THRESHOLD="${ONYXIO_WATCHDOG_FAILURE_THRESHOLD:-1}"
  watch_once
  exit $?
fi

log "Onyxio watchdog started."
while true; do
  watch_once || true
  sleep "$CHECK_INTERVAL_SECONDS"
done
