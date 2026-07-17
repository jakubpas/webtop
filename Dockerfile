# Custom webtop image: Ubuntu-based (glibc) instead of the default Alpine
# flavor, with the official Google Chrome package installed alongside the
# stock Chromium. This exists solely because open-source Chromium builds
# (including the ones shipped by every distro, Alpine or otherwise) lack
# Google's proprietary OAuth API keys, so the browser-level "sign in to
# Chromium" sync feature can't persist across restarts. Google Chrome ships
# its own valid keys and only distributes glibc (.deb/.rpm) builds - hence
# the Ubuntu base instead of Alpine here.
FROM linuxserver/webtop:ubuntu-xfce

RUN apt-get update && \
    apt-get install -y --no-install-recommends wget gnupg ca-certificates && \
    wget -q -O /tmp/google-chrome-key.pub https://dl.google.com/linux/linux_signing_key.pub && \
    gpg --dearmor -o /usr/share/keyrings/google-chrome.gpg /tmp/google-chrome-key.pub && \
    rm /tmp/google-chrome-key.pub && \
    echo "deb [arch=amd64 signed-by=/usr/share/keyrings/google-chrome.gpg] http://dl.google.com/linux/chrome/deb/ stable main" \
      > /etc/apt/sources.list.d/google-chrome.list && \
    apt-get update && \
    apt-get install -y --no-install-recommends google-chrome-stable && \
    rm -rf /var/lib/apt/lists/* && \
    # NOTE: deliberately NOT purging wget/gnupg afterward - google-chrome-stable
    # itself depends on gnupg (used for its own repo signing verification), so
    # a `apt-get purge gnupg` silently drags Chrome down with it via apt's
    # dependency resolver. Not worth the ~15MB saved.
    # Container always runs as a non-root user (PUID/PGID), so --no-sandbox
    # isn't strictly required for that reason, but is kept for parity with
    # the existing Chromium CHROME_ARGS behavior and to avoid any sandbox
    # namespace restrictions inside Docker. --password-store=basic matches
    # the existing Chromium setup (avoids depending on a system keyring that
    # isn't present in this minimal desktop). Desktop file path is located
    # dynamically since the .deb doesn't always drop it in the same spot
    # across distro/package versions.
    desktop_file=$(find /usr/share/applications -iname 'google-chrome*.desktop' | head -n1) && \
    if [ -n "$desktop_file" ]; then \
      sed -i "s|Exec=/usr/bin/google-chrome-stable %U|Exec=/usr/bin/google-chrome-stable --no-sandbox --password-store=basic %U|" "$desktop_file"; \
    else \
      echo "WARNING: google-chrome .desktop file not found - shortcut will need Exec flags added manually"; \
    fi
