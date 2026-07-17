# Custom webtop image: Ubuntu-based (glibc) instead of the default Alpine
# flavor, with the official Google Chrome package installed in place of the
# stock Chromium. This exists solely because open-source Chromium builds
# (including the ones shipped by every distro, Alpine or otherwise) lack
# Google's proprietary OAuth API keys, so the browser-level "sign in to
# Chromium" sync feature can't persist across restarts. Google Chrome ships
# its own valid keys and only distributes glibc (.deb/.rpm) builds - hence
# the Ubuntu base instead of Alpine here.
#
# Built as a multi-stage image: the `builder` stage does all the apt
# install/purge work, then the final stage does `COPY --from=builder / /`
# onto a bare `scratch` base. This is necessary (not just cosmetic) because
# Docker layers are additive/union-based - deleting files in a later RUN
# layer (see the trim step below) only adds "whiteout" markers, it does NOT
# reclaim the disk space those files occupy in the earlier base-image layer,
# so a naive single-stage build here still weighs ~5.36GB even after purging
# ~576MB of packages. `COPY --from=builder / /` instead copies the final
# merged filesystem view (post-whiteout) into a single fresh layer, so
# deleted files are actually gone from the resulting image. All of the base
# image's runtime metadata (ENV/EXPOSE/VOLUME/ENTRYPOINT/LABEL) has to be
# re-declared explicitly in the final stage since COPY does not carry image
# config over - captured via `docker inspect linuxserver/webtop:ubuntu-xfce`.
FROM linuxserver/webtop:ubuntu-xfce AS builder

RUN apt-get update && \
    apt-get install -y --no-install-recommends wget gnupg ca-certificates && \
    wget -q -O /tmp/google-chrome-key.pub https://dl.google.com/linux/linux_signing_key.pub && \
    gpg --dearmor -o /usr/share/keyrings/google-chrome.gpg /tmp/google-chrome-key.pub && \
    rm /tmp/google-chrome-key.pub && \
    echo "deb [arch=amd64 signed-by=/usr/share/keyrings/google-chrome.gpg] http://dl.google.com/linux/chrome/deb/ stable main" \
      > /etc/apt/sources.list.d/google-chrome.list && \
    apt-get update && \
    apt-get install -y --no-install-recommends google-chrome-stable && \
    # Chromium is no longer needed once Chrome is installed - user has no use
    # for two browsers. `chromium`/`chromium-common` don't depend on Chrome
    # (confirmed safe to remove independently - unlike the gnupg/wget
    # situation below), and apt's update-alternatives automatically re-points
    # x-www-browser/gnome-www-browser at google-chrome-stable once chromium
    # is gone.
    apt-get purge -y chromium chromium-common && \
    apt-get autoremove -y && \
    rm -rf /var/lib/apt/lists/* && \
    # Leftover orphaned launcher script not tracked by dpkg (dpkg -S finds
    # nothing for it) - the actual chromium binary/libs/.desktop entry are
    # already gone via the purge above, this is just harmless dead cruft.
    rm -f /usr/bin/chromium-browser && \
    # NOTE: deliberately NOT purging wget/gnupg afterward - google-chrome-stable
    # itself depends on gnupg (used for its own repo signing verification), so
    # a `apt-get purge gnupg` silently drags Chrome down with it via apt's
    # dependency resolver. Not worth the ~15MB saved.
    # Container always runs as a non-root user (PUID/PGID), so --no-sandbox
    # isn't strictly required for that reason, but is kept for parity with
    # the previous Chromium CHROME_ARGS behavior and to avoid any sandbox
    # namespace restrictions inside Docker. --password-store=basic matches
    # the previous Chromium setup (avoids depending on a system keyring that
    # isn't present in this minimal desktop). --test-type suppresses the
    # "You are using an unsupported command-line flag: --no-sandbox" infobar
    # Chrome otherwise shows on every launch - purely cosmetic, has no other
    # effect (it's the standard flag automated/CI Chrome runs use to silence
    # that warning; does not disable the sandbox any further than --no-sandbox
    # already does). Desktop file path is located dynamically since the .deb
    # doesn't always drop it in the same spot across distro/package versions.
    desktop_file=$(find /usr/share/applications -iname 'google-chrome*.desktop' | head -n1) && \
    if [ -n "$desktop_file" ]; then \
      sed -i "s|Exec=/usr/bin/google-chrome-stable %U|Exec=/usr/bin/google-chrome-stable --no-sandbox --test-type --password-store=basic %U|" "$desktop_file"; \
    else \
      echo "WARNING: google-chrome .desktop file not found - shortcut will need Exec flags added manually"; \
    fi

# Trim other bloat baked into the linuxserver/webtop:ubuntu-xfce base that
# this deployment has no use for:
# - Docker-in-Docker (docker-ce/docker-ce-cli/containerd.io/docker-buildx-
#   plugin/docker-compose-plugin, ~340MB) - linuxserver.io bundles this for
#   their optional "mods" system; we don't run docker inside this container
#   (no socket mounted, no mods used), so it's dead weight. Confirmed via
#   `apt-get purge --simulate` that removing these 5 packages alone doesn't
#   cascade into anything else (xfce4/desktop stays intact).
# - locales-all (~236MB) ships precompiled data for EVERY locale; this
#   desktop only ever runs LANG=en_US.UTF-8, so swap it for the much smaller
#   `locales` package and generate just that one locale.
# NOTE: deliberately NOT touching the gcc/g++/cmake/libc6-dev toolchain
# (~270MB) - `apt-get purge --simulate` showed removing it cascades into
# purging `xfce4`/`xfce4-session` themselves (something in the base image's
# dependency chain ties the desktop metapackage to having a compiler present),
# so it's not safely removable without breaking the desktop environment.
RUN apt-get purge -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin && \
    apt-get purge -y locales-all && \
    apt-get update && \
    apt-get install -y --no-install-recommends locales && \
    locale-gen en_US.UTF-8 && \
    apt-get autoremove -y && \
    apt-get clean && \
    rm -rf /var/lib/apt/lists/*

# htop: requested for interactive CPU/RAM monitoring inside the desktop
# (e.g. via a terminal) - ad-hoc `apk`/`apt` installs into the container's
# writable layer don't persist across recreates, so it needs to live here to
# stick around permanently.
RUN apt-get update && \
    apt-get install -y --no-install-recommends htop && \
    apt-get clean && \
    rm -rf /var/lib/apt/lists/*

# Final stage: copy the builder's merged rootfs (with purged files actually
# gone) into a fresh single layer on scratch, then re-declare the runtime
# metadata that linuxserver/webtop:ubuntu-xfce normally provides but which
# COPY --from doesn't carry over automatically.
FROM scratch

COPY --from=builder / /

ENV PATH="/lsiopy/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin" \
    HOME="/config" \
    LANGUAGE="en_US.UTF-8" \
    LANG="en_US.UTF-8" \
    TERM="xterm" \
    S6_CMD_WAIT_FOR_SERVICES_MAXTIME="0" \
    S6_VERBOSITY="1" \
    S6_STAGE2_HOOK="/docker-mods" \
    VIRTUAL_ENV="/lsiopy" \
    DISPLAY=":1" \
    PERL5LIB="/usr/local/bin" \
    START_DOCKER="true" \
    PULSE_RUNTIME_PATH="/defaults" \
    SELKIES_INTERPOSER="/usr/lib/selkies_joystick_interposer.so" \
    NVIDIA_DRIVER_CAPABILITIES="all" \
    DISABLE_ZINK="false" \
    DISABLE_DRI3="false" \
    SELKIES_ENCODER="x264enc,jpeg" \
    TITLE="Ubuntu XFCE" \
    LSIO_FIRST_PARTY="true"

LABEL maintainer="thelamer" \
      org.opencontainers.image.authors="linuxserver.io" \
      org.opencontainers.image.description="webtop image by linuxserver.io" \
      org.opencontainers.image.documentation="https://docs.linuxserver.io/images/docker-webtop" \
      org.opencontainers.image.licenses="GPL-3.0-only" \
      org.opencontainers.image.source="https://github.com/linuxserver/docker-webtop" \
      org.opencontainers.image.title="Webtop" \
      org.opencontainers.image.url="https://github.com/linuxserver/docker-webtop/packages" \
      org.opencontainers.image.vendor="linuxserver.io"

EXPOSE 3000/tcp 3001/tcp
VOLUME ["/config"]
WORKDIR /
ENTRYPOINT ["/init"]

