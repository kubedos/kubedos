#!/usr/bin/env bash
set -euo pipefail

SRC="/srv/ansible"
DEST_DIR="/home/todd"
TS="$(date -u +%Y%m%dT%H%M%SZ)"
OUT_BASE="ansible_bundle_${TS}"
WORKDIR="/tmp/${OUT_BASE}"
TARBALL="${DEST_DIR}/${OUT_BASE}.tar.gz"

# Safety checks
[[ -d "$SRC" ]] || { echo "ERROR: missing $SRC" >&2; exit 1; }
[[ -d "$DEST_DIR" ]] || { echo "ERROR: missing $DEST_DIR" >&2; exit 1; }

umask 077
rm -rf "$WORKDIR"
mkdir -p "$WORKDIR"

# Copy key structure (readable + complete enough)
mkdir -p "$WORKDIR/srv_ansible"
rsync -aHAX --numeric-ids \
  --delete \
  --exclude ".git/" \
  --exclude ".venv/" \
  --exclude "venv/" \
  --exclude "__pycache__/" \
  --exclude "*.pyc" \
  --exclude ".cache/" \
  --exclude ".mypy_cache/" \
  --exclude ".pytest_cache/" \
  --exclude "collections/" \
  --exclude "roles/*/files/*.tar.gz" \
  --exclude "artifacts/*.tar.gz" \
  "$SRC/" "$WORKDIR/srv_ansible/"

# Create a concise manifest I can scan fast
{
  echo "# Ansible bundle manifest"
  echo "created_utc: ${TS}"
  echo "source: ${SRC}"
  echo
  echo "## top-level"
  (cd "$WORKDIR/srv_ansible" && ls -la)
  echo
  echo "## inventory files"
  (cd "$WORKDIR/srv_ansible" && find inventory -maxdepth 3 -type f -print 2>/dev/null || true)
  echo
  echo "## group_vars / host_vars"
  (cd "$WORKDIR/srv_ansible" && find group_vars host_vars -type f -print 2>/dev/null || true)
  echo
  echo "## playbooks"
  (cd "$WORKDIR/srv_ansible" && find playbooks -type f -maxdepth 2 -print 2>/dev/null || true)
  echo
  echo "## roles (tasks/handlers/templates/defaults/vars)"
  (cd "$WORKDIR/srv_ansible" && find roles -type f \( \
      -path "*/tasks/*" -o -path "*/handlers/*" -o -path "*/templates/*" -o -path "*/defaults/*" -o -path "*/vars/*" \
    \) -print 2>/dev/null || true)
  echo
  echo "## ansible.cfg"
  if [[ -f "$WORKDIR/srv_ansible/ansible.cfg" ]]; then
    sed -n '1,220p' "$WORKDIR/srv_ansible/ansible.cfg"
  else
    echo "(none)"
  fi
  echo
} > "$WORKDIR/MANIFEST.txt"

# Optional: redact obvious secrets in-place (best-effort)
# NOTE: This does not guarantee removal of all secrets; it just helps.
# Comment this block out if you prefer raw.
find "$WORKDIR/srv_ansible" -type f \( -name "*.yml" -o -name "*.yaml" -o -name "*.ini" -o -name "*.cfg" -o -name "*.j2" \) -print0 \
| while IFS= read -r -d '' f; do
    sed -i \
      -e 's/\(PFSENSE_JWT[[:space:]]*[:=][[:space:]]*\).*/\1"REDACTED"/g' \
      -e 's/\(token[[:space:]]*[:=][[:space:]]*\).*/\1"REDACTED"/Ig' \
      -e 's/\(password[[:space:]]*[:=][[:space:]]*\).*/\1"REDACTED"/Ig' \
      -e 's/\(client_secret[[:space:]]*[:=][[:space:]]*\).*/\1"REDACTED"/Ig' \
      "$f" 2>/dev/null || true
  done

# Build tarball
tar -C /tmp -czf "$TARBALL" "$OUT_BASE"

# Lock down permissions and show result
chown todd:todd "$TARBALL" || true
chmod 0600 "$TARBALL"

echo "Wrote: $TARBALL"
echo "To inspect:"
echo "  tar -tzf $TARBALL | less"
echo "To extract:"
echo "  mkdir -p /home/todd/${OUT_BASE} && tar -xzf $TARBALL -C /home/todd/${OUT_BASE}"

