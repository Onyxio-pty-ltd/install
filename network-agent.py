#!/usr/bin/env python3
import ipaddress
import json
import os
import re
import subprocess
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path


HOST = os.environ.get("ONYXIO_NETWORK_AGENT_HOST", "127.0.0.1")
PORT = int(os.environ.get("ONYXIO_NETWORK_AGENT_PORT", "8097"))
NETPLAN_FILE = Path(os.environ.get("ONYXIO_NETPLAN_FILE", "/etc/netplan/99-onyxio.yaml"))
LEGACY_NETPLAN_FILE = Path(
    os.environ.get("ONYXIO_NETPLAN_LEGACY_FILE", "/etc/netplan/90-onyxio-managed.yaml")
)
MAX_BODY_BYTES = 1_000_000
INTERFACE_NAME_PATTERN = re.compile(r"^[A-Za-z0-9_.-]{1,15}$")


def json_response(handler, status, payload):
    body = json.dumps(payload).encode("utf-8")
    handler.send_response(status)
    handler.send_header("Content-Type", "application/json")
    handler.send_header("Content-Length", str(len(body)))
    handler.end_headers()
    handler.wfile.write(body)


def run(command, timeout=60):
    completed = subprocess.run(command, text=True, capture_output=True, timeout=timeout)
    if completed.returncode != 0:
        message = completed.stderr.strip() or completed.stdout.strip() or "command failed"
        raise RuntimeError(f"{' '.join(command)} failed: {message}")
    return completed.stdout


def read_previous_config():
    if not NETPLAN_FILE.exists():
        return None
    return NETPLAN_FILE.read_text(encoding="utf-8")


def write_netplan_config(content):
    NETPLAN_FILE.parent.mkdir(parents=True, exist_ok=True)
    tmp_path = NETPLAN_FILE.with_name(f"{NETPLAN_FILE.name}.tmp")
    tmp_path.write_text(content, encoding="utf-8")
    tmp_path.chmod(0o600)
    tmp_path.replace(NETPLAN_FILE)
    NETPLAN_FILE.chmod(0o600)
    if LEGACY_NETPLAN_FILE.exists():
        LEGACY_NETPLAN_FILE.chmod(0o600)


def remove_netplan_config():
    try:
        NETPLAN_FILE.unlink()
    except FileNotFoundError:
        pass


def apply_netplan():
    run(["netplan", "generate"])
    run(["netplan", "apply"], timeout=120)


def rollback(previous_config):
    if previous_config is None:
        remove_netplan_config()
    else:
        write_netplan_config(previous_config)
    apply_netplan()


def get_ipv4_addresses(interface_name):
    try:
        output = run(["ip", "-j", "-4", "addr", "show", "dev", interface_name], timeout=10)
    except RuntimeError:
        return []
    parsed = json.loads(output or "[]")
    addresses = []
    for interface in parsed:
        for info in interface.get("addr_info", []):
            if info.get("family") != "inet":
                continue
            local = info.get("local")
            prefixlen = info.get("prefixlen")
            if local is None or prefixlen is None:
                continue
            addresses.append(f"{local}/{prefixlen}")
    return addresses


def target_is_ready(target):
    addresses = get_ipv4_addresses(target["interfaceName"])
    if target["mode"] == "dhcp":
        return len(addresses) > 0
    return target["address"] in addresses


def wait_for_targets(targets, timeout_ms, poll_ms):
    deadline = time.monotonic() + timeout_ms / 1000
    missing = list(targets)
    while True:
        missing = [target for target in missing if not target_is_ready(target)]
        if not missing:
            return
        if time.monotonic() >= deadline:
            formatted = ", ".join(format_target(target) for target in missing)
            raise RuntimeError(f"connectivity targets did not appear: {formatted}")
        time.sleep(max(poll_ms, 100) / 1000)


def format_target(target):
    if target["mode"] == "dhcp":
        return f"{target['interfaceName']} dhcp"
    return f"{target['interfaceName']} {target['address']}"


def validate_payload(payload):
    yaml = payload.get("yaml")
    if not isinstance(yaml, str) or not yaml.strip():
        raise ValueError("yaml is required")
    if len(yaml.encode("utf-8")) > MAX_BODY_BYTES:
        raise ValueError("yaml is too large")

    targets = payload.get("targets")
    if not isinstance(targets, list):
        raise ValueError("targets must be a list")
    for target in targets:
        if not isinstance(target, dict):
            raise ValueError("targets must contain objects")
        interface_name = target.get("interfaceName")
        if not isinstance(interface_name, str) or not INTERFACE_NAME_PATTERN.match(interface_name):
            raise ValueError("target interfaceName is invalid")
        mode = target.get("mode")
        if mode == "static":
            try:
                ipaddress.ip_interface(target.get("address", ""))
            except ValueError as error:
                raise ValueError("target static address is invalid") from error
        elif mode != "dhcp":
            raise ValueError("target mode must be static or dhcp")

    rollback_timeout_ms = parse_int(payload.get("rollbackTimeoutMs"), 120_000)
    connectivity_poll_ms = parse_int(payload.get("connectivityPollMs"), 2_000)
    if rollback_timeout_ms < 0 or rollback_timeout_ms > 600_000:
        raise ValueError("rollbackTimeoutMs must be between 0 and 600000")
    if connectivity_poll_ms < 100 or connectivity_poll_ms > 30_000:
        raise ValueError("connectivityPollMs must be between 100 and 30000")

    return {
        "yaml": yaml,
        "targets": targets,
        "rollbackTimeoutMs": rollback_timeout_ms,
        "connectivityPollMs": connectivity_poll_ms,
    }


def parse_int(value, fallback):
    if value is None:
        return fallback
    if not isinstance(value, int):
        raise ValueError("timeout values must be integers")
    return value


def apply_network_settings(payload):
    previous_config = read_previous_config()
    try:
        write_netplan_config(payload["yaml"])
        apply_netplan()
        wait_for_targets(
            payload["targets"], payload["rollbackTimeoutMs"], payload["connectivityPollMs"]
        )
    except Exception as error:
        try:
            rollback(previous_config)
        except Exception as rollback_error:
            raise RuntimeError(
                f"{error}; rollback also failed: {rollback_error}"
            ) from rollback_error
        raise RuntimeError(f"Network settings were rolled back: {error}") from error


class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path != "/health":
            json_response(self, 404, {"ok": False, "error": "not found"})
            return
        json_response(self, 200, {"ok": True, "service": "onyxio-network-agent"})

    def do_POST(self):
        if self.path != "/apply":
            json_response(self, 404, {"applied": False, "error": "not found"})
            return

        try:
            body_size = int(self.headers.get("Content-Length", "0"))
            if body_size <= 0 or body_size > MAX_BODY_BYTES:
                raise ValueError("request body size is invalid")
            payload = json.loads(self.rfile.read(body_size).decode("utf-8"))
            validated = validate_payload(payload)
            apply_network_settings(validated)
        except ValueError as error:
            json_response(self, 400, {"applied": False, "error": str(error)})
            return
        except Exception as error:
            json_response(self, 500, {"applied": False, "error": str(error)})
            return

        json_response(self, 200, {"applied": True})

    def log_message(self, format_string, *args):
        return


if __name__ == "__main__":
    server = ThreadingHTTPServer((HOST, PORT), Handler)
    print(f"Onyxio network agent listening on http://{HOST}:{PORT}", flush=True)
    server.serve_forever()
