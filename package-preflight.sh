#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

MODE="offline"
if [ "${1:-}" = "--mode" ]; then
  MODE="${2:-offline}"
fi

WARNINGS=0
FAILURES=0

info() {
  printf '  - %s\n' "$1"
}

pass() {
  printf '[PASS] %s\n' "$1"
}

warn() {
  WARNINGS=$((WARNINGS + 1))
  printf '[WARN] %s\n' "$1"
}

fail() {
  FAILURES=$((FAILURES + 1))
  printf '[FAIL] %s\n' "$1"
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

compose() {
  if docker compose version >/dev/null 2>&1; then
    docker compose "$@"
  elif command -v docker-compose >/dev/null 2>&1; then
    docker-compose "$@"
  else
    return 127
  fi
}

compose_services_running() {
  [ -f docker-compose.yml ] || return 1
  [ -n "$(compose ps -q 2>/dev/null || true)" ]
}

valid_port() {
  local value="$1"
  [[ "$value" =~ ^[0-9]+$ ]] && [ "$value" -ge 1 ] && [ "$value" -le 65535 ]
}

port_enabled() {
  local value="$1"
  case "$(printf '%s' "${value:-}" | tr '[:upper:]' '[:lower:]')" in
    '' | 0 | false | disabled | none | off)
      return 1
      ;;
    *)
      return 0
      ;;
  esac
}

casting_enabled() {
  case "$(printf '%s' "$(env_value .env CASTING_ENABLED)" | tr '[:upper:]' '[:lower:]')" in
    false | 0 | disabled | none | off)
      return 1
      ;;
    *)
      return 0
      ;;
  esac
}

port_is_listening() {
  local port="$1"
  if command -v lsof >/dev/null 2>&1; then
    lsof -nP -iTCP:"$port" -sTCP:LISTEN >/dev/null 2>&1
    return $?
  fi
  if command -v ss >/dev/null 2>&1; then
    if ss -ltnH 2>/dev/null | awk '{ print $4 }' | grep -Eq "(^|[.:])${port}$"; then
      return 0
    fi
    return 1
  fi
  if command -v netstat >/dev/null 2>&1; then
    if netstat -an 2>/dev/null | grep -E "LISTEN|LISTENING" | grep -Eq "[.:]${port}[[:space:]]"; then
      return 0
    fi
    return 1
  fi
  return 1
}

host_ips() {
  {
    hostname -I 2>/dev/null | tr ' ' '\n' || true
    if command -v ip >/dev/null 2>&1; then
      ip -o -4 addr show scope global 2>/dev/null | awk '{ split($4, parts, "/"); print parts[1] }'
    fi
    if command -v ifconfig >/dev/null 2>&1; then
      ifconfig 2>/dev/null | awk '/inet / { print $2 }'
    fi
  } | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' | sort -u || true
}

ip_is_available() {
  local ip="$1"
  [ "$ip" = "0.0.0.0" ] && return 0
  [ "$ip" = "127.0.0.1" ] && return 0
  host_ips | grep -Fxq "$ip"
}

https_requested() {
  bool_true "$(env_value .env ONYXIO_ENABLE_HTTPS)" &&
    [ -n "$(env_value .env HTTPS_HOST)" ]
}

tls_certificates_available() {
  [ -s data/tls/fullchain.pem ] && [ -s data/tls/privkey.pem ]
}

check_required_files() {
  [ -f .env ] && pass ".env exists" || fail ".env is missing"
  [ -f docker-compose.yml ] && pass "docker-compose.yml exists" || fail "docker-compose.yml is missing"

  if [ "$MODE" = "offline" ]; then
    if find images -name '*.tar' -type f -print -quit 2>/dev/null | grep -q .; then
      pass "offline Docker image tarballs exist"
    else
      fail "offline package is missing images/*.tar"
    fi
  fi

  if https_requested; then
    [ -f docker-compose.https.yml ] && pass "HTTPS compose overlay exists" || fail "docker-compose.https.yml is missing"
    [ -f nginx/onyxio-https.conf.template ] &&
      pass "nginx HTTPS template exists" ||
      fail "nginx/onyxio-https.conf.template is missing"
  fi
}

check_docker() {
  if ! command -v docker >/dev/null 2>&1; then
    fail "Docker is not installed"
    return
  fi
  pass "Docker CLI exists"

  if docker info >/dev/null 2>&1; then
    pass "Docker daemon is running"
  else
    fail "Docker daemon is not reachable"
  fi

  if compose version >/dev/null 2>&1; then
    pass "Docker Compose is available"
  else
    fail "Docker Compose is not available"
  fi
}

check_disk_space() {
  local min_mb available_kb available_mb
  min_mb="${ONYXIO_PREFLIGHT_MIN_FREE_MB:-4096}"
  available_kb="$(df -Pk . 2>/dev/null | awk 'NR == 2 { print $4 }')"
  if [ -z "$available_kb" ]; then
    warn "Could not determine free disk space"
    return
  fi

  available_mb=$((available_kb / 1024))
  if [ "$available_mb" -lt "$min_mb" ]; then
    fail "free disk space is ${available_mb} MB; at least ${min_mb} MB is recommended"
  else
    pass "free disk space is ${available_mb} MB"
  fi
}

check_ip_setting() {
  local label="$1"
  local ip="$2"

  if [ -z "$ip" ]; then
    warn "${label} is not configured"
    return
  fi

  if ip_is_available "$ip"; then
    pass "${label} ${ip} is available on this host"
  else
    fail "${label} ${ip} is not assigned to this host"
    info "Available host IPv4 addresses: $(host_ips | tr '\n' ' ')"
  fi
}

check_port() {
  local label="$1"
  local value="$2"
  local existing_services="${3:-false}"

  if ! port_enabled "$value"; then
    pass "${label} port is disabled"
    return
  fi

  if ! valid_port "$value"; then
    fail "${label} port '${value}' is invalid"
    return
  fi

  if port_is_listening "$value"; then
    if [ "$existing_services" = "true" ]; then
      warn "${label} port ${value} is already listening; this can be normal during an update"
    else
      fail "${label} port ${value} is already in use"
    fi
    return
  fi

  pass "${label} port ${value} is available"
}

check_network_and_ports() {
  local server_ip https_addr existing_services
  server_ip="$(env_value .env SERVER_IP)"
  https_addr="$(env_value .env HTTPS_LISTEN_ADDR)"
  existing_services="false"
  if compose_services_running; then
    existing_services="true"
  fi

  check_ip_setting "SERVER_IP" "$server_ip"

  check_port "Backend HTTP" "$(env_value .env PORT)" "$existing_services"
  check_port "WebSocket" "$(env_value .env WEB_SOCKET_PORT)" "$existing_services"
  check_port "Philips WebServices" "$(env_value .env PHILIPS_WEBSERVICES_PORT)" "$existing_services"
  check_port "Philips bootstrap WebServices" "$(env_value .env PHILIPS_WEBSERVICES_BOOTSTRAP_PORT)" "$existing_services"
  check_port "Postgres localhost" "$(env_value .env POSTGRES_PORT)" "$existing_services"

  if casting_enabled; then
    check_port "Cast proxy DIAL HTTP" "8008" "$existing_services"
    check_port "Cast proxy Cast V2" "8009" "$existing_services"
    check_port "Cast proxy DIAL HTTPS" "8443" "$existing_services"
    info "Casting also requires UDP mDNS 5353 and SSDP 1900 on the selected guest interface."
  fi

  if https_requested; then
    check_ip_setting "HTTPS_LISTEN_ADDR" "${https_addr:-$server_ip}"
    if tls_certificates_available; then
      check_port "HTTPS proxy" "$(env_value .env HTTPS_PORT)" "$existing_services"
    else
      warn "HTTPS is configured, but data/tls/fullchain.pem or data/tls/privkey.pem is missing"
      info "Onyxio will start without the HTTPS proxy until certificates are placed in ./data/tls."
    fi
  fi
}

check_urls() {
  local public_url mobile_url
  public_url="$(env_value .env PUBLIC_SERVER_URL)"
  mobile_url="$(env_value .env MOBILE_APP_PUBLIC_URL)"

  case "$public_url" in
    http://* | https://*)
      pass "PUBLIC_SERVER_URL is set"
      ;;
    *)
      warn "PUBLIC_SERVER_URL is missing or does not start with http:// or https://"
      ;;
  esac

  if https_requested; then
    case "$mobile_url" in
      https://*)
        pass "MOBILE_APP_PUBLIC_URL is HTTPS"
        ;;
      *)
        warn "MOBILE_APP_PUBLIC_URL should be HTTPS when the HTTPS front door is configured"
        ;;
    esac
  fi
}

echo "Running Onyxio preflight checks..."
echo
check_required_files
check_docker
check_disk_space
check_network_and_ports
check_urls
echo

if [ "$FAILURES" -gt 0 ]; then
  echo "Preflight failed with ${FAILURES} failure(s) and ${WARNINGS} warning(s)." >&2
  echo "Fix the failures above and run ./install.sh again." >&2
  exit 1
fi

if [ "$WARNINGS" -gt 0 ]; then
  echo "Preflight passed with ${WARNINGS} warning(s)."
else
  echo "Preflight passed."
fi
