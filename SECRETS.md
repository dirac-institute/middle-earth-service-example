# Secrets layout

No secret is ever committed to this repo or baked into a container image.

## Development

For development, `init.sh` generates a self-signed TLS certificate and key
under `certs/` in the repo directory (gitignored). That is the only secret
needed to run the service locally.

| Path | What it is |
|---|---|
| `certs/hostcert.pem` | Self-signed TLS certificate |
| `certs/hostkey.pem` | Matching private key (mode 0600) |

## Production

In production, secrets live on the `/service/shire` NFS share and are
bind-mounted read-only into the container at runtime. Point `SVC_CERT_DIR` at
the production path:

```bash
SVC_CERT_DIR=/service/shire/<service>/certs podman compose up -d --build
```

| Host path | Container path | What it is |
|---|---|---|
| `/service/shire/<service>/certs/hostcert.pem` | `/etc/httpd/certs/hostcert.pem` | TLS certificate |
| `/service/shire/<service>/certs/hostkey.pem` | `/etc/httpd/certs/hostkey.pem` | Matching private key |

## Ownership and root_squash

`/service/shire` is exported with `root_squash`, so **root on the VM cannot
write to it** — root is mapped to `nobody`. The tree is owned by the service
account whose name, uid, and gid are defined in `service.conf`.

To place or update secrets, become that user (use the name from `service.conf`):

```bash
sudo -u $SVC_USER install -m 0600 /path/to/newkey \
    /service/shire/<service>/certs/hostkey.pem
```

`init.sh` creates this account on the host, so this works on any VM that has
been initialized. Before `init.sh` has run, use the numeric ids from
`service.conf` instead:

```bash
setpriv --reuid=$SVC_UID --regid=$SVC_GID --clear-groups \
    install -m 0600 /path/to/newkey /service/shire/<service>/certs/hostkey.pem
```

The container must *run* as that uid, or it cannot read mode-0600 files on the
share. The image creates a user with that uid/gid and `compose.yaml` sets
`user:` accordingly. All three values come from `service.conf` with no
hardcoded defaults.

## Permissions

```
/service/shire/<service>/certs/                   0755  $SVC_USER
/service/shire/<service>/certs/hostcert.pem       0644  $SVC_USER  (public)
/service/shire/<service>/certs/hostkey.pem        0600  $SVC_USER
```
