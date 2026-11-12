# server/Dockerfile

# ── Admin UI asset build (Tailwind + DaisyUI) ────────────────────────────────
# Builds the LiveView admin stylesheet from server/assets/ into priv/static/assets/app.css.
# Runs in a Node stage so the runtime/builder images stay Node-free. Scans lib/ for the
# Tailwind class usage in the LiveView (~H) templates. See `make assets` for local rebuilds.
FROM node:20-alpine AS assets
WORKDIR /app
COPY assets assets
COPY lib lib
RUN cd assets && npm ci --no-audit --no-fund && npm run build

# glibc builder (Debian), NOT alpine/musl: the release bundles ERTS, and the hardened runtime base below is glibc.
# Pinned by digest (container-hardening guideline); Renovate bumps tag + digest together.
FROM elixir:1.20.5-otp-29@sha256:23642332ffac151b68f7ba0029e93fba2ba6083c0944efc06087957e2109e21c AS builder
WORKDIR /app
RUN mix local.hex --force && mix local.rebar --force
# ADR-019: single OTP application — one mix.exs at the project root, no umbrella apps.
COPY mix.exs mix.lock ./
RUN mix deps.get --only prod
COPY . .
# Overwrite the committed app.css with the freshly built one (source of truth = assets/).
COPY --from=assets /app/priv/static/assets/app.css priv/static/assets/app.css
ARG GIT_COMMIT=unknown
ARG BUILD_TIME=unknown
ARG RELEASE_VERSION=unknown
ENV GIT_COMMIT=${GIT_COMMIT}
ENV BUILD_TIME=${BUILD_TIME}
ENV RELEASE_VERSION=${RELEASE_VERSION}
RUN MIX_ENV=prod mix release

# ── Shared libraries the release needs but the hardened base does not ship ───────────────────────
# Collects every shared library the ERTS / NIF binaries link against, minus the ones the base provides
# (glibc core, OpenSSL). Paths are preserved (--parents) so they land in the base's LD_LIBRARY_PATH
# (/usr/lib/<multiarch>). Fails the build if a binary has an unresolved library.
FROM builder AS libs
RUN set -eu; mkdir -p /libs; \
    find /app/_build/prod/rel/nebu -type f \( -name '*.so' -o -name 'beam.smp' -o -name 'erlexec' -o -name 'erl_child_setup' -o -name 'inet_gethost' -o -name 'epmd' \) > /tmp/elfs; \
    : > /tmp/needed; \
    while read -r f; do \
      out="$(ldd "$f" 2>&1 || true)"; \
      if echo "$out" | grep -q 'not found'; then echo "unresolved library for $f:"; echo "$out"; exit 1; fi; \
      echo "$out" | awk '/=> \//{print $3}' >> /tmp/needed; \
    done < /tmp/elfs; \
    sort -u /tmp/needed \
      | grep -Ev '/(libc|libm|libdl|libpthread|librt|libresolv|libutil|libnss_[a-z]+|libcrypto|libssl|ld-linux[^/]*)\.so' \
      | xargs -r -I{} cp -L --parents {} /libs/; \
    echo "copied into runtime:"; find /libs -type f

# ── Runtime: openCode / container.gov.de hardened base (glibc, openssl, ca-certificates, tzdata) ──
# https://container.gov.de/images/ — zendis/base is distroless, runs as 53111:53111 and is signed (cosign) with
# SBOM, VEX, provenance and SARIF attestations. The STANDARD variant (no "-minimal") is used on purpose: it ships a
# static /bin/busybox with `sh`, which the release start script and the ENTRYPOINT below need. Pinned by digest.
# Verify: cosign verify registry.opencode.de/oci-community/images/zendis/base:1.0.0 --key cosign.pub --insecure-ignore-tlog=true
FROM registry.opencode.de/oci-community/images/zendis/base:1.0.0@sha256:e0c1af6b1b67973c715212fc45d69406b3c89a6f53d8aa9d4e73391796b69812 AS runtime
USER 0:0
# The release script (bin/nebu) uses dirname/basename/sed/... — expose every busybox applet as a symlink.
RUN ["/bin/busybox", "--install", "-s", "/usr/bin"]
COPY --from=libs /libs/ /
WORKDIR /app
ARG GIT_COMMIT=unknown
ARG BUILD_TIME=unknown
ARG RELEASE_VERSION=unknown
ENV GIT_COMMIT=${GIT_COMMIT}
ENV BUILD_TIME=${BUILD_TIME}
ENV RELEASE_VERSION=${RELEASE_VERSION}
COPY --from=builder --chown=53111:53111 /app/_build/prod/rel/nebu ./
# Liveness probe without curl (not in the hardened base): a throw-away VM does one GET /health.
# docker-compose / cloud-init use `/app/healthcheck`; Kubernetes uses httpGet probes.
COPY --chown=53111:53111 --chmod=0555 healthcheck.sh /app/healthcheck
# Hardened-container baseline: non-root, no login shell, nothing else runs as root.
USER 53111:53111
# Same probe as docker-compose and cloud-init (CKV_DOCKER_2). Kubernetes ignores HEALTHCHECK and uses its httpGet probes.
# The probe boots a throw-away Erlang VM, hence the generous timeout and start period.
HEALTHCHECK --interval=10s --timeout=15s --start-period=30s --retries=3 CMD ["/app/healthcheck"]
# go-removal-cleanup (full-elixir-stack): the server now owns DB migrations (formerly run
# by the Go gateway). Run Nebu.Release.migrate/0 before booting the server. `exec`
# replaces the shell so OTP receives SIGTERM/SIGINT for graceful shutdown.
ENTRYPOINT ["/bin/sh", "-c", "./bin/nebu eval 'Nebu.Release.migrate()' && exec ./bin/nebu start"]
