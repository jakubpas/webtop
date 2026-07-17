# AGENTS.md — webtop / dev.darkplanet.pl project

Context for future work on this repo. This branch (`darkplanet`) turns the local
`webtop` launcher script into a permanently-hosted, authenticated remote desktop
at **https://dev.darkplanet.pl**, running on the `darkplanet.pl` production
server.

## Goal

Run the `linuxserver/webtop` Docker container on the `darkplanet.pl` server,
exposed at `dev.darkplanet.pl` over HTTPS, protected by Basic Auth, so it
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
    www.signum-temporis.pl) — **do not add dev.darkplanet.pl to this one.**
  - `www.darkplanet.pl` (separate, single-domain).
- Plan: issue a **new, dedicated cert** for `dev.darkplanet.pl`:
  `sudo certbot --apache -d dev.darkplanet.pl` (run only after the DNS A
  record above is live and propagated).

## Apache (2.4.58, prefork MPM)

- Vhosts: `/etc/apache2/sites-available/*.conf`, symlinked into `sites-enabled/`.
  Existing numbering: `000-default`, `001-darkplanet.pl`, `003-jakubpas.net`,
  `004-signum-temporis.pl(+le-ssl)`, `005-download.jakubpas.net`. New vhost should
  be `002-dev.darkplanet.pl.conf` (or next free number).
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
- **Image is a custom build now** (`webtop-ubuntu-chrome:local`, built from the
  `Dockerfile` in this repo, `FROM linuxserver/webtop:ubuntu-xfce` + Google
  Chrome installed on top — see "Custom image: Ubuntu + real Google Chrome"
  below for why). Originally this was a plain `linuxserver/webtop:latest`
  pull; see "Deviations found during implementation" for why local-pull-then-
  stream was abandoned (ARM64 vs AMD64 mismatch) in favor of doing image
  operations directly on the server. Same reasoning still applies to the
  build: `cd ~/webtop && sudo docker compose build && sudo docker compose up -d`
  run directly on darkplanet.pl — AMD64 native, no cross-arch ambiguity, and
  it's just an apt-install layer (not a heavy compile), so it doesn't
  meaningfully compete with production services on this host.
  - `~/webtop_data` (persistent config/profile volume) is just an empty dir
    created directly on the server: `mkdir -p ~/webtop_data`.
  - **Back this dir up manually**: `~/backups` on the server is an ad-hoc
    dumping ground, not an automated routine (no crontab exists for `kuba`).
    Use `scripts/backup-webtop-data.sh` (checked into this repo) to snapshot
    `~/webtop_data` to `~/backups/webtop_data_<timestamp>.tar.gz` by hand
    before any risky container/host change.
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
  - Keep `--shm-size=1gb`. The `SELKIES_*` env vars were later retuned for
    performance over quality — see "Post-deployment tuning & known quirks"
    below (no longer the original high-DPI retina settings).
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
  hashed (`htpasswd -B /etc/apache2/.htpasswd-dev kuba`), HTTPS-only so
  credentials are encrypted in transit. This is intentionally simple per the
  current requirements — no SSO/2FA layer requested.
- `fail2ban` is installed and running (`apache-auth` jail, `backend = auto`
  explicitly set — Ubuntu's default `backend = systemd` doesn't work for
  Apache's file-based error log, see deviations note above), watching
  `/var/log/apache2/error.log` for `AH01617` Basic Auth failures. 5 failures
  in 10 minutes → 1 hour ban. Config: `fail2ban/jail.d/dev-darkplanet.conf`
  in this repo. To unban an IP: `sudo fail2ban-client set apache-auth unbanip <ip>`.
- `ufw` is inactive on this host and **intentionally left alone** — not part of
  this project's scope; security relies on webtop being loopback-only + Apache
  TLS + Basic Auth + fail2ban instead of a host firewall change on a shared
  production box.
- Container itself runs as `kuba`'s uid (1001) via PUID/PGID — no root-in-container
  surprises expected from `linuxserver/webtop`'s standard s6-init model.

## Streaming through the reverse proxy — resolved, notes for the future

Originally flagged as the biggest open risk: `linuxserver/webtop` uses
**Selkies**, and the concern was that its WebRTC media negotiation (ICE
candidates over NAT) might behave badly once accessed from an arbitrary public
client through a reverse proxy. **This turned out not to be the actual
problem** — in practice Selkies in this image tunnels its stream over a plain
WebSocket at the `/websocket` path (confirmed by inspecting the container's
internal nginx config, `/etc/nginx/http.d/default.conf`), not raw WebRTC media
through the proxy. Ordinary WebSocket reverse-proxying works fine here.

The actual bug hit was much simpler: `RewriteEngine On` was missing from the
`:443` vhost (it does not inherit from the `:80` vhost above it), so the
WebSocket rewrite rule silently no-op'd and everything fell through to plain
`mod_proxy_http`, which can't perform a protocol Upgrade — surfacing in the
browser as "WebSocket disconnected. Attempting to reconnect...". Fixed by
adding `RewriteEngine On` explicitly to the SSL vhost. If this class of issue
ever resurfaces (e.g. after further vhost edits), verify with:
```bash
curl -sk -v -u 'kuba:<password>' \
  -H "Connection: Upgrade" -H "Upgrade: websocket" \
  -H "Sec-WebSocket-Version: 13" -H "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==" \
  https://dev.darkplanet.pl/websocket
```
Expect `HTTP/1.1 101 Switching Protocols` in the response headers — anything
else (200, hanging, connection reset) means the Upgrade isn't being proxied
correctly.

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

**Live and working as of 2026-07-17.** All 8 build steps complete —
`https://dev.darkplanet.pl` is deployed, TLS + Basic Auth + fail2ban are
active, and the desktop has been confirmed streaming correctly in-browser.
See the checked-off plan below for what was done and the real issues hit
along the way (worth reading before making further changes).

**Renamed from `desktop.darkplanet.pl` to `dev.darkplanet.pl` on 2026-07-17**
(same day as initial go-live) — the Docker container itself was never
touched/restarted for this, only the DNS record, TLS cert, Apache vhost,
`.htpasswd` file, and fail2ban jail were swapped over. Old `desktop`
subdomain was fully decommissioned (not kept as an alias): DNS `A` record
renamed to `dev`, dedicated cert `desktop.darkplanet.pl` deleted via
`certbot delete`, old vhost file and `.htpasswd-desktop` removed. All repo
file names/contents below already reflect the new `dev.darkplanet.pl` name.

## Post-deployment tuning & known quirks (2026-07-17, after initial go-live)

A few things came up in day-to-day use after the initial deployment was
confirmed working. Recorded here so they aren't re-discovered from scratch.

- **Chromium desktop shortcut.** `/config/Desktop` ships empty in the image —
  no icon on the desktop by default, even though Chromium itself *is* present
  (`/usr/bin/chromium`, Alpine-based image, XFCE desktop). Fixed by copying
  the existing `.desktop` file onto the persistent volume:
  ```bash
  sudo docker exec webtop cp /usr/share/applications/chromium.desktop /config/Desktop/chromium.desktop
  sudo docker exec webtop chown abc:abc /config/Desktop/chromium.desktop
  sudo docker exec webtop chmod +x /config/Desktop/chromium.desktop
  ```
  This persists (it's on the `/config` volume). XFCE may show it with an
  "untrusted" shield the first time — right-click → **Allow Launching** once.
- **Chromium profile (passwords, cookies, bookmarks) persists** across
  container restarts — it lives at `/config/.config/chromium`, which is on the
  `~/webtop_data` volume, not the container's writable layer.
- **Chromium "profile in use by another process" error after every container
  restart.** Chromium's `SingletonLock`/`SingletonCookie`/`SingletonSocket`
  files embed the container's hostname, which changes every time the
  container is recreated (`docker compose up -d`, image update, host reboot,
  etc.), so the *previous* container's stale lock blocks the *new* one from
  starting Chromium. Fix (needs to be re-run after every container
  restart/recreate, currently manual — not yet automated):
  ```bash
  sudo docker exec webtop rm -f /config/.config/chromium/SingletonLock \
    /config/.config/chromium/SingletonCookie /config/.config/chromium/SingletonSocket
  ```
  Possible future improvement (not yet done, user declined for now): add a
  small script to `svc-de` or an s6 `cont-init.d` hook that clears these on
  every container boot automatically.
- **Performance tuning — no hardware video encode is available.** The host
  has an Intel iGPU (`/dev/dri/card0` exists on the *host*, not passed into
  the container), but it doesn't matter: Selkies' `x264enc`/pixelflux path
  hard-codes `use_cpu = True` and disables the VAAPI render node whenever the
  encoder is `x264enc` — only `nvh264enc` (NVIDIA/NVENC) would use hardware,
  and there's no NVIDIA GPU here. So encoding is always CPU-bound regardless
  of encoder choice; the only real levers are resolution, framerate, and CRF.
  Current tuning in `docker-compose.yml` (user explicitly prioritized
  performance over quality, but wanted a "not too small" desktop for
  browsing):
  - `SELKIES_MANUAL_WIDTH/HEIGHT=1600x900`, `SELKIES_SCALING_DPI=96` (down
    from the original `2520x1240`/`192` DPI retina-tuned settings).
  - `SELKIES_FRAMERATE=15` (fewer encodes/sec = direct CPU win).
  - `SELKIES_H264_CRF=38` (higher CRF = cheaper/faster encode, lower quality —
    acceptable since quality isn't a priority here).
  - `SELKIES_ENCODER=x264enc` kept (not switched to `jpeg` — both are
    CPU-bound with no hardware path available here, and `x264enc`'s
    motion-compensated compression is generally cheaper overall for typical
    desktop/browsing content than re-encoding full JPEG frames repeatedly).
  - Verify current load with `sudo docker stats --no-stream webtop`.
- **`pulseaudio` and `nginx` inside the container are not worth stripping.**
  `pulseaudio` costs ~1% CPU / ~5MB RAM and is a structural dependency —
  Selkies' own startup script calls `pactl load-module` to create audio sinks
  even when audio is unused, so removing it breaks Selkies' init. `nginx`
  barely registers in `top` and is the container's internal router for the
  web UI/websocket/file-manager — not optional. Neither is a real lever for
  the CPU usage seen; that's almost entirely Selkies' video encode (see
  above).
- **Ad-hoc package installs (e.g. `sudo apk add htop`) do not persist.** Only
  `/config` (the `webtop_data` volume) survives a container recreate;
  anything installed into the container's writable layer (via `apk`, etc.) is
  gone on the next `docker compose up -d` / image update / reboot. If a tool
  needs to persist permanently, it should go into a custom Dockerfile layered
  on `linuxserver/webtop`, or an init script under `/config` — not yet done,
  raise it again if actually needed.

## Custom image: Ubuntu + real Google Chrome (2026-07-17)

**Why:** open-source Chromium (shipped by every distro, including the
original Alpine-based image) lacks Google's proprietary OAuth API keys, so
the browser-level "sign in to Chromium" sync (top-right avatar, syncing
bookmarks/settings to a Google account) can't persist across restarts -
purely a limitation of the binary, not of profile persistence (regular
website logins/passwords/cookies already persisted fine before this change).
Google only distributes the real `google-chrome-stable` package as glibc
(.deb/.rpm) builds, so this required switching off Alpine (musl) onto an
Ubuntu base.

**What changed:**
- `Dockerfile` (new, checked into this repo) - builds
  `FROM linuxserver/webtop:ubuntu-xfce` and installs `google-chrome-stable`
  from Google's own apt repo. Built directly on darkplanet.pl via
  `docker compose build` - AMD64 native (avoids the ARM64/AMD64 mismatch
  noted below) and it's just an apt install layer, not a heavy compile, so it
  doesn't meaningfully compete with production services on this shared host.
- `docker-compose.yml` - `image: linuxserver/webtop:latest` replaced with a
  `build: { context: ., dockerfile: Dockerfile }` + `image: webtop-ubuntu-chrome:local`
  pair, so `docker compose build && docker compose up -d` (or
  `docker compose up -d --build`) rebuilds and redeploys in one step.
- Google Chrome's `.desktop` file `Exec` line was patched at build time to
  add `--no-sandbox --password-store=basic` (parity with the previous
  Chromium `CHROME_ARGS` env var, which only chromium's own launcher script
  read - Chrome needs its flags set directly since it has its own launcher).
- After deploying, `google-chrome.desktop` was copied onto
  `/config/Desktop/` (same one-time step as the earlier Chromium shortcut).
- **Chromium was later removed entirely** (2026-07-17, same day - user didn't
  want two browsers once Chrome worked): `Dockerfile` now also
  `apt-get purge -y chromium chromium-common` plus `rm -f
  /usr/bin/chromium-browser` (an orphaned launcher script not tracked by
  dpkg, left behind after the purge - harmless dead cruft but removed for
  tidiness). Confirmed safe: Chrome has no dependency on Chromium, and
  `update-alternatives` already re-points `x-www-browser`/`gnome-www-browser`
  at `google-chrome-stable` automatically. The old `chromium.desktop`
  shortcut and cached profile (`/config/.config/chromium`,
  `/config/.cache/chromium`) were also deleted from the `/config` volume.
- **Gotcha hit while building:** the Dockerfile originally tried
  `apt-get purge -y wget gnupg` afterward to slim the image, but
  `google-chrome-stable` itself **depends on `gnupg`** (used for its own repo
  signing verification) - purging `gnupg` silently dragged `google-chrome-stable`
  down with it via apt's dependency resolver (visible in the build log as
  `gnupg* google-chrome-stable* wget*` all marked for removal together, despite
  only `wget`/`gnupg` being named on the purge command line). Fixed by simply
  not purging `wget`/`gnupg` - not worth the ~15MB saved.
- **Image is bigger than the original**: 5.35GB uncompressed vs. 3.33GB
  before (~60% bigger) - the Ubuntu-xfce base itself is heavier than Alpine,
  plus Chrome's own ~135MB package and dependencies. Still runs fine within
  the existing `mem_limit: 2g` / `cpus: 2` caps. Removing chromium afterward
  only freed a few MB (its main cost was already paid by the Ubuntu base
  switch, not chromium itself), so don't expect this to meaningfully shrink
  the image again.
- The stale-Chromium-`SingletonLock`-on-restart issue (see above) applies
  identically to Google Chrome's own profile dir
  (`/config/.config/google-chrome/Singleton*`) - same fix, same caveat about
  it not yet being automated.

## Image size trim + volume path fix (2026-07-17, second pass)

Two follow-up fixes made after the initial Ubuntu+Chrome switch, both
verified end-to-end on darkplanet.pl (rebuild, recreate, HTTP 200, public
`https://dev.darkplanet.pl` still 401s pre-auth, Chrome profile/Desktop
shortcut confirmed intact across the recreate):

- **`Dockerfile` is now multi-stage.** A first attempt at trimming bloat
  (`docker-ce`/`docker-ce-cli`/`containerd.io`/`docker-buildx-plugin`/
  `docker-compose-plugin` - unused Docker-in-Docker support linuxserver.io
  bundles for their "mods" system - plus swapping `locales-all` for just
  `locales` + `locale-gen en_US.UTF-8`) looked right but **did not actually
  shrink the image** (stayed at 5.36GB): Docker layers are additive/union-
  based, so deleting files in a later `RUN` layer only adds whiteout
  markers - the deleted files' bytes are still physically present in the
  earlier base-image layer and still counted in the image size. Fixed by
  restructuring as `FROM ... AS builder` (does the apt work) followed by a
  `FROM scratch` final stage that does `COPY --from=builder / /` (copies the
  final *merged* filesystem view, i.e. post-whiteout, into one fresh layer)
  plus explicit re-declaration of the base image's `ENV`/`EXPOSE`/`VOLUME`/
  `ENTRYPOINT`/`LABEL` (captured via `docker inspect linuxserver/webtop:ubuntu-xfce`,
  since `COPY --from` doesn't carry image config over). Actual result:
  **5.36GB → 3.74GB** (~1.6GB saved - more than the ~576MB purge target
  alone, since squashing also collapsed general layer/apt-cache overhead
  elsewhere in the base image). `docker buildx build --squash` was
  considered first but isn't available in this buildx version without the
  containerd image store's experimental squash support; the manual
  `COPY --from=builder / /` technique is the standard workaround and needs
  no daemon flags.
- **`docker-compose.yml`'s volume mount was silently pointing at the wrong
  host path.** It read `${HOME}/webtop_data:/config`, but every deploy
  command in this project is `sudo docker compose ...` (`kuba` isn't in the
  `docker` group), and `sudo` resets `$HOME` to `/root` unless `-E` is
  passed - so `${HOME}` was resolving to `/root/webtop_data`, not
  `/home/kuba/webtop_data` as this doc and `scripts/backup-webtop-data.sh`
  assume. Discovered because `~/webtop_data` on the server was nearly empty
  (just created dirs, no real profile data) while `/root/webtop_data` held
  the actual Chrome profile/Desktop shortcut/XFCE config. No data was lost,
  but the documented backup path was silently backing up an empty directory.
  Fixed by hardcoding the path in `docker-compose.yml`
  (`/home/kuba/webtop_data:/config`, no `${HOME}` interpolation) so it's
  invariant to how the command is invoked, then migrated
  (`rsync -a --delete /root/webtop_data/ /home/kuba/webtop_data/` +
  `chown -R 1001:1001`) and deleted the stale `/root/webtop_data`. Backed up
  both the pre-migration `/root/webtop_data` and the final merged
  `/home/kuba/webtop_data` to `~/backups/` before/after the change.

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
- [x] **`desktop-tls-cert`** *(depends on DNS record)* — Once the DNS record has
  propagated: `sudo certbot --apache -d dev.darkplanet.pl` — a **dedicated**
  cert, separate from the existing multi-SAN `darkplanet.pl` cert (see rationale above).
  *(Done 2026-07-17 — cert issued at `/etc/letsencrypt/live/dev.darkplanet.pl/`,
  ECDSA, valid until 2026-10-15, covered by the existing auto-renewal timer.
  Certbot's own auto-install step failed with "vhost ambiguity" since no vhost
  exists for this domain yet — harmless/expected, the vhost is hand-built in
  the next step instead of letting certbot auto-inject it.)*
- [x] **`desktop-apache-vhost`** *(depends on docker + cert)* — New
  `/etc/apache2/sites-available/00X-dev.darkplanet.pl.conf`: `:80` → 301
  redirect to `:443`; `:443` with the new cert, `sudo a2enmod proxy_wstunnel`
  enabled, `ProxyPass`/`ProxyPassReverse` to `http://127.0.0.1:8082/` with
  WebSocket `Upgrade`/`Connection` headers wired through, `AuthType Basic` +
  bcrypt `.htpasswd` (`htpasswd -B`) + `Require valid-user` wrapping the whole
  vhost. Reload with `sudo systemctl reload apache2`.
  *(Done 2026-07-17 — config checked into `apache/002-dev.darkplanet.pl.conf`
  in this repo, deployed as `/etc/apache2/sites-available/002-dev.darkplanet.pl.conf`
  on the server. `mod_proxy_wstunnel` enabled; WebSocket upgrade routed via a
  `RewriteCond %{HTTP:Upgrade} =websocket` rule to `ws://127.0.0.1:8082/` ahead
  of the plain `ProxyPass`. Basic Auth via `/etc/apache2/.htpasswd-dev`
  (bcrypt, user `kuba`, mode 640, owned `root:www-data` — password generated
  and shared with the user directly, NOT committed anywhere). Verified live:
  no-auth → 401, wrong password → 401, correct password → 200,
  `http://` → 301 redirect to `https://`.)*
- [x] **`desktop-fail2ban`** *(depends on vhost)* — Enable `fail2ban` (currently
  installed but inactive) and add a jail watching the new vhost's Apache
  auth-failure log entries.
  *(Done 2026-07-17 — `fail2ban` wasn't actually installed (earlier "inactive"
  check was misleading — systemd reports "inactive" for a nonexistent unit
  too); installed via apt. Jail config checked into
  `fail2ban/jail.d/dev-darkplanet.conf`, deployed to
  `/etc/fail2ban/jail.d/dev-darkplanet.conf`. Hit one real snag — Ubuntu's
  `defaults-debian.conf` sets `backend = systemd` (journal) globally, so the
  jail was checking journal entries instead of the actual
  `/var/log/apache2/error.log` file Apache writes to, and never matched
  anything. Fixed by explicitly setting `backend = auto` in the jail. Verified
  live: 7 deliberate failed-Basic-Auth attempts triggered an actual ban of the
  testing IP after the 5-attempt threshold; unbanned it afterward to keep
  testing.)*
- [x] **`desktop-e2e-test`** *(depends on fail2ban)* — Log in through the
  browser via Basic Auth and confirm the desktop actually renders and streams
  through the reverse proxy over the public domain. This is the biggest open
  risk (Selkies is WebRTC-based — ICE/NAT behavior through a public Apache
  proxy is untested). If it doesn't work reliably, look at forcing
  TURN/relay-only ICE in the container's Selkies config, or fall back to a
  KasmVNC-based image variant (plain TCP/websocket, no WebRTC).
  *(Done 2026-07-17 — first attempt showed "WebSocket disconnected. Attempting
  to reconnect..." looping in the browser. Root cause: `RewriteEngine On` was
  missing from the `:443` vhost block (it doesn't inherit from the `:80` block
  above it) — silently no-op'd the WebSocket rewrite rule, so `/websocket`
  requests fell through to plain `mod_proxy_http`, which cannot perform an
  Upgrade. Also discovered along the way that Selkies's actual WebSocket
  endpoint is `/websocket` specifically (inspected the container's internal
  nginx config at `/etc/nginx/http.d/default.conf` to find this — not
  documented anywhere obvious). Fixed by adding `RewriteEngine On` to the SSL
  vhost; verified via `curl` that `/websocket` now returns
  `HTTP/1.1 101 Switching Protocols`, then confirmed by the user in-browser
  that the desktop streams correctly. The WebRTC/ICE-through-proxy risk turned
  out to be a non-issue — Selkies here tunnels over a plain WebSocket, not
  raw WebRTC media, so ordinary reverse-proxying works fine once the Upgrade
  path is correctly wired.)*
- [x] **`webtop-data-backup`** *(depends on docker run)* — Add `~/webtop_data`
  to the existing `~/backups` routine already present on darkplanet.pl, so the
  persistent browser profile/session state survives a rebuild.
  *(Done 2026-07-17 — turns out there's no automated backup routine to "fold
  into" after all: `~/backups` is just an ad-hoc manual dumping ground, no
  crontab exists for `kuba`. Added `scripts/backup-webtop-data.sh` instead,
  matching that existing manual pattern rather than introducing new cron
  automation on a shared production host unasked. Tested — produces
  `~/backups/webtop_data_<timestamp>.tar.gz` on the server. Run it by hand
  before any risky container/host change.)*

Decisions already locked in (don't re-litigate without a good reason):
Docker over native host desktop; public HTTPS + Basic Auth over a VPN/tunnel
(work PC can't run a tunnel client); dedicated cert over adding to the shared
multi-SAN cert; image built/pulled locally and piped to the server rather than
pulled on the production box.
