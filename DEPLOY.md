# Deploying the Middle-earth service example to a DiRAC VM

Target: stock Rocky 10 VM on UW DiRAC infrastructure.

The VM provides a reverse proxy that handles TLS termination and routes
traffic to your container on port 8080.

```bash
git clone <this repo> /root/middle-earth-service-example
cd /root/middle-earth-service-example
sudo ./init.sh
podman compose up -d --build
```

Then verify:

```bash
curl http://localhost:8080/api/hello
# {"message":"Hello from Middle-earth!","service":"example"}

curl http://localhost:8080/
# (static HTML page)

curl -s http://localhost:9110/metrics | grep -E 'load1 |filesystem_size|source_success'
# service_vm_load1 ..., one filesystem_size line per local disk filesystem,
# and service_vm_monitor_source_success{source="..."} 1 for all five sources
```

Then register the VM with the gadget monitor; see "Monitoring" below.

## What each piece does

| File | Role |
|---|---|
| `/root/VM.set` (not in the repo) | Written by IT when the VM is provisioned. The source of truth for the service account name, uid, and gid. |
| `init.sh` | Host-level only: reads the service account from `/root/VM.set` and checks it exists on the VM, installs podman + podman-compose, enables `podman-restart.service`, writes `.env`. Idempotent; safe to re-run. |
| `Dockerfile` | Apache httpd 2.4 + Python 3 + Flask/Gunicorn in one image. Apache serves static files and reverse-proxies `/api/` to Gunicorn. |
| `start.sh` | Container entrypoint: starts Gunicorn in the background, then runs Apache in the foreground. |
| `compose.yaml` | Two services: `app` (Apache + Gunicorn in one container on port 8080) and `monitoring` (the VM's CPU, memory and disks on port 9110). |
| `app/server.py` | Flask application with one API endpoint (`GET /api/hello`). |
| `app/static/index.html` | Static HTML page served directly by Apache. |
| `apache/httpd.conf` | Apache virtual host: plain HTTP on 8080, static files from `/srv/static`, `/api/` proxied to Gunicorn on `127.0.0.1:8000`. |
| `start.sh` | Container entrypoint: starts Gunicorn in the background, then runs Apache in the foreground. |
| `monitoring/` | Service VM monitor, copied unchanged from [middle-earth-gadget-monitor](https://github.com/dirac-institute/middle-earth-gadget-monitor). Its image and compose settings (`monitoring/compose.yaml`, pulled into `compose.yaml` with `extends`). See `monitoring/README.md`. |
| `dev-startup.sh` | Local development helper for macOS: runs `docker compose` as your own uid/gid, since a laptop has no `VM.set`. |
| `SECRETS.md` | How secrets are stored, the NFS ownership model, and permissions. |

## Architecture

```
                   ┌──────────────────────────────────────────┐
  VM reverse  ──►  │  container                                │
  proxy :8080      │    apache (port 8080)                     │
                   │      /         → static files             │
                   │      /api/*    → gunicorn (port 8000)     │
                   └──────────────────────────────────────────┘

  gadget monitor   ┌──────────────────────────────────────────┐
  (polls every ──► │  monitoring container (port 9110)         │
  minute) :9110    │    /metrics → this VM's CPU, memory,      │
                   │               disks, load (VM's / at      │
                   │               /host, read-only)           │
                   └──────────────────────────────────────────┘
```

## Design choices

**One container, two processes.** Apache and Gunicorn run in the same
container. Apache handles static files and reverse-proxies API requests to
Gunicorn on an internal port. The `start.sh` entrypoint launches Gunicorn in
the background and runs Apache in the foreground as PID 1.

**Containers for everything.** The only things `init.sh` does on the host are
check the service account and install podman. The service account, SSH, and
SELinux are provisioned by IT.
All application logic, dependencies, and configuration live inside the
container image. This means a deployment is fully reproducible from the repo
checkout.

**Secrets are bind-mounted, never baked in.** Any secrets the service needs
are mounted read-only into the container at runtime. See `SECRETS.md` for the
full story.

**Service account with fixed uid/gid.** The service account name, uid, and gid
come from IT's `/root/VM.set` on the VM, and flow through `.env` into the
Dockerfile and compose.yaml with no fallback defaults. Nothing about the
account is committed to the repo, so the same checkout deploys to any VM.
The uid/gid must match the owner of secrets on the production NFS share, which
is exported with `root_squash` — only that uid can read mode-0600 secrets. See
`SECRETS.md` for details on why this matters.

**Port 8080, localhost only.** The container listens on port 8080 and the
compose file binds it to `127.0.0.1:8080`. The VM's reverse proxy handles
TLS termination and routes external traffic to this port. The one
exception is the monitoring container's port 9110 (see "Monitoring").

**Monitoring is part of every service.** Each service VM runs the same
small monitor container, so the gadget monitor can graph its CPU, memory,
disks and load. It is copied into the repo rather than written per service,
and every service gets it with no changes of its own.

## Service identity: `/root/VM.set`

IT leaves `/root/VM.set` on every VM when it provisions it. It is in tcsh
syntax and names the VM and its service account:

```
set VM=myservice
set VMUSER=astro-myservice
set VMUID=NNNNNNN
set VMGID=NNNNNNNNNN
set VMGECOS="My Service Management User"
```

`init.sh` reads `VMUSER`, `VMUID` and `VMGID` from it. It parses the file and
never runs it, and ignores lines of any other form. It exits if the file is
missing, if any of the three is missing or malformed, or if the account does
not exist on the VM with exactly that uid and primary gid. If `VM` doesn't
match the VM's short hostname, it warns, because the file may have been
copied from another VM. `VMGECOS` is not used.

There is no copy of these values in the repo. If `VM.set` is missing or wrong,
ask PACS via help-astro@uw.edu rather than writing your own.

## Per-host configuration: `.env`

`init.sh` writes the account to `.env` as `SVC_USER`, `SVC_UID` and
`SVC_GID`, along with the host's own FQDN (`SVC_FQDN`), which compose.yaml
uses as the Apache `ServerName` and container hostname. Podman compose reads
`.env` automatically:

```
# Written by init.sh on every run; don't edit.
SVC_USER=astro-myservice
SVC_UID=NNNNNNN
SVC_GID=NNNNNNNNNN
SVC_FQDN=myservice.astro.washington.edu
```

The Dockerfile and compose.yaml consume these values via build args and
environment variables with no hardcoded defaults, so running `podman compose`
without a populated `.env` fails on the missing variables. `.env` is
gitignored and derived: `init.sh` rewrites it on every run. Re-run `init.sh`
rather than editing it, and never copy it between hosts.

## VM infrastructure context

DiRAC VMs run Rocky 10 and use podman (not Docker) as the container runtime.
Key things to know:

- **podman-compose** is the compose frontend. It reads the same `compose.yaml`
  format as `docker compose`. Install it from EPEL; `init.sh` handles this.
- **podman-restart.service** must be enabled for `restart: unless-stopped` to
  survive a VM reboot. `init.sh` enables it.
- **The VM's reverse proxy** handles TLS termination and firewall rules.
  The container listens on `127.0.0.1:8080` and does not need to manage TLS or
  open ports itself.
- **Service accounts** exist because the NFS share uses `root_squash`. The
  container process must run as the uid that owns the secrets on the share.
  IT creates this account on the VM and names it in `/root/VM.set`;
  `init.sh` checks the two agree and exits if they do not.

## Rollout to another VM

The procedure above is the whole deployment. On a new VM, confirm:

- `/root/VM.set` exists and names a service account that exists on the VM
  (IT provisions both).
- The VM has network access to pull container base images.
- For production: if the service has secrets, `/service/shire` is mounted and
  the secrets directory is populated (see `SECRETS.md`).
- For production: the VM is listed in the gadget monitor's
  `config/service_vms.toml` (see "Monitoring").

## Monitoring

The `monitoring` container is the gadget monitor's **service VM monitor**. It
serves the VM's CPU, memory, disk and load figures as Prometheus text on
`http://<vm fqdn>:9110/metrics`. The gadget monitor
([middle-earth-gadget-monitor](https://github.com/dirac-institute/middle-earth-gadget-monitor))
polls that every minute and graphs it on its **Service VMs** dashboard.
`monitoring/README.md` lists the metrics and explains each compose setting.

**Keep `monitoring/` identical to the gadget monitor's copy.** Do not edit it
in a service repo. To update it, copy the folder over again from the gadget
monitor's repo. The only per-service lines are in `compose.yaml`:
`container_name` (any name unique on the VM) and `labels`.

**Port 9110 is reachable from anywhere.** Unlike 8080, it is published
on every interface and does not go through the VM's reverse proxy or TLS,
because the gadget monitor connects to it directly. Podman DNATs the port, so
firewalld does not need to open it. Anyone who can reach the VM can read
these figures. They are resource numbers only, which was judged acceptable.
`monitoring/README.md` explains how to restrict who can read them.

### Registering the VM with the gadget monitor

Deploying the container is not enough on its own. The gadget monitor only
polls VMs listed in its `config/service_vms.toml`. Once the service is
running on its production VM:

1. **Check the endpoint from another machine**, using the production VM's
   own FQDN (what `hostname -f` prints on it, which is also `SVC_FQDN` in
   its `.env`):

   ```bash
   curl -s http://<vm fqdn>:9110/metrics | grep source_success
   ```

   Every `source` should report `1`. If it can't connect, the gadget monitor
   can't either. Fix that first.

2. **Open a pull request** against
   [dirac-institute/middle-earth-gadget-monitor](https://github.com/dirac-institute/middle-earth-gadget-monitor).
   It should add one entry to `config/service_vms.toml`:

   ```toml
   [[service_vm]]
   name = "<service name>"     # becomes the `service_vm` label on the dashboard
   address = "<vm fqdn>"       # the production VM's FQDN, as in step 1
   ```

   - `name` is a short, stable name for the service, typically the repo
     name without its `middle-earth-` prefix. Renaming it later starts new
     series and breaks the VM's history on the dashboard, so choose it once.
     It must not match any existing `name` in the file.
   - `address` must be the production VM, never a dev or test box. A dev
     box's numbers would be graphed as if they were the service's.
   - Add `port` or `metrics_url` only if you changed the monitor's port. With
     the settings in `monitoring/compose.yaml` you never need them.
   - In the PR description, give the service's repo and paste the step 1
     `curl` output, so the reviewer knows the endpoint answers.

   Do not add anything else. The dashboard lists every VM in the file
   automatically.

3. **After it merges and the gadget monitor is redeployed**, the VM
   appears on the **Service VMs** dashboard within a minute or two.

A VM that is retired or renamed needs another PR to remove or change its
entry. Otherwise the dashboard shows it as down.

## Boot persistence

`restart: unless-stopped` only survives reboot if `podman-restart.service` is
enabled, which `init.sh` does.
