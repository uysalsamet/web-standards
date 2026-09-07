# syntax=docker/dockerfile:1.7
# =============================================================================
# deployments/main/Dockerfile
# Build context is the REPOSITORY ROOT (see docker-compose.yml build.context).
#
#   docker compose -f deployments/main/docker-compose.yml \
#     --env-file deployments/main/.env.prod \
#     build --build-arg BUILD_ID=$(git rev-parse --short HEAD) \
#            --build-arg GIT_SHA=$(git rev-parse HEAD)
#
# Two stages only ([OPS-01]). The runtime stage contains nginx, dist/ and the
# templates. No Node, no npm, no source ([GEN-13]).
# =============================================================================

# ---------- stage 1: build ---------------------------------------------------
FROM node:24-alpine AS builder

WORKDIR /app

# Dependencies in their own layer, BEFORE the source is copied. package.json
# and the lockfile change rarely; src/ changes every commit. Copying the source
# first would reinstall ~1,200 packages (60 to 125 s) on every build.
COPY package.json package-lock.json ./
RUN npm ci

COPY . .

# Cache-bust. BUILD_ID changes on every commit, so this ARG invalidates the
# layers below it while `npm ci` above stays cached.
#
# This exists so that `--no-cache` is NEVER needed ([OPS-10]). On the reference
# deployment, routine `docker build --no-cache` grew the BuildKit cache to
# 168 GB; the resulting garbage collection ran mid-build and produced
# intermittent `COPY --from ... not found` failures that looked like a
# Dockerfile bug. Cache-busting one ARG is the correct tool.
ARG BUILD_ID=dev
ENV BUILD_ID=$BUILD_ID

# The ONLY VITE_* build argument allowed ([GEN-09], [OPS-14]). Everything else
# an environment can change is a runtime value in /config.js. A second VITE_*
# arg here means one image per environment, which means the image you tested is
# not the image you deployed.
ARG VITE_BUILD_ID=dev
ENV VITE_BUILD_ID=$VITE_BUILD_ID

# Full commit sha for the release id ([OBS-05]). Read by vite.config.ts, which
# defines __APP_RELEASE__ and emits dist/__version.json.
ARG GIT_SHA=unknown
ENV GIT_SHA=$GIT_SHA

RUN npm run build

# dist/__version.json is emitted by the versionFile Vite plugin ([OBS-18]).
# Failing here is much cheaper than discovering after the deploy that the
# version endpoint 404s.
RUN test -s dist/index.html \
 && test -s dist/__version.json \
 && echo "build ok: $(wc -c < dist/index.html) bytes of index.html"

# ---------- stage 2: runtime -------------------------------------------------
FROM nginxinc/nginx-unprivileged:1.30-alpine

# nginx-unprivileged runs as uid 101 and binds 8080, so no capability is needed
# and `USER root` never appears ([OPS-03]).

LABEL org.opencontainers.image.title="example-app" \
      org.opencontainers.image.description="React + Vite SPA served by nginx" \
      org.opencontainers.image.licenses="UNLICENSED" \
      org.opencontainers.image.base.name="nginxinc/nginx-unprivileged:1.30-alpine"

ARG GIT_SHA=unknown
ARG BUILD_ID=dev
# Queryable with `docker inspect`: which commit is this image, without running it.
LABEL org.opencontainers.image.revision="$GIT_SHA" \
      org.opencontainers.image.version="$BUILD_ID"

# Rendered configs and /config.js go to the /tmp tmpfs, because the container
# runs with read_only: true and /etc/nginx/conf.d is then not writable.
ENV NGINX_ENVSUBST_OUTPUT_DIR=/tmp/nginx
# Substitute ONLY NGINX_* and APP_* names. Without the filter, envsubst would
# also replace nginx's own $host, $uri and $request_id if a same-named
# environment variable ever existed.
ENV NGINX_ENVSUBST_FILTER='^(NGINX|APP)_'
# The output directory must EXIST and be writable before
# 20-envsubst-on-templates.sh runs, or it logs
# "ERROR: /etc/nginx/templates exists, but /tmp/nginx is not writable" and
# renders nothing, and nginx then fails on an empty include. Under
# read_only: true this directory comes from its own tmpfs mount (see compose);
# creating it here covers a plain `docker run` with no read_only.
RUN mkdir -p /tmp/nginx

COPY --from=builder /app/dist /usr/share/nginx/html

COPY deployments/main/nginx/nginx.conf              /etc/nginx/nginx.conf
COPY deployments/main/nginx/default.conf.template   /etc/nginx/templates/default.conf.template
COPY deployments/main/nginx/security-headers.conf   /etc/nginx/snippets/security-headers.conf
# NOT under /etc/nginx/templates: the stock 20-envsubst-on-templates.sh renders
# every *.template it finds there, so config.js would be rendered twice, the
# first time with the loose NGINX_ENVSUBST_FILTER allow-list.
COPY deployments/main/config.js.template            /etc/nginx/app-config/config.js.template
COPY --chmod=0755 deployments/main/docker-entrypoint.d/20-render-config.sh \
                                                    /docker-entrypoint.d/20-render-config.sh

EXPOSE 8080

# wget is in busybox, already in the image; no curl layer needed.
# start-period covers the entrypoint rendering the templates.
HEALTHCHECK --interval=30s --timeout=3s --start-period=5s --retries=3 \
  CMD wget -q -O /dev/null http://127.0.0.1:8080/healthz || exit 1
