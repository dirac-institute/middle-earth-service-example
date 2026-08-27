#!/bin/bash
# Host initialization for a Middle-earth service VM. Run as root; safe to re-run.
#
#   git clone <this repo> && cd middle-earth-service-example
#   sudo ./init.sh
#   podman compose up -d --build
#
# Only host-level concerns live here (packages, firewall, service account, dev
# certs, SELinux). Everything else belongs in the container image.

set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="$REPO_DIR/.env"
CONF_FILE="$REPO_DIR/service.conf"
CERTS_DIR="$REPO_DIR/certs"

if [ ! -f "$CONF_FILE" ]; then
    echo "FATAL: $CONF_FILE not found." >&2
    echo "This file defines SVC_USER, SVC_UID, and SVC_GID for the service account." >&2
    exit 1
fi
# shellcheck source=service.conf
source "$CONF_FILE"
for var in SVC_USER SVC_UID SVC_GID; do
    if [ -z "${!var:-}" ]; then
        echo "FATAL: $var is not set in $CONF_FILE" >&2
        exit 1
    fi
done

WARNINGS=0
warn() { echo "WARNING: $*" >&2; WARNINGS=$((WARNINGS + 1)); }

[ "$(id -u)" -eq 0 ] || { echo "must run as root" >&2; exit 1; }

# ── Packages ────────────────────────────────────────────────────────────────
echo "== Packages =="
need=()
command -v podman >/dev/null || need+=(podman)
command -v podman-compose >/dev/null || need+=(podman-compose)
if [ ${#need[@]} -gt 0 ]; then
    rpm -q epel-release >/dev/null 2>&1 || dnf install -y epel-release
    dnf install -y "${need[@]}"
else
    echo "podman and podman-compose already installed"
fi
podman --version

# A compose restart policy only survives reboot if this unit is enabled.
systemctl enable --now podman-restart.service >/dev/null 2>&1 \
    && echo "podman-restart.service enabled" \
    || warn "could not enable podman-restart.service (containers won't restart at boot)"

# ── Firewall ────────────────────────────────────────────────────────────────
echo
echo "== Firewall =="
if systemctl is-active --quiet firewalld; then
    for port_spec in 443/tcp; do
        if firewall-cmd --permanent --query-port="$port_spec" >/dev/null 2>&1; then
            echo "  ok   $port_spec already open"
        else
            firewall-cmd --permanent --add-port="$port_spec" >/dev/null
            echo "  added $port_spec"
        fi
    done
    firewall-cmd --reload >/dev/null
    for port_spec in 443/tcp; do
        firewall-cmd --query-port="$port_spec" >/dev/null 2>&1 || warn "$port_spec is not open at runtime"
    done
else
    warn "firewalld is not running; ports not configured"
fi

# ── SSH hardening ───────────────────────────────────────────────────────────
echo
echo "== SSH hardening =="
SSHD_CONF=/etc/ssh/sshd_config.d/00-svc-hardening.conf
cat > "$SSHD_CONF" <<'EOF'
PasswordAuthentication no
KbdInteractiveAuthentication no
EOF
chmod 0600 "$SSHD_CONF"
if sshd -t >/dev/null 2>&1; then
    systemctl reload sshd >/dev/null 2>&1 \
        && echo "  ok   password authentication disabled" \
        || warn "could not reload sshd"
else
    warn "sshd config validation failed; check $SSHD_CONF"
fi

# ── Service account ────────────────────────────────────────────────────────
echo
echo "== Service account =="
# The container runs as this uid. On a production VM the secrets directory is
# on a shared NFS mount exported with root_squash, meaning root cannot read
# mode-0600 files -- only the service account can. The uid/gid must match what
# the NFS export owner uses; see SECRETS.md for the production story.
if getent group "$SVC_GID" >/dev/null; then
    have_group="$(getent group "$SVC_GID" | cut -d: -f1)"
    if [ "$have_group" = "$SVC_USER" ]; then
        echo "  ok   group $SVC_USER ($SVC_GID) exists"
    else
        warn "gid $SVC_GID belongs to group '$have_group', expected '$SVC_USER'"
    fi
else
    groupadd -g "$SVC_GID" "$SVC_USER"
    echo "  added group $SVC_USER ($SVC_GID)"
fi

if getent passwd "$SVC_UID" >/dev/null; then
    have_user="$(getent passwd "$SVC_UID" | cut -d: -f1)"
    if [ "$have_user" = "$SVC_USER" ]; then
        echo "  ok   user $SVC_USER ($SVC_UID) exists"
    else
        warn "uid $SVC_UID belongs to user '$have_user', expected '$SVC_USER'"
    fi
else
    useradd -u "$SVC_UID" -g "$SVC_GID" -M -d /nonexistent -s /bin/bash \
            -c "Service account" "$SVC_USER" 2>/dev/null
    echo "  added user $SVC_USER ($SVC_UID)"
fi

# ── SELinux ─────────────────────────────────────────────────────────────────
echo
echo "== SELinux =="
if command -v getenforce >/dev/null && [ "$(getenforce)" != "Disabled" ]; then
    command -v semanage >/dev/null || dnf install -y policycoreutils-python-utils
    if [ "$(getenforce)" = "Permissive" ]; then
        setenforce 1
        sed -i 's/^SELINUX=permissive/SELINUX=enforcing/' /etc/selinux/config
        echo "  ok   SELinux set to enforcing"
    else
        echo "  ok   SELinux already enforcing"
    fi
else
    warn "SELinux is disabled; cannot enable at runtime (requires reboot)"
fi

# ── Dev TLS certificates ───────────────────────────────────────────────────
echo
echo "== Dev TLS certificates =="
# In production the cert and key would live on the shared NFS mount (see
# SECRETS.md) and SVC_CERT_DIR would point at them. For development init.sh
# generates a self-signed pair so `podman compose up` works out of the box.
mkdir -p "$CERTS_DIR"
if [ -f "$CERTS_DIR/hostcert.pem" ] && [ -f "$CERTS_DIR/hostkey.pem" ]; then
    echo "  ok   dev certs already exist in $CERTS_DIR"
else
    FQDN="$(hostname -f 2>/dev/null || hostname)"
    openssl req -x509 -newkey rsa:2048 -nodes \
        -keyout "$CERTS_DIR/hostkey.pem" \
        -out "$CERTS_DIR/hostcert.pem" \
        -days 365 \
        -subj "/C=US/ST=Washington/L=Seattle/O=UW DiRAC/OU=Dev/CN=${FQDN}" \
        2>/dev/null
    chmod 0600 "$CERTS_DIR/hostkey.pem"
    chmod 0644 "$CERTS_DIR/hostcert.pem"
    echo "  ok   generated self-signed dev cert for $FQDN"
fi

# ── Compose environment ────────────────────────────────────────────────────
echo
echo "== Compose environment =="
FQDN="$(hostname -f 2>/dev/null || hostname)"
case "$FQDN" in
    *.*) ;;
    *)   warn "hostname '$FQDN' is not fully qualified; check DNS and /etc/hosts" ;;
esac
# Write service identity and the host FQDN into .env so podman compose can
# read them. .env is gitignored and per-host; service.conf is the committed
# source of truth for the identity values.
cat > "$ENV_FILE" <<EOF
SVC_USER=$SVC_USER
SVC_UID=$SVC_UID
SVC_GID=$SVC_GID
SVC_FQDN=$FQDN
EOF
echo "  ok   SVC_USER=$SVC_USER SVC_UID=$SVC_UID SVC_GID=$SVC_GID written to $ENV_FILE"
echo "  ok   SVC_FQDN=$FQDN written to $ENV_FILE"

echo
if [ "$WARNINGS" -gt 0 ]; then
    echo "init complete with $WARNINGS warning(s)."
else
    echo "init complete."
fi
echo "Next: podman compose up -d --build"
