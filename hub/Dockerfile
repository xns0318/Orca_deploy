ARG BASE_IMAGE
FROM ${BASE_IMAGE}
ARG ORCA_VERSION
ARG ORCA_DEB_URL
ARG ORCA_DEB_SHA256
RUN apt-get update && apt-get install -y --no-install-recommends \
      ca-certificates curl tini xvfb xauth dbus-x11 git openssh-client \
      libgtk-3-0 libnotify4 libnss3 libxss1 libxtst6 libatspi2.0-0 \
      libuuid1 libsecret-1-0 libasound2 libgbm1 \
    && curl -fsSL --retry 3 --connect-timeout 20 --max-time 900 \
      --proto '=https' --proto-redir '=https' "$ORCA_DEB_URL" -o /tmp/orca.deb \
    && printf '%s  /tmp/orca.deb\n' "$ORCA_DEB_SHA256" | sha256sum -c - \
    && test "$(dpkg-deb -f /tmp/orca.deb Version)" = "$ORCA_VERSION" \
    && dpkg-deb -x /tmp/orca.deb / \
    && rm -f /tmp/orca.deb \
    && rm -rf /var/lib/apt/lists/* \
    && groupadd --gid 10001 orca \
    && useradd --uid 10001 --gid 10001 --create-home --shell /bin/bash orca \
    && chmod 700 /home/orca
COPY . /opt/orca-hub/
RUN chmod 755 /opt/orca-hub /opt/orca-hub/entrypoint.sh /opt/orca-hub/hubctl \
    && chmod 644 /opt/orca-hub/*.cjs \
    && ln -s /opt/orca-hub/hubctl /usr/local/bin/hubctl
ENV HOME=/home/orca ORCA_USER_DATA_PATH=/home/orca/.config/orca ORCA_HUB_REQUIRE_MONITOR=1 ORCA_HUB_REQUIRE_BRIDGE=1 ORCA_DESKTOP_PORT=6769
USER 10001:10001
WORKDIR /home/orca
HEALTHCHECK --interval=15s --timeout=10s --start-period=60s --retries=3 CMD ["hubctl", "health"]
ENTRYPOINT ["/usr/bin/tini", "-g", "--", "/opt/orca-hub/entrypoint.sh"]
