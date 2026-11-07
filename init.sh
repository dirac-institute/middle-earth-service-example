#!/bin/bash
# Host initialization for a Middle-earth service VM. Run as root; safe to re-run.
#
#   git clone <this repo> && cd middle-earth-service-example
#   sudo ./init.sh
#   podman compose up -d --build
#
# Only host-level concerns live here (checking the service account from IT's
# /root/VM.set, podman packages, .env). Everything else belongs in the
# container image. The service account, SSH, and SELinux are provisioned by
# IT; this script does not change them.

set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="$REPO_DIR/.env"
# Written by IT when the VM is provisioned and authoritative for the service
# account. tcsh syntax: `set VMUSER=astro-myservice`.
VM_SET=/root/VM.set

WARNINGS=0
warn() { echo "WARNING: $*" >&2; WARNINGS=$((WARNINGS + 1)); }
die()  { echo "FATAL: $*" >&2; exit 1; }

[ "$(id -u)" -eq 0 ] || die "must run as root"

# vmset NAME: the value of `set NAME=value` in VM.set, quotes removed. The
# file is parsed, never executed; lines of any other form are ignored.
vmset() {
    sed -n -E "s/^[[:space:]]*set[[:space:]]+$1=(\"([^\"]*)\"|'([^']*)'|([^[:space:]\"']*))[[:space:]]*\$/\2\3\4/p" \
        "$VM_SET" | tail -n 1
}
[ -r "$VM_SET" ] || die "$VM_SET not found. IT writes it when the VM is provisioned; it
       defines the service account (VMUSER, VMUID, VMGID). Ask PACS via help-astro@uw.edu."
SVC_USER="$(vmset VMUSER)"
SVC_UID="$(vmset VMUID)"
SVC_GID="$(vmset VMGID)"
VM_NAME="$(vmset VM)"
[[ "$SVC_USER" =~ ^[a-z_][a-z0-9_.-]*$ ]] || die "VMUSER in $VM_SET is missing or not a user name: '$SVC_USER'"
[[ "$SVC_UID" =~ ^[0-9]+$ ]] || die "VMUID in $VM_SET is missing or not a number: '$SVC_UID'"
[[ "$SVC_GID" =~ ^[0-9]+$ ]] || die "VMGID in $VM_SET is missing or not a number: '$SVC_GID'"

# ── Service account ────────────────────────────────────────────────────────
echo "== Service account =="
# The container runs as this uid. On a production VM the secrets directory is
# on a shared NFS mount exported with root_squash, meaning root cannot read
# mode-0600 files -- only the service account can. IT provisions the account
# and names it in VM.set; the two must agree. See SECRETS.md for the
# production story.
account_fail() {
    echo "FATAL: $*" >&2
    echo "$VM_SET and the accounts on this VM disagree; ask PACS via help-astro@uw.edu." >&2
    exit 1
}
have_user="$(getent passwd "$SVC_USER" || true)"
[ -n "$have_user" ] || account_fail "user $SVC_USER does not exist"
have_uid="$(echo "$have_user" | cut -d: -f3)"
have_gid="$(echo "$have_user" | cut -d: -f4)"
[ "$have_uid" = "$SVC_UID" ] \
    || account_fail "user $SVC_USER has uid $have_uid, VM.set says $SVC_UID"
[ "$have_gid" = "$SVC_GID" ] \
    || account_fail "user $SVC_USER has primary gid $have_gid, VM.set says $SVC_GID"
echo "  ok   user $SVC_USER ($SVC_UID:$SVC_GID) from $VM_SET exists"

# ── Packages ────────────────────────────────────────────────────────────────
echo
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

# ── Compose environment ────────────────────────────────────────────────────
echo
echo "== Compose environment =="
FQDN="$(hostname -f 2>/dev/null || hostname)"
case "$FQDN" in
    *.*) ;;
    *)   warn "hostname '$FQDN' is not fully qualified; check DNS and /etc/hosts" ;;
esac
# VM.set's VM is IT's short name for this VM. Nothing here depends on it, but
# a mismatch means VM.set may have been copied from another VM.
SHORT="$(hostname -s | tr '[:upper:]' '[:lower:]')"
[ -z "$VM_NAME" ] || [ "$VM_NAME" = "$SHORT" ] \
    || warn "VM.set says VM=$VM_NAME but the hostname is $SHORT; is $VM_SET from this VM?"
# .env is gitignored and derived: rewritten on every run from VM.set and the
# hostname, so podman compose can read them. Re-run init.sh rather than
# editing it.
cat > "$ENV_FILE" <<EOF
# Written by init.sh on every run; don't edit.
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
