# Deploying the Middle-earth service example to a DiRAC VM

Target: stock Rocky 9 VM on UW DiRAC infrastructure.

```bash
git clone <this repo> /root/middle-earth-service-example
cd /root/middle-earth-service-example
sudo ./init.sh
podman compose up -d --build
```

Then verify:

```bash
curl -k https://localhost/api/hello
# {"message":"Hello from Middle-earth!","service":"example"}

curl -k https://localhost/
# (static HTML page)
```

## What each piece does

| File | Role |
|---|---|
| `service.conf` | Single source of truth for the service account name, uid, and gid. Committed to the repo. Everything else reads from here. |
| `init.sh` | Host-level only: podman + podman-compose, firewall, the service account, SSH hardening, SELinux, dev TLS certs, `.env`. Reads `service.conf`; idempotent; safe to re-run. |
| `Dockerfile.apache` | Apache httpd 2.4 with SSL and reverse proxy modules. TLS cert/key are bind-mounted at runtime, never baked in. |
| `Dockerfile.app` | Python 3.12 + Flask/Gunicorn. Serves the API and static files. |
| `compose.yaml` | Two services: `apache` (TLS termination, static files, reverse proxy) and `app` (Python API). |
| `app/server.py` | Flask application with one API endpoint (`GET /api/hello`) and static file serving. |
| `app/static/index.html` | Static HTML page demonstrating the static-file path. |
| `apache/httpd-ssl.conf` | Apache virtual host: TLS on 443, static files from `/srv/static`, `/api/` proxied to the app container. |
| `SECRETS.md` | What must exist for TLS and how to put it there (dev and production). |

## Architecture

```
                   ┌──────────────────────────────────────────┐
  client ──443──►  │  apache (TLS termination)                │
                   │    /           → static files            │
                   │    /api/*      → proxy to app:8080       │
                   └──────────────┬───────────────────────────┘
                                  │
                   ┌──────────────▼───────────────────────────┐
                   │  app (gunicorn + flask)                   │
                   │    /api/hello → JSON response             │
                   └──────────────────────────────────────────┘
```

## Design choices

**Containers for everything.** The only things `init.sh` does on the host are
install podman, configure the firewall, create the service account, and
generate dev certs. All application logic, dependencies, and configuration
live inside the container images. This means a deployment is fully
reproducible from the repo checkout.

**Apache for TLS termination.** The Python app speaks plain HTTP on an internal
port. Apache handles TLS, serves static files directly, and reverse-proxies
API requests. This separates concerns: the app does not need to know about
certificates, and cert rotation is an Apache restart, not an app change.

**Secrets are bind-mounted, never baked in.** The TLS certificate and key are
mounted read-only into the Apache container at runtime. In development,
`init.sh` generates a self-signed pair. In production, the real cert lives on
the `/service/shire` NFS share. See `SECRETS.md` for the full story.

**Service account with fixed uid/gid.** The service account name, uid, and gid
are defined once in `service.conf` and flow into every other file — init.sh,
the Dockerfiles, and compose.yaml all read from it with no fallback defaults.
The uid/gid must match the owner of the production NFS share, which is
exported with `root_squash` — only that uid can read mode-0600 secrets. See
`SECRETS.md` for details on why this matters.

## Service identity: `service.conf`

`service.conf` is the single source of truth for the service account:

```
SVC_USER=astro-svc
SVC_UID=1725455
SVC_GID=2121725455
```

It is committed to the repo. `init.sh` reads it and writes the values into
`.env` alongside the per-host FQDN. The Dockerfiles and compose.yaml consume
these values via build args and environment variables with no hardcoded
defaults — if `service.conf` is missing or incomplete, `init.sh` exits
immediately, and running `podman compose` without a populated `.env` will
fail on the missing variables.

## Per-host configuration: `.env`

The only per-machine value is the host's own FQDN, which `compose.yaml` uses
as the Apache `ServerName` and container hostname. `init.sh` writes it (along
with the `service.conf` values) to `.env`, which podman compose reads
automatically:

```
SVC_USER=astro-svc
SVC_UID=1725455
SVC_GID=2121725455
SVC_FQDN=myhost.astro.washington.edu
```

`.env` is gitignored and must never be copied between hosts.

## VM infrastructure context

DiRAC VMs run Rocky 9 and use podman (not Docker) as the container runtime.
Key things to know:

- **podman-compose** is the compose frontend. It reads the same `compose.yaml`
  format as `docker compose`. Install it from EPEL; `init.sh` handles this.
- **podman-restart.service** must be enabled for `restart: unless-stopped` to
  survive a VM reboot. `init.sh` enables it.
- **firewalld** is the default firewall. `init.sh` opens port 443/tcp.
- **SELinux** should be enforcing. `init.sh` sets it if it finds permissive
  mode. If the service needs to write to host-mounted paths, add
  `container_file_t` context via `semanage fcontext`.
- **SSH** is hardened by `init.sh` (password auth disabled). Access is by key
  only.
- **Service accounts** exist because the NFS share uses `root_squash`. The
  container process must run as the uid that owns the secrets on the share.
  `init.sh` creates this account on the host so the ids are available for
  `podman compose`.

## Rollout to another VM

The procedure above is the whole deployment. On a new VM, confirm:

- The VM has network access to pull container base images.
- For production: `/service/shire` is mounted and the cert directory is
  populated (see `SECRETS.md`). For dev: `init.sh` generates self-signed
  certs automatically.

## Boot persistence

`restart: unless-stopped` only survives reboot if `podman-restart.service` is
enabled, which `init.sh` does.
