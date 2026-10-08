# Runs the unit tests under bash 3.2 (the macOS default) with busybox awk/sed.
FROM bash:3.2
RUN apk add --no-cache git diffutils \
 && git clone --depth 1 --branch v1.11.0 https://github.com/bats-core/bats-core.git /opt/bats \
 && /opt/bats/install.sh /usr/local
