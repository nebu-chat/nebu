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

FROM elixir:1.20-alpine AS builder
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

FROM alpine:3.23 AS runtime
RUN apk add --no-cache libstdc++ openssl ncurses curl
ARG GIT_COMMIT=unknown
ARG BUILD_TIME=unknown
ARG RELEASE_VERSION=unknown
ENV GIT_COMMIT=${GIT_COMMIT}
ENV BUILD_TIME=${BUILD_TIME}
ENV RELEASE_VERSION=${RELEASE_VERSION}
COPY --from=builder /app/_build/prod/rel/nebu ./
# go-removal-cleanup (full-elixir-stack): the server now owns DB migrations (formerly run
# by the Go gateway). Run Nebu.Release.migrate/0 before booting the server. `exec`
# replaces the shell so OTP receives SIGTERM/SIGINT for graceful shutdown.
ENTRYPOINT ["/bin/sh", "-c", "./bin/nebu eval 'Nebu.Release.migrate()' && exec ./bin/nebu start"]
