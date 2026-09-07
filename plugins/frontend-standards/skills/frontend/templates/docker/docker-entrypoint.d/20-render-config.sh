#!/bin/sh
# =============================================================================
# 20-render-config.sh -> /docker-entrypoint.d/20-render-config.sh (mode 0755)
#
# The official nginx entrypoint runs every executable *.sh in
# /docker-entrypoint.d/ in `sort -V` order before exec'ing nginx. The stock
# 20-envsubst-on-templates.sh renders /etc/nginx/templates/*.template into
# $NGINX_ENVSUBST_OUTPUT_DIR; "20-envsubst-on-templates.sh" sorts before
# "20-render-config.sh", so by the time this runs the nginx config exists and
# we render the browser-facing runtime config next to it.
#
# Two jobs:
#   1. FAIL FAST. Every required variable is checked here. An empty variable
#      that reaches envsubst produces `proxy_pass http:///;` (nginx refuses to
#      start with a message that names no variable) or a /config.js with
#      `apiBaseUrl: ""` (the app boots and every request 404s against itself).
#      Both were real incidents. Exiting 1 with the variable name turns a
#      30-minute investigation into a one-line log entry.
#   2. Render config.js.template into the tmpfs. /usr/share/nginx/html is
#      root-owned and the container runs read-only as uid 101, so the file
#      cannot be written into the document root; `location = /config.js`
#      aliases it out of /tmp/nginx instead.
# =============================================================================
set -eu

ME="$(basename "$0")"

TEMPLATE="${APP_CONFIG_TEMPLATE:-/etc/nginx/app-config/config.js.template}"
OUTPUT_DIR="${NGINX_ENVSUBST_OUTPUT_DIR:-/tmp/nginx}"
OUTPUT="$OUTPUT_DIR/config.js"

# Every variable that must be non-empty for the container to be useful.
# Add a variable here in the same commit that adds it to config.js.template.
REQUIRED="
APP_API_BASE_URL
APP_TILE_BASE_URL
APP_MAP_STYLE_URL
APP_MQTT_WS_URL
APP_ENVIRONMENT
APP_RELEASE
APP_SITE_URL
APP_FEATURES_JSON
NGINX_PUBLIC_HOST
NGINX_ROBOTS_POLICY
NGINX_UPSTREAM_API
NGINX_UPSTREAM_TILES
NGINX_UPSTREAM_MAP
NGINX_UPSTREAM_MQTT
NGINX_UPSTREAM_MEDIA
"

missing=''
for name in $REQUIRED; do
    # POSIX indirect expansion; `set -u` would abort before we can report, so
    # the default branch is explicit.
    eval "value=\${$name:-}"
    if [ -z "$value" ]; then
        missing="$missing $name"
    fi
done

if [ -n "$missing" ]; then
    echo "$ME: FATAL: required environment variable(s) empty or unset:$missing" >&2
    echo "$ME: the container will not start. Set them in the --env-file used by compose." >&2
    exit 1
fi

# APP_FEATURES_JSON is interpolated into JavaScript unquoted. If it is not
# valid JSON the bundle throws a SyntaxError before React mounts, and the user
# sees a blank page with no network error to point at. Check it here instead.
case "$APP_FEATURES_JSON" in
    '{'*'}') : ;;
    *)
        echo "$ME: FATAL: APP_FEATURES_JSON must be a single-line JSON object, got: $APP_FEATURES_JSON" >&2
        exit 1
        ;;
esac

# Upstreams are host:port. A scheme or a path here produces a proxy_pass that
# nginx accepts and that then fails at request time with a useless 502.
for name in NGINX_UPSTREAM_API NGINX_UPSTREAM_TILES NGINX_UPSTREAM_MAP NGINX_UPSTREAM_MQTT NGINX_UPSTREAM_MEDIA; do
    eval "value=\$$name"
    case "$value" in
        *://*|*/*)
            echo "$ME: FATAL: $name must be host:port without a scheme or path, got: $value" >&2
            exit 1
            ;;
    esac
done

if [ ! -f "$TEMPLATE" ]; then
    echo "$ME: FATAL: $TEMPLATE not found; the image was built without a runtime config template" >&2
    exit 1
fi

mkdir -p "$OUTPUT_DIR"

# Substitute ONLY the APP_* names this template uses. Passing no list would let
# any environment variable (PATH, HOME, a secret from the host) replace a
# matching $NAME in the file.
envsubst '
  ${APP_API_BASE_URL}
  ${APP_TILE_BASE_URL}
  ${APP_MAP_STYLE_URL}
  ${APP_MQTT_WS_URL}
  ${APP_ENVIRONMENT}
  ${APP_RELEASE}
  ${APP_SITE_URL}
  ${APP_FEATURES_JSON}
' < "$TEMPLATE" > "$OUTPUT"

echo "$ME: rendered $TEMPLATE -> $OUTPUT (release=$APP_RELEASE, env=$APP_ENVIRONMENT)"
