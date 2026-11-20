#!/usr/bin/env bash
# Generate or reuse a private local CA and TLS server certificate.
# Also create the Linux client installer and Databag admin secret.
# Usage: ./setup.sh 192.168.0.71
set -euo pipefail

if [[ $# -ne 1 ]]; then
    echo "Usage: $0 <server-LAN-IPv4>" >&2
    exit 1
fi
IP="$1"
if ! [[ "$IP" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]]; then
    echo 'Expected an IPv4 address.' >&2
    exit 1
fi
IFS=. read -r a b c d <<< "$IP"
for part in "$a" "$b" "$c" "$d"; do
    if (( 10#$part > 255 )); then
        echo 'Invalid IPv4 address.' >&2
        exit 1
    fi
done
for cmd in openssl sha256sum sed awk; do
    command -v "$cmd" >/dev/null || { echo "Missing required command: $cmd" >&2; exit 1; }
done

cd "$(dirname "$(realpath "$0")")"
umask 077
mkdir -p pki public data databag-data
if ! chmod 700 pki 2>/dev/null; then
    echo 'Cannot change permissions of pki/; this usually means Docker created it as root.' >&2
    echo 'Fix (from this directory): sudo chown -R "$(id -u):$(id -g)" pki public' >&2
    exit 1
fi
if [[ ! -w pki || ! -w public ]]; then
    echo 'pki/ or public/ is not writable by the current user.' >&2
    echo 'Fix: sudo chown -R "$(id -u):$(id -g)" pki public' >&2
    exit 1
fi

# Reuse the existing CA when upgrading the earlier VoceChat deployment.
if [[ -e pki/rootCA.key || -e pki/rootCA.crt ]]; then
    if [[ ! -s pki/rootCA.key || ! -s pki/rootCA.crt ]]; then
        echo 'Incomplete CA in pki/. Refusing to replace it.' >&2
        exit 1
    fi
    echo 'Reusing existing local CA; no client trust reinstallation required.'
else
    echo 'Generating private root CA...'
    openssl genrsa -out pki/rootCA.key 3072
    openssl req -new -x509 -sha256 -days 3650 \
        -key pki/rootCA.key -out pki/rootCA.crt \
        -subj '/CN=B Local Root CA' \
        -addext 'basicConstraints=critical,CA:TRUE,pathlen:0' \
        -addext 'keyUsage=critical,keyCertSign,cRLSign' \
        -addext 'subjectKeyIdentifier=hash'
fi

cat > pki/server.ext <<'EXT'
[server_cert]
basicConstraints = critical, CA:FALSE
keyUsage = critical, digitalSignature, keyEncipherment
extendedKeyUsage = serverAuth
subjectAltName = @names

[names]
DNS.1 = chat.b.local
DNS.2 = gitea.b.local
EXT

# Re-issue only when necessary; repeated setup does not change the leaf certificate.
if [[ -s pki/server.crt && -s pki/server.key ]] && \
   openssl verify -CAfile pki/rootCA.crt pki/server.crt >/dev/null 2>&1 && \
   openssl x509 -in pki/server.crt -checkend 2592000 -noout >/dev/null 2>&1 && \
   openssl x509 -in pki/server.crt -noout -ext subjectAltName | grep -q 'DNS:chat.b.local' && \
   openssl x509 -in pki/server.crt -noout -ext subjectAltName | grep -q 'DNS:gitea.b.local'; then
    echo 'Reusing existing HTTPS certificate.'
else
    echo 'Generating HTTPS certificate for chat.b.local and gitea.b.local (365 days)...'
    openssl genrsa -out pki/server.key 2048
    openssl req -new -sha256 -key pki/server.key \
        -out pki/server.csr -subj '/CN=chat.b.local'
    openssl x509 -req -sha256 -days 365 \
        -in pki/server.csr -CA pki/rootCA.crt -CAkey pki/rootCA.key \
        -CAcreateserial -out pki/server.crt \
        -extfile pki/server.ext -extensions server_cert
    rm -f pki/server.csr
fi
chmod 600 pki/rootCA.key pki/server.key
chmod 644 pki/rootCA.crt pki/server.crt
cp pki/rootCA.crt public/rootCA.crt

# Create a strong Databag admin password without embedding it in compose or ZIP.
if [[ ! -e .env ]]; then
    printf 'DATABAG_ADMIN=%s\n' "$(openssl rand -hex 24)" > .env
    chmod 600 .env
    echo 'Created .env with Databag admin password.'
else
    echo 'Keeping existing .env (Databag admin password not changed).'
fi

CA_SHA="$(sha256sum public/rootCA.crt | awk '{print $1}')"
sed -e "s/@@SERVER_IP@@/$IP/g" -e "s/@@CA_SHA256@@/$CA_SHA/g" \
    cert-client.template.sh > public/cert.sh
chmod 644 public/rootCA.crt public/cert.sh

cat <<MSG

Setup complete. Start the services:
  docker compose up -d --remove-orphans

URLs:
  https://chat.b.local
  https://gitea.b.local
  http://$IP/cert.sh

On each Linux client:
  curl -fsS http://$IP/cert.sh -o cert.sh
  # Verify SHA256 against the trusted value below before running:
  bash cert.sh

Trusted SHA256 of public/cert.sh:
  $(sha256sum public/cert.sh)

Databag administrator password is in .env (DATABAG_ADMIN=...).
Do not distribute .env, pki/rootCA.key or pki/server.key.
MSG
