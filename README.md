# Onyxio Installer

Public installer endpoint for internet-connected Onyxio servers.

Install Onyxio:

```bash
curl -fsSL https://install.onyxio.com.au | sudo bash
```

Uninstall Onyxio:

```bash
curl -fsSL https://install.onyxio.com.au/uninstall.sh | sudo bash
```

Upgrade Onyxio:

```bash
curl -fsSL https://install.onyxio.com.au/upgrade.sh | sudo env ONYXIO_VERSION=2026.08.15 bash
```

Install or update a casting gateway for cloud-managed properties:

```bash
curl -fsSL https://install.onyxio.com.au/install-gateway.sh | sudo env \
  CASTING_GATEWAY_WS_URL=wss://cloud.example.com \
  CASTING_GATEWAY_SITE_ID=site-1 \
  CASTING_GATEWAY_TOKEN=shared-secret \
  bash
```

For a non-interactive lab reset:

```bash
curl -fsSL https://install.onyxio.com.au/uninstall.sh | sudo bash -s -- --yes --remove-images
```

If the container image is private, pass a registry token:

```bash
curl -fsSL https://install.onyxio.com.au | sudo env \
  ONYXIO_REGISTRY_USERNAME=YOUR_GITHUB_USERNAME \
  ONYXIO_REGISTRY_TOKEN=TOKEN \
  bash
```

Optional variables:

```bash
ONYXIO_VERSION=2026.07.12
ONYXIO_SERVER_IMAGE=ghcr.io/onyxio-pty-ltd/server:2026.07.12
ONYXIO_REGISTRY=ghcr.io
ONYXIO_REGISTRY_USERNAME=YOUR_GITHUB_USERNAME
ONYXIO_REGISTRY_TOKEN=...
ONYXIO_INSTALL_DIR=/opt/onyxio
SERVER_IP=192.168.85.2
ONYXIO_ENABLE_HTTPS=true
HTTPS_HOST=remote.example-hotel.com
HTTPS_LISTEN_ADDR=172.20.0.10
HTTPS_PORT=443
CASTING_GATEWAY_WS_URL=wss://cloud.example.com
CASTING_GATEWAY_SITE_ID=site-1
CASTING_GATEWAY_TOKEN=...
CASTING_GATEWAY_GUEST_INTERFACE_IPS=172.20.0.10/255.255.255.0
CASTING_GATEWAY_DEVICE_INTERFACE_IPS=10.10.0.10/255.255.255.0
```

Example:

```bash
curl -fsSL https://install.onyxio.com.au | sudo env \
  ONYXIO_VERSION=2026.07.12 \
  ONYXIO_REGISTRY_USERNAME=YOUR_GITHUB_USERNAME \
  ONYXIO_REGISTRY_TOKEN=TOKEN \
  SERVER_IP=192.168.85.2 \
  ONYXIO_ENABLE_HTTPS=true \
  HTTPS_HOST=remote.example-hotel.com \
  HTTPS_LISTEN_ADDR=172.20.0.10 \
  HTTPS_PORT=443 \
  bash
```

The installer creates:

- `/opt/onyxio/docker-compose.yml`
- `/opt/onyxio/docker-compose.https.yml`
- `/opt/onyxio/nginx/onyxio-https.conf.template`
- `/opt/onyxio/bin/watchdog`
- `/opt/onyxio/upgrade.sh`
- `/opt/onyxio/.env`
- `/opt/onyxio/data/postgres`
- `/opt/onyxio/data/uploads`
- `/opt/onyxio/data/uploads/license`
- `/opt/onyxio/data/tls`

The server receives Docker images only. It does not receive Onyxio source code.

## Casting Gateway Installs

Gateway-only property installs use `install-gateway.sh` from this repository as
the single installer/updater. The gateway package runs the same backend image as
the full product, but starts only the shared casting runtime command and writes
its files under `/opt/onyxio-gateway` by default.

Required values:

```bash
CASTING_GATEWAY_WS_URL=wss://cloud.example.com
CASTING_GATEWAY_SITE_ID=site-1
CASTING_GATEWAY_TOKEN=shared-secret
```

Optional interface hints limit discovery and proxy traffic to known guest and
TV/device networks:

```bash
CASTING_GATEWAY_GUEST_INTERFACE_IPS=172.20.0.10/255.255.255.0
CASTING_GATEWAY_DEVICE_INTERFACE_IPS=10.10.0.10/255.255.255.0
```

Re-run the same command with a new `ONYXIO_VERSION` or `ONYXIO_SERVER_IMAGE` to
update the gateway:

```bash
curl -fsSL https://install.onyxio.com.au/install-gateway.sh | sudo env \
  ONYXIO_VERSION=2026.08.15 \
  CASTING_GATEWAY_WS_URL=wss://cloud.example.com \
  CASTING_GATEWAY_SITE_ID=site-1 \
  CASTING_GATEWAY_TOKEN=shared-secret \
  bash
```

To remove a gateway-only install:

```bash
curl -fsSL https://install.onyxio.com.au/uninstall.sh | sudo env \
  ONYXIO_INSTALL_DIR=/opt/onyxio-gateway \
  ONYXIO_UNINSTALL_CONFIRM=true \
  bash
```

## Crash Recovery

Onyxio containers use Docker Compose `restart: unless-stopped`, so Docker will
automatically relaunch the backend if the server process exits unexpectedly.

The installer also enables `onyxio-watchdog.service`, a small host-level
watchdog that runs `/opt/onyxio/bin/watchdog`. It checks the backend service
every 30 seconds and runs `docker compose up -d onyxio` if the backend
container disappears or stops. If the container is running but the backend stops
accepting connections on `PORT`, the watchdog restarts it after three failed
checks.

Useful commands:

```bash
sudo systemctl status onyxio-watchdog.service
sudo journalctl -u onyxio-watchdog.service -f
sudo /opt/onyxio/bin/watchdog --once
```

To change the check interval:

```bash
sudo systemctl edit onyxio-watchdog.service
```

Then add:

```ini
[Service]
Environment=ONYXIO_WATCHDOG_INTERVAL_SECONDS=10
```

To change how many failed connection checks are allowed before a restart:

```ini
[Service]
Environment=ONYXIO_WATCHDOG_FAILURE_THRESHOLD=5
```

## Source Repository Boundary

The installer remains a separate repository from the source monorepos. Local
product source builds now live under the sibling `platform/` repository, while
this repository only publishes the public install, uninstall, upgrade, and
gateway install/update entry points used by target servers.

Platform deployment packages also copy package-specific installer entry points
from this repository:

- `package-install.sh` for offline image bundles
- `package-install-online.sh` for online registry-pull bundles
- `package-preflight.sh` for packaged full-server checks
- `uninstall.sh`, `network-agent.py`, `watchdog.sh`, and `install-gateway.sh`
  for shared host support

Recommended flow: generate an installation ID and license before deployment, install with `ONYXIO_INSTALLATION_ID=onyxio-...`, and upload the pre-issued signed license in Admin > Settings > License. TV and mobile apps stay locked until the license is valid.

The installer writes the bundled Onyxio license public key to
`/opt/onyxio/data/uploads/license/public-key.pem` when one is not already
present.

For ad-hoc installs, omit `ONYXIO_INSTALLATION_ID`; the backend will generate and persist an installation ID on first startup.

For mobile AI on-prem, use a real HTTPS hostname that resolves on the guest
network to the server guest IP. Put certificates at:

```text
/opt/onyxio/data/tls/fullchain.pem
/opt/onyxio/data/tls/privkey.pem
```

The installer writes nginx settings and installs a post-onboarding helper at
`/opt/onyxio/bin/enable-https`. After onboarding has applied the final
interface addresses, run the command shown in Admin Panel -> Settings ->
Interfaces. It will look like:

```bash
sudo /opt/onyxio/bin/enable-https \
  --host remote.example-hotel.com \
  --listen-address 172.20.0.10 \
  --port 443
```

Then set Admin Panel -> Settings -> Interfaces -> Mobile HTTPS URL to
`https://remote.example-hotel.com/mobile/`.

For Philips TV first-run bootstrap and cloning, add a local DNS record or DNS
override on the TV/device network:

```text
web.services.tpvision.htv -> <SERVER_IP>
```

The TV will request `http://web.services.tpvision.htv/webservices.php`, which is
served by the Onyxio WebServices API on TCP port 80.

## Upgrades

The upgrade script keeps persistent data in place, creates a Postgres backup
under `/opt/onyxio/backups`, refreshes host support files such as Compose,
HTTPS helper scripts, lifecycle wrappers, the watchdog, and the network agent, updates
`ONYXIO_VERSION` and `ONYXIO_SERVER_IMAGE` in `/opt/onyxio/.env`, pulls the new
backend image, and recreates the Onyxio container.

Pinned version:

```bash
curl -fsSL https://install.onyxio.com.au/upgrade.sh | sudo env ONYXIO_VERSION=2026.08.15 bash
```

Full image override:

```bash
curl -fsSL https://install.onyxio.com.au/upgrade.sh | sudo env \
  ONYXIO_SERVER_IMAGE=ghcr.io/onyxio-pty-ltd/server:2026.08.15 \
  bash
```

If the image is private, pass registry credentials:

```bash
curl -fsSL https://install.onyxio.com.au/upgrade.sh | sudo env \
  ONYXIO_VERSION=2026.08.15 \
  ONYXIO_REGISTRY_USERNAME=YOUR_GITHUB_USERNAME \
  ONYXIO_REGISTRY_TOKEN=TOKEN \
  bash
```

The script prints rollback commands using the previous image tag after each
upgrade. Skip the automatic database backup only when another verified backup
already exists:

```bash
curl -fsSL https://install.onyxio.com.au/upgrade.sh | sudo env \
  ONYXIO_VERSION=2026.08.15 \
  ONYXIO_SKIP_UPGRADE_BACKUP=true \
  bash
```

Host support refresh can be skipped for emergency image-only upgrades:

```bash
curl -fsSL https://install.onyxio.com.au/upgrade.sh | sudo env \
  ONYXIO_VERSION=2026.08.15 \
  ONYXIO_SKIP_HOST_REFRESH=true \
  bash
```
