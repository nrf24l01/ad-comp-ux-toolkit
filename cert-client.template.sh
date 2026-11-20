#!/usr/bin/env bash
# Run as your normal desktop user on a Linux client, NOT as root.
set -euo pipefail

SERVER_IP='@@SERVER_IP@@'
EXPECTED_CA_SHA256='@@CA_SHA256@@'
CA_LABEL='B Local Root CA'

if [[ "$(uname -s)" != Linux ]]; then
    echo 'This installer supports Linux only.' >&2
    exit 1
fi
if (( EUID == 0 )); then
    echo 'Run as your normal desktop user: bash cert.sh (not sudo bash cert.sh).' >&2
    exit 1
fi
for cmd in curl sudo sha256sum awk install; do
    command -v "$cmd" >/dev/null || { echo "Missing command: $cmd" >&2; exit 1; }
done

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

curl -fsS --connect-timeout 10 --max-time 60 \
    "http://${SERVER_IP}/rootCA.crt" -o "$TMP_DIR/rootCA.crt"
ACTUAL_SHA256="$(sha256sum "$TMP_DIR/rootCA.crt" | awk '{print $1}')"
if [[ "$ACTUAL_SHA256" != "$EXPECTED_CA_SHA256" ]]; then
    echo 'CA certificate fingerprint mismatch. Aborting.' >&2
    exit 1
fi

echo "Verified CA certificate SHA-256: $ACTUAL_SHA256"

echo 'Installing CA into the system trust store (sudo required)...'
sudo -v
if [[ -d /etc/ca-certificates/trust-source/anchors ]] && command -v trust >/dev/null; then
    # Arch Linux
    sudo install -m 0644 "$TMP_DIR/rootCA.crt" /etc/ca-certificates/trust-source/anchors/b-local-rootCA.crt
    sudo trust extract-compat
elif command -v update-ca-certificates >/dev/null; then
    # Debian / Ubuntu
    sudo install -m 0644 "$TMP_DIR/rootCA.crt" /usr/local/share/ca-certificates/b-local-rootCA.crt
    sudo update-ca-certificates
elif [[ -d /etc/pki/ca-trust/source/anchors ]] && command -v update-ca-trust >/dev/null; then
    # Fedora / RHEL
    sudo install -m 0644 "$TMP_DIR/rootCA.crt" /etc/pki/ca-trust/source/anchors/b-local-rootCA.crt
    sudo update-ca-trust extract
else
    echo 'Unsupported distribution: no supported system CA trust store.' >&2
    exit 1
fi

echo 'Configuring /etc/hosts...'
awk '
    $0 == "# BEGIN B-LOCAL-SERVICES" { managed=1; next }
    $0 == "# END B-LOCAL-SERVICES" { managed=0; next }
    !managed { print }
' /etc/hosts > "$TMP_DIR/hosts"
{
    echo '# BEGIN B-LOCAL-SERVICES'
    printf '%s chat.b.local gitea.b.local\n' "$SERVER_IP"
    echo '# END B-LOCAL-SERVICES'
} >> "$TMP_DIR/hosts"
sudo cp "$TMP_DIR/hosts" /etc/hosts

# Firefox and some Chromium builds can use a separate NSS certificate DB.
# Import into the existing browser profiles (if certutil is installed).
if ! command -v certutil >/dev/null 2>&1; then
    echo 'WARNING: certutil is missing. For Firefox/Chromium install nss (Arch), libnss3-tools (Debian/Ubuntu), or nss-tools (Fedora), then rerun this installer.' >&2
else
    shopt -s nullglob
    for firefox_dir in \
        "$HOME/.mozilla/firefox" \
        "$HOME/.var/app/org.mozilla.firefox/.mozilla/firefox" \
        "$HOME/snap/firefox/common/.mozilla/firefox"; do
        for profile in "$firefox_dir"/*; do
            [[ -f "$profile/cert9.db" ]] || continue
            certutil -D -d "sql:$profile" -n "$CA_LABEL" >/dev/null 2>&1 || true
            certutil -A -d "sql:$profile" -n "$CA_LABEL" -t 'C,,' -i "$TMP_DIR/rootCA.crt"
            echo "Added CA to Firefox NSS profile: $profile"
        done
    done

    NSS_DIR="$HOME/.pki/nssdb"
    mkdir -p "$NSS_DIR"
    if [[ ! -f "$NSS_DIR/cert9.db" ]]; then
        certutil -N --empty-password -d "sql:$NSS_DIR"
    fi
    certutil -D -d "sql:$NSS_DIR" -n "$CA_LABEL" >/dev/null 2>&1 || true
    certutil -A -d "sql:$NSS_DIR" -n "$CA_LABEL" -t 'C,,' -i "$TMP_DIR/rootCA.crt"
    echo 'Added CA to Chromium-compatible NSS database.'
fi

cat <<'EOF'

Done. Restart your browser, then open:
  https://chat.b.local
  https://gitea.b.local

If an existing entry for either name already exists elsewhere in /etc/hosts,
remove the conflicting old entry.
EOF
