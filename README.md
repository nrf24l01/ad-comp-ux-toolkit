# Gitea + Databag + Nginx (private LAN HTTPS)

This replaces the former VoceChat deployment. Three containers, no extra DB or
Redis: Gitea uses SQLite, Databag serves its included web client from its image,
Nginx terminates TLS. Databag has **no direct external network access** because it
is connected only to the `chat_isolated` Docker network (`internal: true`).
The container images themselves must be pulled once (or imported offline).

## Upgrade the existing VoceChat stack

1. Make a backup of the previous directory (`data/` and `pki/` in particular).
2. Extract the new ZIP **into the same project directory**, overwriting only
   `docker-compose.yml`, `nginx/default.conf`, `setup.sh`,
   `cert-client.template.sh`, `README.md`, `.gitignore`.
   **Do not delete** the existing `pki/`, `public/`, or `data/` directories.
3. Run `./setup.sh 192.168.0.71` (change IP if your server has another address).
   If Docker previously created root-owned directories, fix with:
   `sudo chown -R "$(id -u):$(id -g)" pki public` and retry.
4. Run `docker compose up -d --remove-orphans`.
5. Check `docker compose ps` and `docker compose logs --tail=100 databag nginx`.

The Compose project name is inferred from your existing directory, so
`--remove-orphans` removes the former VoceChat container without touching the
bind-mounted data. Do not change the directory or project name during migration.

Existing `vocechat-data/` is not deleted. Databag starts with a separate empty
`databag-data/`; chat history does not automatically migrate from VoceChat.
Gitea continues to use the previous bind mount `./data:/data`.

## New installation

```sh
./setup.sh 192.168.0.71
# The IP must be reachable by clients on the LAN or VPN.
docker compose up -d
```

`setup.sh` creates a local CA and TLS certificate in `pki/`, a Linux installer in
`public/cert.sh` and a randomly generated Databag administrator password in `.env`.
Subsequent runs reuse the existing root CA and the current valid HTTPS certificate.

Access points:

- `https://chat.b.local` — Databag
- `https://gitea.b.local` — Gitea
- `http://192.168.0.71/cert.sh` — Linux client certificate/hosts installer
- `http://192.168.0.71/rootCA.crt` — public root CA certificate
- `ssh://git@gitea.b.local:2222/USER/REPO.git` — Git over SSH

In Databag, open the gear icon, enter the password from `.env`, then use admin
settings to create account invitations for your users. Leave federation and
WebRTC relay settings unconfigured for a LAN-only, message/file deployment.

## Linux clients: local CA + /etc/hosts

```sh
curl -fsS http://192.168.0.71/cert.sh -o cert.sh
sha256sum cert.sh  # MUST match the hash printed by setup.sh over SSH/console
bash cert.sh
```

Run as your normal desktop user (the installer invokes sudo). It installs the
local CA in the Linux trust store, adds a managed `/etc/hosts` mapping for
`chat.b.local` and `gitea.b.local`, and imports the CA into NSS browser profiles
when `certutil` is available. Restart the browser afterwards.

**Security:** HTTP delivery of a privileged installer can be tampered with. Do
NOT execute the downloaded script until verifying its SHA-256 using SSH/console
on the server. Do NOT publish `pki/rootCA.key`, `pki/server.key` or `.env`.
Windows, macOS and mobile devices require separate trust/hosts configuration.
A private CA cannot suppress warnings on devices that have not installed it.

## Ports and network isolation

- Published: TCP 80, 443 (Nginx), 2222 (Gitea SSH).
- Gitea HTTP (3000) and Databag HTTP (7000) are **not** published.
- Databag is attached only to an internal Docker network; Nginx has one
  interface on that network and another on a normal network for Gitea.
- This prevents direct Internet egress **from the Databag container**; it does
  not by itself guarantee that browser JavaScript or other services make no
  external requests. Test browser traffic separately if a strictly offline
  environment is a hard requirement.
- `.local` is reserved for mDNS; `/etc/hosts` usually resolves it, but
  `home.arpa` is a better suffix for future purely local naming.
- Limit published ports on your LAN/VPN firewall as needed.

Back up the Gitea `data/`, Databag `databag-data/`, the `.env` file and `pki/`.
The root CA private key is highly sensitive. Re-running setup renews the server
certificate when it has less than 30 days left; restart Nginx after renewals.
