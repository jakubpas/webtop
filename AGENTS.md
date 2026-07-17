# AGENTS.md — webtop / desktop.darkplanet.pl project

Context for future work on this repo. This branch (`darkplanet`) turns the local
`webtop` launcher script into a permanently-hosted, authenticated remote desktop
at **https://desktop.darkplanet.pl**, running on the `darkplanet.pl` production
server.

## Goal

Run the `linuxserver/webtop` Docker container on the `darkplanet.pl` server,
exposed at `desktop.darkplanet.pl` over HTTPS, protected by Basic Auth, so it
can be opened from a browser and used like a normal remote Linux desktop.

## Target server: darkplanet.pl

- Host: `darkplanet.pl` (`142.4.215.81`), Ubuntu 24.04, 4 vCPU, 7.6GB RAM, 3.3TB disk.
- SSH: `ssh kuba@darkplanet.pl` — key-based, no password prompt.
- `kuba` is in the `sudo` group with **passwordless sudo** — `sudo <cmd>` just works,
  no `-S`/password needed. Also passwordless: `rndc reload`, `systemctl reload apache2`.
- `kuba` uid/gid on this host is **1001/1001** (NOT 1000 — this matters for Docker PUID/PGID).
- This is a **shared production box**: it also runs the darkplanet.pl mail server
  (Postfix/Dovecot), MySQL, a Spring Boot app (`portal.jar`, ports 8080/8081), and
  BIND9 (authoritative DNS for darkplanet.pl, signum-temporis.pl, jakubpas.net, etc).
  Free RAM is tight (~324MB free / ~4.7GB reclaimable cache at time of writing) —
  always cap new containers with `--memory`/`--cpus` so they can't starve
  production services.

## Port allocation (important — avoid collisions)

- **8080 and 8081 are TAKEN** by `/opt/darkplanet/portal.jar` (the production
  Spring Boot app, proxied by the `darkplanet.pl` vhost). Do **not** use these.
- webtop container must bind to **`127.0.0.1:8082`** (host-side), mapped to the
  container's internal port 3000. Loopback-only so it's unreachable except via
  the Apache reverse proxy — never expose it on `0.0.0.0`.

## DNS (BIND9, self-hosted)

- Zone file: `/etc/bind/zones/darkplanet.pl` on the server (owned by `kuba`, editable directly).
- Config: `/etc/bind/named.conf.local` — zone `darkplanet.pl` allows AXFR transfer
  to specific secondary IPs only (OVH slave `8.33.137.137`, etc).
- To add the subdomain: append `desktop  IN  A  142.4.215.81`, **bump the SOA serial**
  (format `YYYYMMDDnn`), then `sudo rndc reload` (passwordless, confirmed working).
- **Automate the serial bump** rather than hand-editing it — manually incrementing
  `YYYYMMDDnn` is a classic footgun (get it wrong/stale and BIND silently ignores
  the reload). A tiny script/Makefile target that reads the current serial and
  increments it correctly removes that risk.
- No Cloudflare/CDN in front — `ns1.darkplanet.pl` / `ns2` (OVH) are authoritative directly.

## TLS (certbot, snap install)

- `certbot` installed via snap, apache plugin available, auto-renewal via
  `snap.certbot.renew.timer` (active).
- Existing certs of note:
  - `darkplanet.pl` (multi-SAN: darkplanet.pl, www.darkplanet.pl, signum-temporis.pl,
    www.signum-temporis.pl) — **do not add desktop.darkplanet.pl to this one.**
  - `www.darkplanet.pl` (separate, single-domain).
- Plan: issue a **new, dedicated cert** for `desktop.darkplanet.pl`:
  `sudo certbot --apache -d desktop.darkplanet.pl` (run only after the DNS A
  record above is live and propagated).

## Apache (2.4.58, prefork MPM)

- Vhosts: `/etc/apache2/sites-available/*.conf`, symlinked into `sites-enabled/`.
  Existing numbering: `000-default`, `001-darkplanet.pl`, `003-jakubpas.net`,
  `004-signum-temporis.pl(+le-ssl)`, `005-download.jakubpas.net`. New vhost should
  be `002-desktop.darkplanet.pl.conf` (or next free number).
- Modules currently loaded: `ssl`, `proxy`, `proxy_http`, `auth_basic`, `authn_file`,
  `authz_user`, `headers`, `rewrite`, `deflate`, `expires`. **`proxy_wstunnel` is
  NOT enabled yet** — required for Selkies WebSocket streaming, must run
  `sudo a2enmod proxy_wstunnel && sudo systemctl reload apache2` before the vhost
  will work correctly.
- Reference vhost pattern to copy from: `001-darkplanet.pl.conf` (reverse proxy to
  a local backend port + `X-Forwarded-Proto` header) and
  `004-signum-temporis.pl-le-ssl.conf` (SSL cert block layout).
- New vhost needs: :80 → 301 redirect to :443; :443 with own cert, `ProxyPass`/
  `ProxyPassReverse` to `http://127.0.0.1:8082/`, WebSocket upgrade rules via
  `proxy_wstunnel` (RewriteCond on `Upgrade: websocket` header, or
  `ProxyPass ... upgrade=websocket`), and `AuthType Basic` + bcrypt `.htpasswd`
  (`htpasswd -B`) with `Require valid-user` wrapping the whole vhost (or at least
  the `/` location) so nothing is reachable pre-auth.
- Reload with `sudo systemctl reload apache2` (confirmed passwordless).

## Docker

- Docker 29.1.3 installed. `kuba` is **not** in the `docker` group — must always
  use `sudo docker ...` (confirmed passwordless).
- **Image is pulled directly on the server**, not built/pulled locally and
  streamed over — see "Deviations found during implementation" below for why
  the original local-pull-then-`docker save | ssh ... docker load` plan was
  abandoned (ARM64 vs AMD64 architecture mismatch). Just run
  `sudo docker pull linuxserver/webtop:latest` (or `docker compose pull`) on
  darkplanet.pl directly — the server is AMD64 so this always gets the right
  architecture with no extra steps. A plain image pull is lightweight
  (network + disk, not CPU-heavy), so this doesn't meaningfully compete with
  the production services on this host.
  - `~/webtop_data` (persistent config/profile volume) is just an empty dir
    created directly on the server: `mkdir -p ~/webtop_data`.
  - **Back this dir up**: fold `~/webtop_data` into the existing `~/backups`
    routine already present on the server (it holds the persistent browser
    profile/session state — worth preserving across a container/host rebuild).
- **`docker-compose.yml` is checked into this repo** (not a raw `docker run`
  bash script) — ports, PUID/PGID, `mem_limit`/`cpus`, `restart: unless-stopped`,
  and the volume mount are all declarative and diffable in git. Deploy dir on
  the server is `~/webtop/` (holds just the compose file); bring it up with
  `cd ~/webtop && sudo docker compose up -d`.
- **`cap_drop: [ALL]` + `no-new-privileges:true` was tried and reverted** — see
  "Deviations found during implementation" below. `linuxserver/webtop`'s
  s6-init/nginx stack isn't designed to run capability-restricted; isolation
  instead relies on the loopback-only port binding + mem/cpu limits.
- PUID/PGID/port fixes already applied vs. the original local `desktop` script:
  - `PUID=1001`/`PGID=1001` (not 1000 — matches `kuba`'s actual uid/gid here).
  - `127.0.0.1:8082:3000` (not `8080:3000` — avoids the portal.jar collision,
    and loopback-only so Apache is the only path in).
  - Add `--restart unless-stopped --memory=2g --cpus=2` for resilience across
    reboots and to protect co-located production services from resource
    starvation.
  - Keep `--shm-size=1gb` and the existing `SELKIES_*` high-DPI env vars —
    those are fine as-is.
- Existing containers on the box (context only, not part of this project):
  several stopped `grafana/alloy` containers and a `torchbearer-telemetry-relay`
  image — unrelated cruft, harmless to ignore.

## Docker vs. native host desktop (decided)

Considered installing a desktop environment (XFCE/Xvfb/Selkies/Chromium) directly
on the server instead of using a container — **rejected**. The server is
confirmed fully headless (no X11/Xorg/desktop packages installed at all), and
it's a shared production box (mail, MySQL, Apache/portal.jar). Docker keeps the
desktop stack isolated (own filesystem/namespace, capped via `--memory`/`--cpus`,
trivially rollback-able by swapping the image) instead of installing a large,
hand-maintained GUI package set directly into the production root filesystem.
Sticking with Docker as originally planned.

## Access model (decided)

Public HTTPS + Basic Auth, **not** a VPN/tunnel (Tailscale/WireGuard) — ruled
out because access is needed from a work PC where installing a tunnel client
isn't practical. Security instead comes from: webtop bound to loopback only,
TLS, bcrypt Basic Auth, and a fail2ban jail (see below).

## Security posture / auth

- Auth model: **Basic Auth at the Apache layer**, single user (`kuba`), bcrypt
  hashed (`htpasswd -B /etc/apache2/.htpasswd-desktop kuba`), HTTPS-only so
  credentials are encrypted in transit. This is intentionally simple per the
  current requirements — no SSO/2FA layer requested.
- `fail2ban` is installed on the server but **inactive** — enable it and add a
  jail watching Apache auth failures (`mod_auth_basic` 401s in the vhost's
  error/access log) to mitigate brute force against the desktop login.
- `ufw` is inactive on this host and **intentionally left alone** — not part of
  this project's scope; security relies on webtop being loopback-only + Apache
  TLS + Basic Auth + fail2ban instead of a host firewall change on a shared
  production box.
- Container itself runs as `kuba`'s uid (1001) via PUID/PGID — no root-in-container
  surprises expected from `linuxserver/webtop`'s standard s6-init model.

## Biggest open risk — verify before calling this "done"

`linuxserver/webtop` (per the `SELKIES_*` env vars already in the `desktop`
script) uses **Selkies**, which streams the desktop via **WebRTC**, not a plain
VNC/websocket protocol. Reverse-proxying WebRTC signaling through Apache
(`proxy_wstunnel`) should carry the signaling channel fine, but actual media
(video/audio) negotiation depends on ICE candidates and may behave differently
once accessed from an arbitrary public client rather than the same LAN/Cloud
Shell relay it was tuned for originally. **Must be tested end-to-end after
deployment** — if the picture doesn't come through reliably, look at forcing
TURN/relay-only ICE mode in the container's Selkies config, or consider
switching to a KasmVNC-based image variant instead (pure TCP/websocket, no
WebRTC/ICE complexity) as a fallback.

## Useful commands (from this session's investigation)

```bash
# SSH in
ssh kuba@darkplanet.pl

# Check current apache modules
apache2ctl -M

# Check what's listening on which port
sudo ss -tlnp

# Certbot status
sudo certbot certificates

# DNS zone reload after editing /etc/bind/zones/darkplanet.pl
sudo rndc reload

# Apache reload after vhost changes
sudo systemctl reload apache2

# Docker (always needs sudo — kuba not in docker group)
sudo docker ps -a
sudo docker images
```

## Status

Planning complete as of 2026-07-17. Implementation not yet started. Build order below.

## Deviations found during implementation

Two parts of the original plan didn't survive contact with reality — recorded
here so they aren't re-attempted:

1. **Local-pull-then-stream for the Docker image didn't work.** The dev
   machine used to prep the image (a Mac) is ARM64; the darkplanet.pl server is
   AMD64. `docker pull` without `--platform` grabs the native (ARM64) image,
   and `docker save | ssh ... docker load` shipped that straight to the AMD64
   server, which then failed with `exec /init: exec format error`. Explicitly
   pulling `--platform linux/amd64` locally avoids that, but then a second
   problem hit: Docker's containerd-backed multi-arch image store couldn't
   `docker save` a single-platform pull cleanly (`unable to create manifests
   file: NotFound: content digest ... not found`). **Fix: just
   `docker pull`/`docker compose pull` directly on the server** — it's AMD64
   native so there's no cross-arch ambiguity, and a pull is lightweight
   (network+disk, not CPU) so it doesn't meaningfully compete with production
   services. The "avoid touching the server" concern from the original plan
   was really about avoiding a *build*, not a plain image pull — pulling
   directly on the server is fine and much simpler.
2. **`cap_drop: [ALL]` + `no-new-privileges:true` broke the container.**
   `linuxserver/webtop`'s s6-init + nginx stack needs several capabilities back
   (`s6-applyuidgid: fatal: unable to set supplementary group list: Operation
   not permitted`, nginx unable to write its own log files or load modules).
   Reverted rather than spending more time reverse-engineering the minimal
   capability set for a stack that isn't designed to run capability-restricted.
   Isolation instead relies on: loopback-only port binding (`127.0.0.1:8082`,
   unreachable except through Apache), `mem_limit`/`cpus` caps, and the
   Apache-level TLS + Basic Auth + fail2ban layer.

## Implementation plan (step-by-step, in dependency order)

- [x] **`dns-desktop-subdomain`** — Add `desktop IN A 142.4.215.81` to
  `/etc/bind/zones/darkplanet.pl`, bump the SOA serial, `sudo rndc reload`.
  *(Done 2026-07-17 — serial bumped to `2026071701`, record verified resolving
  both locally and publicly via 8.8.8.8. Zone backed up to
  `darkplanet.pl.bak.<timestamp>` on the server before editing.)*
- [x] **`dns-serial-helper`** *(depends on above)* — Add a small script/Makefile
  target that safely reads and increments the zone's SOA serial (`YYYYMMDDnn`)
  so future edits don't risk a stale/incorrect serial silently blocking reloads.
  *(Done 2026-07-17 — `scripts/bump-zone-serial.sh`, tested live against the
  server: bumped serial `2026071701 → 2026071702`, validated with
  `named-checkzone`, reloaded with `rndc reload`.)*
- [x] **`webtop-docker-run`** *(depends on DNS record)* — Create a
  `docker-compose.yml` in this repo: port `127.0.0.1:8082:3000`,
  `PUID=1001`/`PGID=1001` (matches `kuba`'s uid/gid on darkplanet.pl, NOT the
  container default 1000), `mem_limit: 2g`, `cpus: 2`,
  `restart: unless-stopped`, `cap_drop: [ALL]` + `no-new-privileges:true` (test
  and add back only capabilities actually required for Xorg), volume
  `~/webtop_data:/config`. Build/pull the image locally and stream it to the
  server (no server-side pull, no intermediate tarball):
  ```bash
  docker pull linuxserver/webtop:latest
  docker save linuxserver/webtop:latest | ssh kuba@darkplanet.pl 'sudo docker load'
  ```
  Then on the server: `mkdir -p ~/webtop_data`, `docker compose up -d`.
  *(Done 2026-07-17, with two real deviations from the original plan — see
  "Deviations found during implementation" below: (1) the local-pull-then-stream
  approach broke due to an ARM64/AMD64 architecture mismatch — pulling directly
  on the server instead; (2) `cap_drop: [ALL]` broke the container's s6-init/nginx
  stack — reverted, no capability restrictions applied. Container verified
  running and responding `HTTP 200` on `127.0.0.1:8082`, `~/webtop_data` ownership
  confirmed correct for uid/gid 1001.)*
- [ ] **`desktop-tls-cert`** *(depends on DNS record)* — Once the DNS record has
  propagated: `sudo certbot --apache -d desktop.darkplanet.pl` — a **dedicated**
  cert, separate from the existing multi-SAN `darkplanet.pl` cert (see rationale above).
- [ ] **`desktop-apache-vhost`** *(depends on docker + cert)* — New
  `/etc/apache2/sites-available/00X-desktop.darkplanet.pl.conf`: `:80` → 301
  redirect to `:443`; `:443` with the new cert, `sudo a2enmod proxy_wstunnel`
  enabled, `ProxyPass`/`ProxyPassReverse` to `http://127.0.0.1:8082/` with
  WebSocket `Upgrade`/`Connection` headers wired through, `AuthType Basic` +
  bcrypt `.htpasswd` (`htpasswd -B`) + `Require valid-user` wrapping the whole
  vhost. Reload with `sudo systemctl reload apache2`.
- [ ] **`desktop-fail2ban`** *(depends on vhost)* — Enable `fail2ban` (currently
  installed but inactive) and add a jail watching the new vhost's Apache
  auth-failure log entries.
- [ ] **`desktop-e2e-test`** *(depends on fail2ban)* — Log in through the
  browser via Basic Auth and confirm the desktop actually renders and streams
  through the reverse proxy over the public domain. This is the biggest open
  risk (Selkies is WebRTC-based — ICE/NAT behavior through a public Apache
  proxy is untested). If it doesn't work reliably, look at forcing
  TURN/relay-only ICE in the container's Selkies config, or fall back to a
  KasmVNC-based image variant (plain TCP/websocket, no WebRTC).
- [ ] **`webtop-data-backup`** *(depends on docker run)* — Add `~/webtop_data`
  to the existing `~/backups` routine already present on darkplanet.pl, so the
  persistent browser profile/session state survives a rebuild.

Decisions already locked in (don't re-litigate without a good reason):
Docker over native host desktop; public HTTPS + Basic Auth over a VPN/tunnel
(work PC can't run a tunnel client); dedicated cert over adding to the shared
multi-SAN cert; image built/pulled locally and piped to the server rather than
pulled on the production box.
