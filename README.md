# Onyxio Installer

Public installer endpoint for internet-connected Onyxio servers.

Install Onyxio:

```bash
curl -fsSL https://install.onyxio.com.au | sudo bash
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
```

Example:

```bash
curl -fsSL https://install.onyxio.com.au | sudo env \
  ONYXIO_VERSION=2026.07.12 \
  ONYXIO_REGISTRY_USERNAME=YOUR_GITHUB_USERNAME \
  ONYXIO_REGISTRY_TOKEN=TOKEN \
  SERVER_IP=192.168.85.2 \
  bash
```

The installer creates:

- `/opt/onyxio/docker-compose.yml`
- `/opt/onyxio/.env`
- `/opt/onyxio/data/postgres`
- `/opt/onyxio/data/uploads`
- `/opt/onyxio/data/uploads/license`

The server receives Docker images only. It does not receive Onyxio source code.

After install, put the Onyxio license public key at `/opt/onyxio/data/uploads/license/public-key.pem`, open Admin > Settings > License, copy the installation ID, and upload the signed license. TV and mobile apps stay locked until the license is valid.
