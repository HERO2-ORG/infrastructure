# Runner for test.sh: the backup scripts run here the way they run on the VMs,
# driving sibling containers through the mounted Docker socket.
FROM debian:bookworm-slim
ARG TARGETARCH
RUN apt-get update && apt-get install -y --no-install-recommends ca-certificates curl bzip2 docker.io shellcheck \
  && rm -rf /var/lib/apt/lists/*
RUN set -eu; \
  case "$TARGETARCH" in \
    amd64) sum=f415415624dcc452f2a02b8c33641791a8c6d6d3b65bbb3543fcf9a25151585c ;; \
    arm64) sum=a5f64aaab53d51e311fa3829124c5b703f2d14cf187d8640b6be3b2b49376465 ;; \
  esac; \
  curl -fsSLo /tmp/restic.bz2 "https://github.com/restic/restic/releases/download/v0.19.1/restic_0.19.1_linux_${TARGETARCH}.bz2"; \
  echo "$sum  /tmp/restic.bz2" | sha256sum -c -; \
  bunzip2 -c /tmp/restic.bz2 > /usr/local/bin/restic; chmod 0755 /usr/local/bin/restic; rm /tmp/restic.bz2
