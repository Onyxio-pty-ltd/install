# Onyxio Installer

Public installer endpoint for internet-connected Onyxio servers.

## Host prerequisites

The online commands below (`install.sh`, the root URL, and `ops-install.sh`)
automatically download missing Docker Engine and Compose packages on Ubuntu
using `apt-get`. This includes Ubuntu 26.04 (Resolute). They enable the Ubuntu
Universe repository when necessary and start Docker through systemd if its
daemon is stopped. Existing working Docker and Compose installations are reused.
If only Compose is missing, the engine is left installed and only the missing
plugin is added; package removal is disabled.

This is an internet installation: host packages come from package repositories,
and application images are pulled from container registries. No Docker packages
are embedded into the Onyxio application image or an offline bundle by this step.
The server needs outbound access to those repositories and registries. On other
operating systems, install Docker Engine and Compose before running the installer.
The separate `package-install.sh` and `package-install-online.sh` bundle entry
points still require Docker to be installed beforehand.

To install the prerequisites manually on a fresh Ubuntu 26.04 server:

```bash
sudo apt-get update
sudo apt-get install -y docker.io docker-compose-v2
sudo systemctl enable --now docker
sudo docker info
sudo docker compose version
```

Install Onyxio:

```bash
curl -fsSL https://install.onyxio.com.au | sudo bash
```

Install the cloud control plane on a cloud VM:

```bash
curl -fsSL https://install.onyxio.com.au | sudo env \
  ONYXIO_DEPLOYMENT=cloud \
  PUBLIC_SERVER_URL=https://cloud.example.com \
  bash
```

Install the cloud-only management console:

```bash
curl -fsSL https://install.onyxio.com.au/ops-install.sh | sudo env \
  PUBLIC_URL=https://console.example.com \
  bash
```

Uninstall Onyxio:

```bash
curl -fsSL https://install.onyxio.com.au/uninstall.sh | sudo bash
```

Upgrade Onyxio:

```bash
curl -fsSL https://install.onyxio.com.au/upgrade.sh | sudo env ONYXIO_VERSION=2026.08.15 bash
```

Install or update a casting host for cloud-managed properties:

```bash
curl -fsSL https://install.onyxio.com.au/install-casting-host.sh | sudo env \
  CASTING_CONTROL_PLANE_WS_URL=wss://cloud.example.com \
  CASTING_HOST_ID=property-a-east \
  CASTING_HOST_NAME="Property A East" \
  CASTING_HOST_SITE_ID=site-1 \
  CASTING_HOST_TOKEN=shared-secret \
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
ONYXIO_DEPLOYMENT=cloud
SERVER_IP=192.168.85.2
PUBLIC_SERVER_URL=https://cloud.example.com
ONYXIO_ENABLE_HTTPS=true
HTTPS_HOST=remote.example-hotel.com
HTTPS_LISTEN_ADDR=172.20.0.10
HTTPS_PORT=443
CASTING_HOST_TOKEN=...
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
- `/opt/onyxio/network-agent` for on-prem installs
- `/opt/onyxio/data/postgres`
- `/opt/onyxio/data/uploads`
- `/opt/onyxio/data/uploads/license`
- `/opt/onyxio/data/tls`

The server receives Docker images only. It does not receive Onyxio source code.

## Management Console Installs

`ops-install.sh` installs the internal management console as a cloud-only
stack. It writes a Docker Compose file with the app and Postgres, creates the
production license-signing private key under the install directory, and always
sets the cloud flags that disable on-prem services.

```bash
curl -fsSL https://install.onyxio.com.au/ops-install.sh | sudo env \
  PUBLIC_URL=https://console.example.com \
  ONYXIO_MANAGEMENT_VERSION=latest \
  ONYXIO_REGISTRY_USERNAME=YOUR_GITHUB_USERNAME \
  ONYXIO_REGISTRY_TOKEN=TOKEN \
  bash
```

Optional variables:

```bash
ONYXIO_INSTALL_DIR=/opt/onyxio-management
ONYXIO_MANAGEMENT_VERSION=latest
ONYXIO_MANAGEMENT_IMAGE=ghcr.io/onyxio-pty-ltd/management:latest
ONYXIO_POSTGRES_IMAGE=postgres:15
PORT=8081
POSTGRES_PORT=5433
ONYXIO_ENABLE_HTTPS=true
HTTPS_HOST=console.example.com
HTTPS_LISTEN_ADDR=0.0.0.0
HTTPS_PORT=8443
ONYXIO_SKIP_WATCHDOG=true
```

Ops can run alongside the Onyxio platform on the same host. Its default host
ports are HTTP `8081`, loopback Postgres `5433`, and optional HTTPS `8443`;
the platform uses `80`, `5432`, and `443`. Set `PORT`, `POSTGRES_PORT`, or
`HTTPS_PORT` if another service already occupies an Ops port. The app still uses
host networking, so each listener needs a distinct host port. Each stack has
its own install directory, Compose project, database data, and watchdog service.

For `https://support.onyxio.app` on standard port `443`, configure the host's
existing reverse proxy to route that hostname to `http://127.0.0.1:8081`.
Forward HTTP requests and WebSocket upgrades to that same upstream port; there
is no separate WebSocket port. The bundled Ops proxy already forwards the
`Upgrade` and `Connection` headers to the app's `PORT`.
Leave `ONYXIO_ENABLE_HTTPS` unset when that proxy handles TLS. For direct access
through the optional Ops HTTPS proxy, use an explicit port in the public URL,
such as `https://support.onyxio.app:8443`, and provide its TLS certificates.
The installer does not configure hostname routing in an existing proxy.

For an installation created with the old defaults, update its existing config
and recreate the management containers. This preserves credentials and data:

```bash
cd /opt/onyxio-management
sudo cp -p .env .env.before-port-change
sudo sed -i \
  -e 's/^PORT=.*/PORT=8081/' \
  -e 's/^POSTGRES_PORT=.*/POSTGRES_PORT=5433/' \
  -e '/^DATABASE_URL=/s/@127\.0\.0\.1:[0-9]*\//@127.0.0.1:5433\//' \
  -e 's/^HTTPS_PORT=.*/HTTPS_PORT=8443/' \
  .env
sudo docker compose -f docker-compose.yml up -d
```

If the Ops HTTPS proxy is enabled and its certificates are installed, include
`-f docker-compose.https.yml` before `up -d`. If installation previously failed
before startup completed, this recovery starts the containers but does not
install the watchdog service that the installer normally creates afterward.

To uninstall management, run `sudo /opt/onyxio-management/uninstall.sh`. Its
confirmation phrase is `uninstall onyxio-management`; the platform uninstaller
continues to require `uninstall onyxio`. Management installs in custom directories
are identified from their `.env` metadata. The installed wrapper downloads the
shared uninstaller on each run.

For emailed team invitations, pass these additional variables to `sudo env`:

```bash
EMAIL_PROVIDER=smtp
EMAIL_FROM='Onyxio <no-reply@example.com>'
SMTP_HOST=smtp.example.com
SMTP_PORT=587
SMTP_SECURE=false
SMTP_USER=YOUR_SMTP_USERNAME
SMTP_PASSWORD='YOUR_SMTP_PASSWORD'
```

The installer saves these settings and `PUBLIC_URL` in its private `.env` file.
`PUBLIC_URL` is the single public address for the management console and links
in password setup emails, mentions, and project notifications.
SMTP requires a host and sender address, plus credentials if your mail server
requires authentication. If `EMAIL_PROVIDER` is omitted, the app selects SMTP
when `SMTP_HOST` is supplied; otherwise email is disabled in production. If
`SMTP_SECURE` is omitted, the app enables implicit TLS for port 465 and uses
STARTTLS when offered on other ports (587 by default). Without SMTP, enter a
password manually when adding a team member.

For an existing installation, keep `PUBLIC_URL` set to the console address and
remove the old `PUBLIC_SERVER_URL` and `PUBLIC_APP_URL` entries from
`/opt/onyxio-management/.env`. Add the email settings as needed, then run
`docker compose up -d onyxio` from that directory to recreate the app container. Use your chosen install directory if
different. The installer only supports fresh installations.

The Ops repo's `.github/workflows/ci.yml` builds and publishes the management
image after tests and a container smoke test pass. Its Dockerfile installs
dependencies from the current backend lockfile (including `nodemailer`), builds
the frontend, and includes `/app/shared/projectKey.mts` for the backend's runtime
import. See the Ops README for release tags and publishing controls.

This installer has no on-prem mode. It does not install a host network agent,
casting host, TV/mobile app URLs, Philips WebServices, or license public-key
assets for customer servers.

## Connecting Ops to Cloud customers on a fresh install

The Ops **Cloud customers** page fetches organizations live from the platform.
Install platform and Ops image versions that contain the customer management API
and Cloud customers page, respectively.

Generate one random monitoring key and use the same value for both installations:

```bash
openssl rand -hex 32
```

For a new cloud platform installation:

```bash
curl -fsSL https://install.onyxio.com.au | sudo env \
  ONYXIO_DEPLOYMENT=cloud \
  PUBLIC_SERVER_URL=https://cloud.example.com \
  ONYXIO_CUSTOMER_MANAGEMENT_API_KEY=YOUR_GENERATED_KEY \
  bash
```

For a new Ops installation:

```bash
curl -fsSL https://install.onyxio.com.au/ops-install.sh | sudo env \
  PUBLIC_URL=https://ops.example.com \
  ONYXIO_CLOUD_PLATFORM_URL=https://cloud.example.com \
  ONYXIO_CLOUD_PLATFORM_API_KEY=YOUR_GENERATED_KEY \
  bash
```

Replace `YOUR_GENERATED_KEY` with the generated value in each command. The
platform key must contain at least 32 characters. `PUBLIC_URL` is the Ops
console's address; `ONYXIO_CLOUD_PLATFORM_URL` is the platform origin without an
API path, query, or credentials. Use HTTPS for remote connections and ensure the
Ops server can reach that address. No extra monitoring port is required.

| Installer | Optional environment variables | Default |
| --- | --- | --- |
| Platform (`install.sh`, public root installer, online/offline package installers) | `ONYXIO_CUSTOMER_MANAGEMENT_API_KEY` | Blank; monitoring API disabled |
| Ops (`ops-install.sh`) | `ONYXIO_CLOUD_PLATFORM_URL`, `ONYXIO_CLOUD_PLATFORM_API_KEY` | Blank; Cloud customers connection unconfigured |

The installers save these values in their generated `.env` files with mode
`0600`, and Compose passes them to the backends. For package installs, supply the
platform key in the environment when running the package's installer. Keys are
not generated automatically or printed by the installers. Keep them out of Git
and frontend/Vite settings. Each key grants installation-wide monitoring access;
use a different key for each platform installation.

After installation, sign in to Ops and open **Cloud customers**. It fetches up to
25 organizations per page through the Ops backend, with Previous, Next and Refresh
controls. Ops does not store copies of platform organizations or synchronize them
in the background. The first version connects to one cloud platform.

## Customer support from the admin panel

Install Platform and Ops image versions containing the customer support feature.
The form is hosted by Ops at `/support/new`, using the same public origin as the
Ops console. Both the Platform backend and the customer's browser must be able
to reach that origin over HTTPS. No new inbound port or container is required.

Generate a dedicated support token with `openssl rand -hex 32`. Keep it separate
from monitoring credentials and license keys. Configure the same value on both
backends; the installers do not generate or register support tokens automatically.

For a fresh cloud Platform installation, include these variables alongside your
usual installer settings:

```bash
curl -fsSL https://install.onyxio.com.au | sudo env \
  ONYXIO_DEPLOYMENT=cloud \
  PUBLIC_SERVER_URL=https://cloud.example.com \
  ONYXIO_SUPPORT_URL=https://ops.example.com \
  ONYXIO_SUPPORT_TOKEN=YOUR_GENERATED_SUPPORT_TOKEN \
  bash
```

For a fresh Ops installation:

```bash
curl -fsSL https://install.onyxio.com.au/ops-install.sh | sudo env \
  PUBLIC_URL=https://ops.example.com \
  SUPPORT_INTEGRATIONS='[{"id":"cloud-production","kind":"cloud","token":"YOUR_GENERATED_SUPPORT_TOKEN"}]' \
  SUPPORT_REPLY_TO=support@example.com \
  SUPPORT_INBOX=tickets@example.com \
  bash
```

Replace both token placeholders with the same generated value. Configure the
existing `EMAIL_PROVIDER`, `EMAIL_FROM`, and `SMTP_*` settings in Ops for email
receipts and internal notifications. Tickets can be created without SMTP.

| Installer | Optional environment variables | Default |
| --- | --- | --- |
| Platform (`install.sh`, public root installer, online/offline package installers) | `ONYXIO_SUPPORT_URL`, `ONYXIO_SUPPORT_TOKEN` | Blank; support launches disabled |
| Ops (`ops-install.sh`) | `SUPPORT_INTEGRATIONS`, `SUPPORT_REPLY_TO`, `SUPPORT_INBOX` | Empty integration list and blank mailboxes |

For a package install, pass the same Platform variables when running its
installer. Fresh Platform installs reject incomplete URL/token pairs, tokens
shorter than 32 characters, and URLs containing credentials, paths, queries, or
fragments. HTTP is accepted only for `localhost` or `127.0.0.1` development.
Ops validates integration JSON and credential fields when its backend starts.
The installers quote these settings for Compose and save them in `.env` with
mode `0600`. Keep tokens out of Git and frontend/Vite variables.

### On-prem provisioning and site identity

Use a different token for each on-prem installation. Add an entry to the Ops
`SUPPORT_INTEGRATIONS` array alongside any existing entries:

```json
{"id":"hotel-installation","kind":"on-prem","clientId":"OPS_CLIENT_ID","installationId":"PLATFORM_INSTALLATION_ID","token":"UNIQUE_SUPPORT_TOKEN_FOR_THIS_INSTALLATION"}
```

Use the actual installation ID from Platform **Admin > Settings > License** (or
the `ONYXIO_INSTALLATION_ID` supplied during installation). Register the Platform
site IDs under the matching client and installation in Ops for site-specific
support. General requests using **No specific site** only require the registered
client and installation. Set that installation's `ONYXIO_SUPPORT_URL` and
`ONYXIO_SUPPORT_TOKEN` to the Ops origin and its dedicated token. A license or installation ID alone
does not authorize support access.

When a customer opens **Contact support**, they can select a site or choose
**No specific site**. Platform verifies their organization membership and any
selected site. Ops uses the registered installation/site mapping for on-prem
requests and the verified organization/site context for cloud requests.

### Enabling existing installations

Update the installed backend `.env` files; rerunning a fresh installer is not an
upgrade. In `/opt/onyxio/.env` (or the package installation directory), add:

```dotenv
ONYXIO_SUPPORT_URL=https://ops.example.com
ONYXIO_SUPPORT_TOKEN=YOUR_GENERATED_SUPPORT_TOKEN
```

In `/opt/onyxio-management/.env`, set `PUBLIC_URL` to that same Ops origin and add
the matching `SUPPORT_INTEGRATIONS` JSON array and optional mailbox settings.
Keep the JSON on one line, surrounded by single quotes as in the command above;
merge new entries into any existing array. Use generated hexadecimal tokens to
avoid Compose interpolation in manually edited values.

After upgrading both images to releases containing support, recreate each
backend container from its installation directory with `docker compose up -d
--force-recreate onyxio`. Package installs use the service name `platform`.
If HTTPS is enabled, retain the existing Compose overlays, for example:
`docker compose -f docker-compose.yml -f docker-compose.https.yml up -d
--force-recreate onyxio`. A container restart alone does not reload `.env`.

`upgrade.sh` preserves existing support settings, including tokens. It does not
enable support on unconfigured installations or replace saved credentials with
values from the shell running the upgrade. After provisioning, refresh the admin
panel and submit a test ticket for a known site to verify its identity in Ops.

## Cloud Control Plane Installs

The same full installer can run the hosted cloud backend when
`ONYXIO_DEPLOYMENT=cloud` or `ONYXIO_CLOUD_MODE=true` is provided. In cloud
mode the installer writes the cloud flags into `/opt/onyxio/.env`, uses
`PUBLIC_SERVER_URL` for the admin, TV, and mobile app URLs, disables local
casting, and disables host network changes from the backend. Philips WebServices
defaults to enabled in both cloud and on-premise installs; set
`PHILIPS_WEBSERVICES_ENABLED=false` explicitly to disable it. Upgrades preserve
the existing value and default to `true` when the setting is absent. Existing
cloud installs created with `false` must change that value to `true` in
`/opt/onyxio/.env` and recreate the backend container to enable WebServices.

Cloud installs should provide a public HTTP(S) URL:

```bash
curl -fsSL https://install.onyxio.com.au | sudo env \
  ONYXIO_VERSION=2026.08.15 \
  ONYXIO_DEPLOYMENT=cloud \
  PUBLIC_SERVER_URL=https://cloud.example.com \
  ONYXIO_REGISTRY_USERNAME=YOUR_GITHUB_USERNAME \
  ONYXIO_REGISTRY_TOKEN=TOKEN \
  bash
```

This install still uses the bundled Docker Compose Postgres service, so it is
best suited to a single-VM cloud control plane. Property LAN casting still uses
the separate casting-host install below.

## On-Prem Casting Bridges

Full on-prem installs no longer start a fixed `casting-host` Docker Compose
service. Open Admin > Settings > Casting and use Add casting bridge to create
or remove local property-network casting bridge processes. The backend starts
those bridge processes with a localhost control-plane websocket and the shared
`CASTING_HOST_TOKEN` from `/opt/onyxio/.env`.

The on-prem Network tab still configures backend host interfaces and HTTPS.
Casting bridge network settings live on each bridge in Admin > Settings >
Casting.

## Casting Host Installs

Casting-host-only property installs use `install-casting-host.sh` from this
repository as the single installer/updater. The casting host package runs the
same backend image as the full product, but starts only the shared casting
runtime command and writes its files under `/opt/onyxio-casting-host` by
default.
It starts the casting runtime immediately and reports the installed
`ONYXIO_VERSION` as the casting module version unless `CASTING_HOST_VERSION` is
set explicitly.

Required values:

```bash
CASTING_CONTROL_PLANE_WS_URL=wss://cloud.example.com
CASTING_HOST_ID=property-a-east
CASTING_HOST_NAME="Property A East"
CASTING_HOST_SITE_ID=site-1
CASTING_HOST_TOKEN=shared-secret
```

The casting host reports detected property-network interfaces to the control
plane. The backend assigns it to the reported site, derives its organization,
and sends that site's current mapping. Select the guest and device roles in
Admin > Settings > Casting; those settings are sent back to the host over the
casting control websocket. The casting host also installs the local
`onyxio-network-agent.service` so network changes requested from Admin are
applied on the property-network machine, not by the cloud backend.
Create the site first and use its actual ID. Each site accepts one module;
registration rejects conflicting assignments. When moving a module in Admin,
update `CASTING_HOST_SITE_ID` in its environment before restarting it.

Re-run the same command with a new `ONYXIO_VERSION` or `ONYXIO_SERVER_IMAGE` to
update the casting host:

```bash
curl -fsSL https://install.onyxio.com.au/install-casting-host.sh | sudo env \
  ONYXIO_VERSION=2026.08.15 \
  CASTING_CONTROL_PLANE_WS_URL=wss://cloud.example.com \
  CASTING_HOST_ID=property-a-east \
  CASTING_HOST_NAME="Property A East" \
  CASTING_HOST_SITE_ID=site-1 \
  CASTING_HOST_TOKEN=shared-secret \
  bash
```

To remove a casting-host-only install:

```bash
curl -fsSL https://install.onyxio.com.au/uninstall.sh | sudo env \
  ONYXIO_INSTALL_DIR=/opt/onyxio-casting-host \
  ONYXIO_UNINSTALL_CONFIRM=true \
  bash
```

Set each casting module's public URL in Admin > Settings > Casting when a
property needs a bridge-specific reachable URL. TV QR codes use the HTTPS URL
from Admin > Settings > Network first, then fall back to the guest-network
address reported by the casting module assigned to the device site; the host
receives pairing mappings and network commands over WebSocket.

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
casting host install/update entry points used by target servers.

Platform deployment packages also copy package-specific installer entry points
from this repository:

- `package-install.sh` for offline image bundles
- `package-install-online.sh` for online registry-pull bundles
- `package-preflight.sh` for packaged full-server checks
- `uninstall.sh`, `network-agent.py`, `watchdog.sh`, and `install-casting-host.sh`
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
Network. It will look like:

```bash
sudo /opt/onyxio/bin/enable-https \
  --host remote.example-hotel.com \
  --listen-address 172.20.0.10 \
  --port 443
```

The HTTPS URL configured in Admin > Settings > Network is used for mobile and
casting pairing links when present. If no HTTPS URL is configured, casting QR
codes fall back to the guest-network IP reported by the casting bridge assigned
to the device site. Unassigned devices do not get casting QR codes.

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

Upgrades preserve existing port and URL settings in `.env`, including `PORT`,
`WEB_SOCKET_PORT`, `PHILIPS_WEBSERVICES_PORT`, and
`PHILIPS_WEBSERVICES_BOOTSTRAP_PORT`.

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
