#!/usr/bin/env bash
# =============================================================================
# nginx-smoke.sh — render an nginx template and prove it is valid.
#
#   bash tools/nginx-smoke.sh <template> <env-file> [--url http://host:port]
#
# Example (CI, [GEN-23]):
#   bash tools/nginx-smoke.sh \
#     deployments/main/nginx/default.conf.template \
#     deployments/main/.env.example
#
# What it does:
#   1. Renders <template> with envsubst using ONLY the variable names that
#      appear in <env-file>. This is the same restriction the container runs
#      with (NGINX_ENVSUBST_FILTER), so a variable you forgot to declare stays
#      literal and the render fails loudly instead of producing
#      `proxy_pass http:///;`.
#   2. Reports any ${NAME} left unsubstituted, and any empty substitution.
#   3. Runs `nginx -t` inside nginxinc/nginx-unprivileged:1.30-alpine with the
#      sibling nginx.conf and security-headers.conf mounted, so include paths
#      and http-level directives are checked too, not just the server block.
#   4. With --url, curls a RUNNING container and asserts the cache and
#      security behaviour that 12-NGINX.md requires.
#
# Exit 0 = clean. Exit 1 = a MUST violation. Docker missing = skip, exit 0.
# =============================================================================
set -uo pipefail

IMAGE="nginxinc/nginx-unprivileged:1.30-alpine"

RED=$'\033[31m'; GRN=$'\033[32m'; YEL=$'\033[33m'; DIM=$'\033[2m'; OFF=$'\033[0m'
if [[ ! -t 1 ]]; then RED=''; GRN=''; YEL=''; DIM=''; OFF=''; fi

FAILED=0
ok()   { printf '%s  PASS%s  %s\n' "$GRN" "$OFF" "$1"; }
fail() { printf '%s  FAIL%s  %s\n' "$RED" "$OFF" "$1"; FAILED=1; }
warn() { printf '%s  WARN%s  %s\n' "$YEL" "$OFF" "$1"; }
info() { printf '%s%s%s\n' "$DIM" "$1" "$OFF"; }

usage() {
  cat >&2 <<'EOF'
usage: nginx-smoke.sh <template.conf.template> <env-file> [--url URL] [--image IMAGE]

  <template>   nginx server-block template containing ${VARIABLES}
  <env-file>   KEY=VALUE file; only these names are substituted
  --url URL    also run live HTTP checks against a running container
  --image IMG  override the nginx image (default: nginxinc/nginx-unprivileged:1.30-alpine)
EOF
  exit 2
}

TEMPLATE=""; ENVFILE=""; URL=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --url)   URL="${2:-}"; shift 2 || usage ;;
    --image) IMAGE="${2:-}"; shift 2 || usage ;;
    -h|--help) usage ;;
    -*) printf 'unknown option: %s\n' "$1" >&2; usage ;;
    *)  if [[ -z "$TEMPLATE" ]]; then TEMPLATE="$1"; elif [[ -z "$ENVFILE" ]]; then ENVFILE="$1"; else usage; fi; shift ;;
  esac
done

[[ -n "$TEMPLATE" && -n "$ENVFILE" ]] || usage
[[ -f "$TEMPLATE" ]] || { printf 'template not found: %s\n' "$TEMPLATE" >&2; exit 1; }
[[ -f "$ENVFILE"  ]] || { printf 'env file not found: %s\n' "$ENVFILE" >&2; exit 1; }

TPL_DIR="$(cd "$(dirname "$TEMPLATE")" && pwd)"
TPL_NAME="$(basename "$TEMPLATE")"

printf '\n%s=== nginx smoke: %s x %s ===%s\n\n' "$DIM" "$TPL_NAME" "$(basename "$ENVFILE")" "$OFF"

# -----------------------------------------------------------------------------
# 1. Collect the variable names declared in the env file
# -----------------------------------------------------------------------------
# Only well-formed KEY=VALUE lines. Comments, blanks and `export` prefixes are
# handled; a line with spaces around '=' is reported, because Docker's env-file
# parser would keep the spaces in the value.
NAMES=()
BAD_LINES=0
while IFS= read -r line || [[ -n "$line" ]]; do
  line="${line%$'\r'}"                       # tolerate CRLF from Windows editors
  [[ "$line" =~ ^[[:space:]]*# ]] && continue
  [[ "$line" =~ ^[[:space:]]*$ ]] && continue
  if [[ "$line" =~ ^[[:space:]]*(export[[:space:]]+)?([A-Za-z_][A-Za-z0-9_]*)=(.*)$ ]]; then
    NAMES+=("${BASH_REMATCH[2]}")
  else
    warn "unparsable env line ignored: ${line:0:60}"
    BAD_LINES=$((BAD_LINES + 1))
  fi
done < "$ENVFILE"

if [[ ${#NAMES[@]} -eq 0 ]]; then
  fail "no variables found in $ENVFILE"
  exit 1
fi
info "declared variables: ${#NAMES[@]}"

# -----------------------------------------------------------------------------
# 2. Render
# -----------------------------------------------------------------------------
WORK="$(mktemp -d)"
cleanup() { rm -rf "$WORK"; }
trap cleanup EXIT

RENDERED="$WORK/conf/default.conf"
mkdir -p "$WORK/conf"

# Build the envsubst allow-list exactly like 20-envsubst-on-templates.sh does.
SUBST_LIST=""
for n in "${NAMES[@]}"; do SUBST_LIST="$SUBST_LIST\${$n} "; done

if ! command -v envsubst >/dev/null 2>&1; then
  fail "envsubst not found (install gettext, or run this in Git Bash / CI image that has it)"
  exit 1
fi

# `set -a` exports every assignment so envsubst can see them. The subshell
# keeps the caller's environment clean.
(
  set -a
  # shellcheck disable=SC1090
  . "$ENVFILE"
  set +a
  envsubst "$SUBST_LIST" < "$TEMPLATE" > "$RENDERED"
) || { fail "envsubst failed"; exit 1; }

ok "rendered $TPL_NAME"

# -----------------------------------------------------------------------------
# 3. Static checks on the rendered output
# -----------------------------------------------------------------------------
# Comment lines are stripped first: this file documents the very failures it
# checks for, and a comment must not be reported as a finding.
CODE="$WORK/rendered.code"
grep -vE '^[[:space:]]*#' "$RENDERED" > "$CODE"

leftovers=$(grep -oE '\$\{[A-Za-z_][A-Za-z0-9_]*\}' "$CODE" | sort -u)
if [[ -n "$leftovers" ]]; then
  fail "variables used in the template that $ENVFILE does not declare:"
  printf '          %s
' $leftovers
else
  ok "no unsubstituted \${VARIABLES} left"
fi

# The failure this whole script exists for. An empty NGINX_UPSTREAM_* renders
# `proxy_pass http:///` and nginx dies with a message that names no variable.
if grep -nE 'proxy_pass[[:space:]]+https?:///' "$CODE" >/dev/null; then
  fail "empty upstream: proxy_pass with no host (a variable rendered empty)"
  grep -nE 'proxy_pass[[:space:]]+https?:///' "$CODE" | sed 's/^/          /'
else
  ok "every proxy_pass has a host"
fi

if grep -nE '^[[:space:]]*server[[:space:]]*;' "$CODE" >/dev/null; then
  fail "empty 'server' directive inside an upstream block (variable rendered empty)"
fi

# -----------------------------------------------------------------------------
# 4. nginx -t inside the real image
# -----------------------------------------------------------------------------
if ! command -v docker >/dev/null 2>&1 || ! docker info >/dev/null 2>&1; then
  warn "docker is not available; skipping 'nginx -t'."
  warn "The rendered config was checked textually only. Run this on a machine"
  warn "with docker (or in CI) before merging an nginx change."
  [[ $FAILED -eq 0 ]] && { printf '\n%sSKIPPED (no docker) — textual checks passed%s\n' "$YEL" "$OFF"; exit 0; }
  printf '\n%sFAILED%s\n' "$RED" "$OFF"; exit 1
fi

# Git Bash on Windows rewrites POSIX paths passed to a native binary. Convert
# host paths explicitly and disable the automatic rewriting for docker.
# MSYS_NO_PATHCONV is set per-command below, never exported: exporting it also
# stops Git Bash translating /dev/null for other native binaries (curl.exe then
# exits 23 on -o /dev/null and every later assertion fails).
hostpath() { if command -v cygpath >/dev/null 2>&1; then cygpath -w "$1"; else printf '%s' "$1"; fi; }

MOUNTS=(-v "$(hostpath "$WORK/conf"):/tmp/nginx:ro")

if [[ -f "$TPL_DIR/nginx.conf" ]]; then
  MOUNTS+=(-v "$(hostpath "$TPL_DIR/nginx.conf"):/etc/nginx/nginx.conf:ro")
  info "using sibling nginx.conf (http-level directives are checked)"
else
  warn "no nginx.conf next to the template; the image default is used and"
  warn "http-level directives the template depends on (map, log_format,"
  warn "proxy_cache_path, limit_req_zone) will report as unknown."
fi

if [[ -f "$TPL_DIR/security-headers.conf" ]]; then
  MOUNTS+=(-v "$(hostpath "$TPL_DIR/security-headers.conf"):/etc/nginx/snippets/security-headers.conf:ro")
fi

# A doc root must exist or try_files/root checks are meaningless. index.html
# is created so the SPA fallback has something to point at.
mkdir -p "$WORK/html"
printf '<!doctype html><title>smoke</title>' > "$WORK/html/index.html"
printf '{"release":"smoke","builtAt":"1970-01-01T00:00:00Z"}' > "$WORK/html/__version.json"
MOUNTS+=(-v "$(hostpath "$WORK/html"):/usr/share/nginx/html:ro")

printf '\n%s--- nginx -t (%s) ---%s\n' "$DIM" "$IMAGE" "$OFF"
NGINX_OUT="$(MSYS_NO_PATHCONV=1 docker run --rm "${MOUNTS[@]}" --entrypoint nginx "$IMAGE" -t 2>&1)"
NGINX_RC=$?
printf '%s\n' "$NGINX_OUT"
printf '%s--- end nginx -t ---%s\n\n' "$DIM" "$OFF"

if [[ $NGINX_RC -eq 0 ]]; then
  ok "nginx -t: configuration syntax is ok"
else
  fail "nginx -t failed (exit $NGINX_RC)"
fi

# -----------------------------------------------------------------------------
# 5. Live HTTP checks against a running container (optional)
# -----------------------------------------------------------------------------
if [[ -n "$URL" ]]; then
  URL="${URL%/}"
  printf '%s--- live checks against %s ---%s\n' "$DIM" "$URL" "$OFF"

  if ! command -v curl >/dev/null 2>&1; then
    warn "curl not found; skipping live checks"
  else
    # Body goes to a real file, not /dev/null: under MSYS_NO_PATHCONV=1 (set
    # above for docker) Git Bash stops translating /dev/null for the native
    # curl.exe, which then exits 23 (write error) and, with pipefail, turns
    # every header assertion into a false failure.
    hdr() { curl -fsS -o /dev/null -D - --max-time 10 "$1" 2>/dev/null; }

    # [NGX-06] health endpoint
    if body=$(curl -fsS --max-time 10 "$URL/healthz" 2>/dev/null) && [[ "$body" == ok* ]]; then
      ok "[NGX-06] GET /healthz -> 200 ok"
    else
      fail "[NGX-06] GET /healthz did not return 'ok'"
    fi

    # [NGX-05] index.html must revalidate
    if hdr "$URL/" | grep -iE '^cache-control:.*no-cache' >/dev/null; then
      ok "[NGX-05] / -> Cache-Control: no-cache"
    else
      fail "[NGX-05] / is missing 'no-cache'; users will run a stale bundle"
    fi

    # [NGX-05]/[SEC-13] config.js must never be stored
    if hdr "$URL/config.js" | grep -iE '^cache-control:.*no-store' >/dev/null; then
      ok "[NGX-05] /config.js -> Cache-Control: no-store"
    else
      fail "[NGX-05] /config.js is missing 'no-store'"
    fi

    # [NGX-11] security headers on a normal response
    heads=$(hdr "$URL/")
    for h in x-content-type-options referrer-policy x-frame-options; do
      if printf '%s' "$heads" | grep -iE "^$h:" >/dev/null; then
        ok "[NGX-11] header present: $h"
      else
        fail "[NGX-11] header missing: $h (an add_header in a location replaces the inherited set)"
      fi
    done

    # [NGX-12] version banner
    if printf '%s' "$heads" | grep -iE '^server:.*nginx/[0-9]' >/dev/null; then
      fail "[NGX-12] Server header leaks the nginx version; set server_tokens off"
    else
      ok "[NGX-12] no nginx version in the Server header"
    fi

    # [NGX-04] hashed assets must be immutable. Discovered from index.html so
    # the check does not need to know the hash.
    asset=$(curl -fsS --max-time 10 "$URL/" 2>/dev/null \
            | grep -oE '/assets/[A-Za-z0-9._-]+\.(js|css)' | head -1)
    if [[ -n "$asset" ]]; then
      if hdr "$URL$asset" | grep -iE '^cache-control:.*immutable' >/dev/null; then
        ok "[NGX-04] $asset -> immutable"
      else
        fail "[NGX-04] $asset is not served with 'immutable'"
      fi
    else
      warn "[NGX-04] no /assets/ reference found in index.html; skipped"
    fi

    # [NGX-13] source maps must not be reachable
    code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 "$URL/assets/anything.js.map")
    if [[ "$code" == "403" || "$code" == "404" ]]; then
      ok "[NGX-13] *.map -> $code"
    else
      fail "[NGX-13] *.map returned $code; source maps must be denied"
    fi
  fi
  printf '%s--- end live checks ---%s\n\n' "$DIM" "$OFF"
fi

if [[ $FAILED -eq 0 ]]; then
  printf '%sCLEAN%s\n' "$GRN" "$OFF"
  exit 0
fi
printf '%sFAILED%s\n' "$RED" "$OFF"
exit 1
