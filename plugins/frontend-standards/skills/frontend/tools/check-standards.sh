#!/usr/bin/env bash
# =============================================================================
#  check-standards.sh — frontend-standards automated audit
#
#  Usage:   bash tools/check-standards.sh [app-root]
#  Exit:    0 = clean | 1 = at least one MUST / MUST NOT violation
#
#  Checks the MACHINE-CHECKABLE part of the standard. Everything it does not cover
#  is left to human/AI review via RULE-MAP.md §1 and 15-NEW-FEATURE-CHECKLIST.md.
#
#  Design note: this is a heuristic, not a proof. Text patterns produce false
#  positives and negatives. If a check misfires, NARROW the pattern; do not
#  silently disable it ([TOOL-02]). Comment lines (// and *) are excluded from
#  source scans; string literals are not.
#
#  Requires: bash 4+, grep, awk, find, node (for JSON parsing). Works in Git Bash
#  on Windows.
# =============================================================================
set -uo pipefail

ROOT="${1:-.}"
ROOT="${ROOT%/}"
ERRORS=0
WARNINGS=0

RED=$'\033[0;31m'; YEL=$'\033[0;33m'; GRN=$'\033[0;32m'; DIM=$'\033[2m'; NC=$'\033[0m'
[[ -t 1 ]] || { RED=""; YEL=""; GRN=""; DIM=""; NC=""; }

# violation <MUST|SHOULD> <rule-id> <location> <message>
violation() {
  local sev="$1" id="$2" loc="$3" msg="$4"
  if [[ "$sev" == "MUST" ]]; then
    printf '%sERROR%s  [%s] %s\n        %s\n' "$RED" "$NC" "$id" "$loc" "$msg"
    ERRORS=$((ERRORS+1))
  else
    printf '%sWARN%s   [%s] %s\n        %s\n' "$YEL" "$NC" "$id" "$loc" "$msg"
    WARNINGS=$((WARNINGS+1))
  fi
}
section() { printf '\n%s── %s%s\n' "$DIM" "$1" "$NC"; }

# Source scanner that drops comment lines. Usage: scan '<ERE>' file...
scan() {
  local pat="$1"; shift
  [[ $# -eq 0 ]] && return 0
  grep -nHE "$pat" "$@" 2>/dev/null | grep -vE ':[0-9]+:[[:space:]]*(//|\*|/\*)' || true
}

SRC="$ROOT/src"
DEPLOY="$ROOT/deployments"

mapfile -t TS_FILES < <(find "$SRC" -type f \( -name '*.ts' -o -name '*.tsx' \) \
  -not -path '*/node_modules/*' -not -name '*.d.ts' -not -name '*.test.*' -not -name '*.spec.*' 2>/dev/null)
mapfile -t TSX_FILES < <(printf '%s\n' "${TS_FILES[@]}" | grep -E '\.tsx$' || true)
mapfile -t DOCKERFILES < <(find "$ROOT" -type f -name 'Dockerfile*' -not -path '*/node_modules/*' 2>/dev/null)
mapfile -t COMPOSE_FILES < <(find "$ROOT" -type f \( -name 'docker-compose*.yml' -o -name 'compose*.yml' -o -name '*-compose.yml' \) -not -path '*/node_modules/*' 2>/dev/null)
mapfile -t NGINX_FILES < <(find "$ROOT" -type f \( -name '*.conf' -o -name '*.conf.template' \) -path '*nginx*' -not -path '*/node_modules/*' 2>/dev/null)
mapfile -t ENV_FILES < <(find "$ROOT" -maxdepth 3 -type f -name '.env*' -not -path '*/node_modules/*' 2>/dev/null)

printf '%s\n' "frontend-standards — automated audit"
printf '%s\n' "root: $ROOT · ${#TS_FILES[@]} ts/tsx · ${#DOCKERFILES[@]} Dockerfile · ${#COMPOSE_FILES[@]} compose · ${#NGINX_FILES[@]} nginx"

# =============================================================================
section "A · Dependencies and versions"
# =============================================================================
PKG="$ROOT/package.json"
if [[ ! -f "$PKG" ]]; then
  violation MUST VER-01 "$ROOT" "package.json not found; is this the app root?"
else
  engines=$(node -e "const p=JSON.parse(require('node:fs').readFileSync(process.argv[1],'utf8'));console.log((p.engines&&p.engines.node)||'')" "$PKG" 2>/dev/null)
  [[ "$engines" =~ 24 ]] || violation MUST VER-01 "$PKG" "engines.node must be '>=24.0.0' (found '${engines:-none}')"

  [[ -f "$ROOT/package-lock.json" ]] || violation MUST VER-04 "$ROOT" "package-lock.json missing; installs are not deterministic"
  [[ -f "$ROOT/.nvmrc" ]] || violation SHOULD VER-01 "$ROOT" ".nvmrc missing (should contain 24)"

  FORBIDDEN='axios ky superagent moment dayjs luxon lodash underscore styled-components @emotion/react @emotion/styled @stitches/react mapbox-gl react-map-gl react-maplibre-gl leaflet react-leaflet @turf/turf uuid redux-thunk redux-saga redux-observable react-helmet react-scripts next remix @remix-run/react'
  deps=$(node -e "const p=JSON.parse(require('node:fs').readFileSync(process.argv[1],'utf8'));console.log(Object.keys({...p.dependencies,...p.devDependencies}).join(' '))" "$PKG" 2>/dev/null)
  for f in $FORBIDDEN; do
    for d in $deps; do
      [[ "$d" == "$f" ]] && violation MUST VER-05 "$PKG" "forbidden dependency '$f' (see 02 §4 for the replacement)"
    done
  done
  # xlsx and xlsx-js-style together = two SheetJS copies
  if [[ " $deps " == *" xlsx "* && " $deps " == *" xlsx-js-style "* ]]; then
    violation MUST VER-05 "$PKG" "'xlsx' and 'xlsx-js-style' both installed; keep xlsx-js-style only"
  fi
  # Required toolchain presence
  for req in vitest eslint prettier typescript vite; do
    [[ " $deps " == *" $req "* ]] || violation SHOULD VER-01 "$PKG" "expected dev dependency '$req' not found"
  done
  # scripts
  for s in lint typecheck test build; do
    node -e "const p=JSON.parse(require('node:fs').readFileSync(process.argv[1],'utf8'));process.exit(p.scripts&&p.scripts['$s']?0:1)" "$PKG" 2>/dev/null \
      || violation MUST CI-02 "$PKG" "npm script '$s' missing; CI gate needs it ([GEN-23])"
  done
fi

# =============================================================================
section "B · Configuration and secrets"
# =============================================================================
# [GEN-10] secret-looking names in VITE_ variables (env files, compose, Dockerfile, source)
SECRET_RE='VITE_[A-Z0-9_]*(PASSWORD|PASSWD|SECRET|TOKEN|PRIVATE|API_KEY|APIKEY|CREDENTIAL)'
for f in "${ENV_FILES[@]}" "${COMPOSE_FILES[@]}" "${DOCKERFILES[@]}"; do
  [[ -f "$f" ]] || continue
  # The value is masked: an audit report must never print the secret it found.
  while IFS= read -r line; do
    violation MUST GEN-10 "${line%%=*}=***" "secret-like value exposed through a VITE_ variable (public by definition)"
  done < <(grep -nHE "$SECRET_RE" "$f" 2>/dev/null | grep -vE ':[0-9]+:[[:space:]]*#' || true)
done
while IFS= read -r line; do
  violation MUST GEN-10 "$line" "secret-like VITE_ variable read in source"
done < <(scan "import\.meta\.env\.$SECRET_RE" "${TS_FILES[@]}")

# [GEN-09] VITE_ build args in Dockerfile other than VITE_BUILD_ID → per-environment images
for f in "${DOCKERFILES[@]}"; do
  while IFS= read -r line; do
    violation MUST GEN-09 "$line" "VITE_ build arg bakes environment into the image; use runtime /config.js ([ADR-0014])"
  done < <(grep -nHE '^\s*ARG\s+VITE_' "$f" | grep -vE 'VITE_BUILD_ID' || true)
done
# [GEN-09] runtime config present
if [[ -d "$DEPLOY" ]]; then
  find "$DEPLOY" -name 'config.js.template' | grep -q . \
    || violation MUST OPS-07 "$DEPLOY" "config.js.template not found; runtime config is mandatory ([GEN-09])"
fi
if [[ -d "$SRC" ]]; then
  grep -rqE '__APP_CONFIG__' "$SRC" 2>/dev/null \
    || violation MUST STR-20 "$SRC" "no reader of window.__APP_CONFIG__ (src/app/config/runtimeConfig.ts expected)"
fi

# [SEC-14] third-party script/style origins in index.html; [PERF-19] Google Fonts
IDX="$ROOT/index.html"
if [[ -f "$IDX" ]]; then
  while IFS= read -r line; do
    violation MUST SEC-14 "$line" "external script/stylesheet origin in index.html; bundle from npm or self-host"
  done < <(grep -nHE '<(script|link)[^>]+(src|href)="https?://' "$IDX" | grep -vE 'rel="(canonical|alternate|me)"' || true)
  grep -qE 'src="/config\.js"' "$IDX" || violation MUST OPS-08 "$IDX" "index.html must load /config.js before the module script"
  grep -qE '<html[^>]*lang=' "$IDX" || violation SHOULD I18N-20 "$IDX" "<html> has no lang attribute (set per locale at runtime)"
fi

# =============================================================================
section "C · Source code"
# =============================================================================
if [[ ${#TS_FILES[@]} -gt 0 ]]; then
  # [GEN-06] bare fetch outside the shared client
  while IFS= read -r line; do
    violation MUST GEN-06 "$line" "bare fetch() outside src/shared/api; use the shared client"
  done < <(scan '\bfetch\(' "${TS_FILES[@]}" | grep -vE 'src/shared/api/|src/test/|/msw/|src/shared/lib/' || true)

  # [VER-05] forbidden imports in source
  while IFS= read -r line; do
    violation MUST VER-05 "$line" "forbidden import (axios/moment/lodash/mapbox-gl/react-map-gl/leaflet/@turf/turf)"
  done < <(scan "from ['\"](axios|moment|dayjs|luxon|lodash|underscore|mapbox-gl|react-map-gl|react-maplibre-gl|leaflet|react-leaflet|@turf/turf|uuid|react-helmet)['\"]" "${TS_FILES[@]}")

  # [SEC-01] dangerouslySetInnerHTML outside SafeHtml
  while IFS= read -r line; do
    violation MUST SEC-01 "$line" "dangerouslySetInnerHTML outside src/shared/components/SafeHtml; sanitize with DOMPurify there"
  done < <(scan 'dangerouslySetInnerHTML' "${TSX_FILES[@]}" | grep -vE '/SafeHtml' || true)

  # [GEN-18] DOM markers; [MAP-01] second map instance
  while IFS= read -r line; do
    violation SHOULD GEN-18 "$line" "maplibregl.Marker (DOM). At most 20 rich widgets ([MAP-11]); datasets must be layers"
  done < <(scan 'new (maplibregl\.)?Marker\(' "${TS_FILES[@]}")
  # Only an explicit maplibre namespace counts. A bare `new Map(` is the native JS Map
  # and matching it produced hundreds of false positives on the reference repo.
  while IFS= read -r line; do
    violation MUST MAP-01 "$line" "maplibregl.Map constructed outside src/shared/map; one map instance owned by MapContainer"
  done < <(scan 'new (maplibregl|maplibre|mapboxgl)\.Map\(' "${TS_FILES[@]}" | grep -vE 'src/shared/map/' || true)
  # setData used for highlight (heuristic: setData near hover/selected/highlight names)
  while IFS= read -r line; do
    violation SHOULD MAP-18 "$line" "setData with hover/selected/highlight data; use feature-state instead"
  done < <(scan 'setData\([^)]*(hover|selected|highlight)' "${TS_FILES[@]}")

  # [GEN-17] empty catch blocks (single-line and two-line forms)
  while IFS= read -r line; do
    violation MUST GEN-17 "$line" "empty catch block swallows the error"
  done < <(scan 'catch\s*(\([^)]*\))?\s*\{\s*\}' "${TS_FILES[@]}")
  for f in "${TS_FILES[@]}"; do
    awk -v F="$f" '
      prev ~ /catch[[:space:]]*(\([^)]*\))?[[:space:]]*\{[[:space:]]*$/ && $0 ~ /^[[:space:]]*\}[[:space:]]*$/ { print F":"NR-1": empty catch (two-line)" }
      { prev=$0 }' "$f"
  done | while IFS= read -r line; do violation MUST GEN-17 "$line" "empty catch block swallows the error"; done

  # [OBS-16] console.* outside the logger wrapper
  while IFS= read -r line; do
    violation MUST OBS-16 "$line" "console.* in application code; use src/shared/lib/logger"
  done < <(scan '\bconsole\.(log|info|debug|warn|error)\(' "${TS_FILES[@]}" | grep -vE 'src/shared/lib/logger|src/test/|vite\.config' || true)

  # [TS-05] any
  while IFS= read -r line; do
    violation MUST TS-05 "$line" "'any' is forbidden; use unknown + narrowing or a schema"
  done < <(scan '(:\s*any\b|as any\b|<any>)' "${TS_FILES[@]}")

  # [TS-21] React.FC
  while IFS= read -r line; do
    violation MUST TS-21 "$line" "React.FC is not used; type props explicitly"
  done < <(scan 'React\.FC\b|: FC<' "${TSX_FILES[@]}")

  # [STR-15] default exports (allowlist: config files, lazy re-export modules)
  while IFS= read -r line; do
    violation SHOULD STR-15 "$line" "export default; use named exports"
  done < <(scan '^\s*export default ' "${TS_FILES[@]}" | grep -vE 'vite\.config|eslint\.config|playwright\.config|vitest\.config|\.d\.ts|src/shared/i18n/config' || true)

  # [STR-10] shared importing features/app; [STR-11] deep cross-feature imports
  mapfile -t SHARED_FILES < <(printf '%s\n' "${TS_FILES[@]}" | grep -E '/src/shared/' || true)
  while IFS= read -r line; do
    violation MUST STR-10 "$line" "src/shared imports from features or app; direction is app → features → shared"
  done < <(scan "from ['\"](@/features|@/app|\.\./(\.\./)*features|\.\./(\.\./)*app)" "${SHARED_FILES[@]}")
  mapfile -t FEATURE_FILES < <(printf '%s\n' "${TS_FILES[@]}" | grep -E '/src/features/' || true)
  while IFS= read -r line; do
    # own feature name from path
    file="${line%%:*}"
    own=$(printf '%s' "$file" | sed -E 's#.*/src/features/([^/]+)/.*#\1#')
    target=$(printf '%s' "$line" | sed -E "s#.*from ['\"]@/features/([^/'\"]+)/.*#\1#")
    [[ "$own" == "$target" ]] && continue
    violation MUST STR-11 "$line" "deep import into another feature; import only '@/features/<Name>' (its index.ts)"
  done < <(scan "from ['\"]@/features/[^/'\"]+/" "${FEATURE_FILES[@]}")
  while IFS= read -r line; do
    violation MUST STR-10 "$line" "feature imports from src/app"
  done < <(scan "from ['\"]@/app/" "${FEATURE_FILES[@]}")

  # [STR-09] utils/ folder inside a feature
  while IFS= read -r d; do
    violation MUST STR-09 "$d" "feature-level utils/; use lib/ (feature logic) or src/shared/utils (domain-free)"
  done < <(find "$SRC/features" -mindepth 2 -maxdepth 2 -type d -name 'utils' 2>/dev/null)

  # [STR-05]/[STR-06] every feature has index.ts and README.md
  while IFS= read -r d; do
    [[ -f "$d/index.ts" ]] || violation MUST STR-05 "$d" "feature has no index.ts public API"
    [[ -f "$d/README.md" ]] || violation MUST STR-06 "$d" "feature has no README.md"
  done < <(find "$SRC/features" -mindepth 1 -maxdepth 1 -type d 2>/dev/null)

  # [STR-25] file size limits (warn at limit, error at 1.5×)
  for f in "${TS_FILES[@]}"; do
    n=$(wc -l < "$f")
    if [[ "$f" == *.tsx ]]; then lim=250; else lim=400; fi
    if (( n > lim * 3 / 2 )); then
      violation MUST STR-25 "$f" "$n lines (limit $lim, hard limit $((lim*3/2)))"
    elif (( n > lim )); then
      violation SHOULD STR-25 "$f" "$n lines (limit $lim)"
    fi
  done

  # [AUTH-04] tokens in web storage
  while IFS= read -r line; do
    violation MUST AUTH-04 "$line" "token/JWT in localStorage/sessionStorage; sessions are HttpOnly cookies"
  done < <(scan '(localStorage|sessionStorage)\.(setItem|getItem)\([^)]*(token|jwt|access|refresh)' "${TS_FILES[@]}")

  # [GEN-14] literal Turkish text in JSX (heuristic: Turkish-only letters inside JSX text)
  while IFS= read -r line; do
    violation SHOULD I18N-03 "$line" "literal Turkish text in JSX; use t('key')"
  done < <(scan '>[^<{]*[çğıöşüÇĞİÖŞÜ][^<{]*<' "${TSX_FILES[@]}")

  # [STA-28] HTTP performed by a thunk instead of a TanStack Query mutation
  while IFS= read -r line; do
    violation MUST STA-28 "$line" "createAsyncThunk performs HTTP: server state belongs to TanStack Query"
  done < <(scan 'createAsyncThunk\(' "${TS_FILES[@]}")
fi

# =============================================================================
section "D · Docker and compose"
# =============================================================================
for f in "${DOCKERFILES[@]}"; do
  grep -qE '^\s*FROM\s+\S+:latest' "$f" && violation MUST VER-02 "$f" "FROM ...:latest"
  grep -qE '^\s*FROM\s+node(:|$)' "$f" && ! grep -qE '^\s*FROM\s+node:24' "$f" && violation MUST VER-01 "$f" "builder must be node:24-alpine"
  if grep -qE '^\s*FROM\s+nginx' "$f"; then
    grep -qE 'nginx-unprivileged' "$f" || grep -qE '^\s*USER\s+' "$f" \
      || violation MUST OPS-03 "$f" "runtime runs as root; use nginxinc/nginx-unprivileged or USER"
  fi
  grep -qE '^\s*HEALTHCHECK' "$f" || violation MUST OPS-05 "$f" "HEALTHCHECK missing"
  grep -qE 'npm ci' "$f" || violation MUST VER-04 "$f" "npm ci not used in the build stage"
  grep -qE 'npm install -g serve|serve -s|http-server' "$f" \
    && violation MUST OPS-02 "$f" "Node static server in the runtime image; nginx serves dist/ ([ADR-0013])"
  grep -qE 'BUILD_ID' "$f" || violation SHOULD OPS-04 "$f" "no BUILD_ID cache-bust arg; vite build may come from cache"
  d=$(dirname "$f"); ctx="$ROOT"
  [[ -f "$ROOT/.dockerignore" || -f "$d/.dockerignore" ]] || violation MUST OPS-06 "$ROOT" ".dockerignore missing"
done
for f in "${COMPOSE_FILES[@]}"; do
  grep -qE 'image:\s*\S+:latest' "$f" && violation MUST VER-02 "$f" "image: ...:latest"
  grep -qE '^\s*logging:' "$f" || violation SHOULD OPS-12 "$f" "no logging rotation (json-file max-size/max-file)"
  grep -qE 'restart:\s*(unless-stopped|always)' "$f" || violation SHOULD OPS-11 "$f" "no restart policy"
  while IFS= read -r line; do
    violation MUST OPS-09 "$line" "default value for an upstream host in compose; fail loudly instead"
  done < <(grep -nHE '\$\{[A-Z_]*UPSTREAM[A-Z_]*:-' "$f" || true)
done

# =============================================================================
section "E · nginx"
# =============================================================================
for f in "${NGINX_FILES[@]}"; do
  # Server-level checks apply only to files that define a server block. Include
  # fragments (security-headers.conf and friends) are checked by their includer.
  grep -qE '^\s*server\s*\{' "$f" || continue
  grep -qE 'try_files[^;]*/index\.html' "$f" || violation MUST NGX-03 "$f" "no SPA fallback (try_files ... /index.html)"
  grep -qE 'immutable' "$f" || violation MUST NGX-04 "$f" "hashed assets not served with 'immutable' cache header"
  grep -qE 'location\s*=\s*/index\.html|location\s*=\s*/config\.js' "$f" \
    || violation MUST NGX-05 "$f" "index.html / config.js have no explicit no-cache/no-store location"
  grep -qE 'server_tokens\s+off' "$f" || violation SHOULD NGX-12 "$f" "server_tokens off missing"
  grep -qE 'security-headers|X-Content-Type-Options' "$f" || violation MUST NGX-11 "$f" "no security headers include"
  grep -qE 'location\s*=\s*/healthz' "$f" || violation MUST NGX-06 "$f" "/healthz location missing"
  grep -qE '\.map' "$f" || violation SHOULD NGX-13 "$f" "*.map (source maps) not denied"
  grep -qE 'gzip_static\s+on' "$f" || violation SHOULD NGX-07 "$f" "gzip_static off; precompressed assets not served"
  while IFS= read -r line; do
    violation SHOULD NGX-22 "$line" "client_max_body_size above 100m; scope large limits to upload locations"
  done < <(grep -nHE 'client_max_body_size\s+([2-9][0-9]{2,}|[1-9][0-9]{3,})[mM]|client_max_body_size\s+[0-9]+[gG]' "$f" || true)
  # variable proxy_pass without resolver
  if grep -qE 'proxy_pass\s+http://\$' "$f" && ! grep -qE '^\s*resolver\s' "$f"; then
    violation MUST NGX-17 "$f" "proxy_pass with a variable but no 'resolver' directive"
  fi
  # add_header inside a location without the security include (inheritance trap)
  awk -v F="$f" '
    /location[[:space:]]/ { inloc=1; hasadd=0; hasinc=0; start=NR }
    inloc && /add_header/ { hasadd=1 }
    inloc && /include[[:space:]]+[^;]*security-headers/ { hasinc=1 }
    inloc && /^[[:space:]]*}/ { if (hasadd && !hasinc) print F":"start": add_header in location without security-headers include (headers are replaced, not merged)"; inloc=0 }
  ' "$f" | while IFS= read -r line; do violation SHOULD NGX-10 "$line" "add_header inheritance trap"; done
done

# =============================================================================
section "F · Routing vs proxy prefix collision"
# =============================================================================
VITECFG=$(ls "$ROOT"/vite.config.* 2>/dev/null | head -1)
ROUTER=$(find "$SRC/app" -name 'router.tsx' 2>/dev/null | head -1)
if [[ -n "$VITECFG" && -n "$ROUTER" ]]; then
  mapfile -t PROXIES < <(grep -oE "^\s*'(/[a-zA-Z0-9_-]+/?)'\s*:" "$VITECFG" | grep -oE "/[a-zA-Z0-9_/-]+" || true)
  mapfile -t ROUTES < <(grep -oE "path:\s*['\"]/[a-zA-Z0-9_/-]*['\"]" "$ROUTER" | grep -oE "/[a-zA-Z0-9_/-]*" || true)
  for p in "${PROXIES[@]}"; do
    [[ "$p" == */ ]] && continue   # trailing slash prefixes only match real sub-paths
    for r in "${ROUTES[@]}"; do
      if [[ "$r" == "$p"* && "$r" != "$p" ]]; then
        violation MUST RTE-16 "$VITECFG" "proxy prefix '$p' (no trailing slash) also matches SPA route '$r'; use '$p/'"
      fi
    done
  done
fi

# =============================================================================
section "G · i18n"
# =============================================================================
LOCALES="$SRC/shared/i18n/locales"
if [[ -d "$LOCALES" ]]; then
  n=$(find "$LOCALES" -mindepth 1 -maxdepth 1 -type d | wc -l)
  (( n < 2 )) && violation SHOULD I18N-01 "$LOCALES" "fewer than two locales"
  printf '        %srun tools/check-i18n.mjs for key parity%s\n' "$DIM" "$NC"
else
  [[ -d "$SRC" ]] && violation MUST I18N-01 "$SRC" "src/shared/i18n/locales not found"
fi

# =============================================================================
printf '\n'
if (( ERRORS > 0 )); then
  printf '%sFAILED%s  %d error(s), %d warning(s)\n' "$RED" "$NC" "$ERRORS" "$WARNINGS"
  exit 1
fi
printf '%sCLEAN%s   0 errors, %d warning(s)\n' "$GRN" "$NC" "$WARNINGS"
printf '%sReminder: tools cover about 6%% of the rules. RULE-MAP.md §1 and the checklist are still required.%s\n' "$DIM" "$NC"
exit 0
