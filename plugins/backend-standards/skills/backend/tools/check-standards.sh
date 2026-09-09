#!/usr/bin/env bash
# =============================================================================
#  check-standards.sh — automated audit for backend-standards
#
#  Usage:    ./tools/check-standards.sh [root-dir]
#  Exit:     0 = clean | 1 = a MUST/MUST NOT violation exists
#
#  This script audits the MACHINE-CHECKABLE rules of the standard. Rules it
#  does not cover are left to human/AI review — the coverage gap is listed at
#  the end (§end).
#
#  Design note: this is a heuristic, not proof. If it produces a false
#  positive, narrow the rule; do NOT silently disable it (see [CI-21], the ban
#  on unjustified //nolint).
# =============================================================================
set -uo pipefail

ROOT="${1:-.}"
ERRORS=0
WARNINGS=0

RED=$'\033[0;31m'; YEL=$'\033[0;33m'; GRN=$'\033[0;32m'; DIM=$'\033[2m'; NC=$'\033[0m'
[[ -t 1 ]] || { RED=""; YEL=""; GRN=""; DIM=""; NC=""; }

# violation <severity> <rule-id> <location> <message>
violation() {
  local sev="$1" id="$2" loc="$3" msg="$4"
  if [[ "$sev" == "MUST" ]]; then
    printf '%sERROR%s   [%s] %s\n         %s\n' "$RED" "$NC" "$id" "$loc" "$msg"
    ERRORS=$((ERRORS+1))
  else
    printf '%sWARN%s  [%s] %s\n         %s\n' "$YEL" "$NC" "$id" "$loc" "$msg"
    WARNINGS=$((WARNINGS+1))
  fi
}

section() { printf '\n%s── %s %s\n' "$DIM" "$1" "$NC"; }

# Scanner that strips comment lines from Go files.
# Example code inside a comment must not count as a violation.
scan() {
  local pat="$1"; shift
  grep -nHE "$pat" "$@" 2>/dev/null | grep -vE ':[0-9]+:[[:space:]]*//' || true
}

go_files()  { find "$ROOT" -name '*.go' -not -name '*_test.go' -not -path '*/vendor/*' 2>/dev/null; }
sql_files() { find "$ROOT" -name '*.sql' -not -path '*/vendor/*' 2>/dev/null; }

mapfile -t GO_FILES < <(go_files)
mapfile -t SQL_FILES < <(sql_files)

printf '%s\n' "backend-standards — automated audit"
printf '%s\n' "root: $ROOT · $(( ${#GO_FILES[@]} )) go · $(( ${#SQL_FILES[@]} )) sql"

# =============================================================================
section "A · Dependencies and versioning"
# =============================================================================

while IFS= read -r f; do
  give=$(grep -E '^go [0-9]' "$f" | head -1 | awk '{print $2}')
  [[ -n "$give" && "$give" != "1.25.12" ]] && \
    violation MUST VER-01 "$f" "go directive '$give' — standard is 1.25.12 ([02] §1)"
done < <(find "$ROOT" -name 'go.mod' -not -path '*/vendor/*' 2>/dev/null)

FORBIDDEN_DEPS='gofiber/fiber|labstack/echo|go-chi/chi|lib/pq|jinzhu/gorm|gorm\.io/gorm|go-pg/pg|entgo\.io/ent|spf13/viper|knadh/koanf|kelseyhightower/envconfig|uber-go/zap|go\.uber\.org/zap|rs/zerolog|sirupsen/logrus|stretchr/testify|gofrs/uuid'
while IFS= read -r hit; do
  dep=$(echo "$hit" | sed -E 's/.*[[:space:]]([a-z0-9./-]*(fiber|echo|chi|pq|gorm|pg|ent|viper|koanf|envconfig|zap|zerolog|logrus|testify|uuid)[a-z0-9./-]*).*/\1/')
  violation MUST VER-05 "${hit%%:*}:$(echo "$hit" | cut -d: -f2)" "banned dependency: $dep — the rejection rationale lives under adr/"
done < <(grep -nHE "$FORBIDDEN_DEPS" $(find "$ROOT" -name 'go.mod' 2>/dev/null) 2>/dev/null || true)

if [[ ${#GO_FILES[@]} -gt 0 ]]; then
  while IFS= read -r hit; do
    violation MUST VER-05 "${hit%:*}" "banned package imported"
  done < <(scan "\"(github\.com/(gofiber|labstack/echo|go-chi/chi|lib/pq|jinzhu/gorm|sirupsen/logrus|rs/zerolog|stretchr/testify)|gorm\.io|go\.uber\.org/zap)" "${GO_FILES[@]}" | cut -d: -f1,2)
  done_marker=1
fi

# =============================================================================
section "B · Money and sensitive data"
# =============================================================================

# Both spellings of every Turkish field name are listed. Go identifiers may contain
# Unicode letters, so `Ucret` and `Ücret` are two different, equally legal field
# names; matching only the ASCII form silently misses the other ([TOOL-02]).
MONEY_FIELD='(Amount|Tutar|Price|Fiyat|Debt|Borc|Borç|Balance|Bakiye|Ucret|Ücret|Fee|Total|Toplam|Paid|Odenen|Ödenen|Salary|Maas|Maaş|Cost|Maliyet)'
if [[ ${#GO_FILES[@]} -gt 0 ]]; then
  while IFS= read -r hit; do
    loc=$(echo "$hit" | cut -d: -f1,2)
    violation MUST MONEY-01 "$loc" "money field declared as float — use Money (int64 minor units) instead"
  done < <(scan "^[[:space:]]*[A-Z][A-Za-z]*${MONEY_FIELD}[A-Za-z]*[[:space:]]+\*?float(32|64)" "${GO_FILES[@]}")

  while IFS= read -r hit; do
    violation MUST AUTH-05 "$(echo "$hit" | cut -d: -f1,2)" "md5/sha1 imported — use argon2id for passwords"
  done < <(scan '"crypto/(md5|sha1)"' "${GO_FILES[@]}")

  while IFS= read -r hit; do
    violation MUST SEC-25 "$(echo "$hit" | cut -d: -f1,2)" "log line may contain a password/token/secret"
  done < <(scan '(log|Log|logger|slog)\.[A-Za-z]+\(.*(password|passwd|parola|sifre|şifre|token|secret|api_key|apikey)' "${GO_FILES[@]}")
fi

while IFS= read -r hit; do
  violation MUST MONEY-02 "$(echo "$hit" | cut -d: -f1,2)" "money column is a float type — use NUMERIC(n,2) instead"
done < <([[ ${#SQL_FILES[@]} -gt 0 ]] && grep -nHiE "${MONEY_FIELD}[a-z_]*[[:space:]]+(REAL|DOUBLE PRECISION|FLOAT|MONEY)" "${SQL_FILES[@]}" 2>/dev/null || true)

# =============================================================================
section "C · Database"
# =============================================================================

if [[ ${#SQL_FILES[@]} -gt 0 ]]; then
  while IFS= read -r hit; do
    violation MUST DB-05 "$(echo "$hit" | cut -d: -f1,2)" "SERIAL/BIGSERIAL primary key — use UUID DEFAULT gen_random_uuid() instead (IDOR)"
  done < <(grep -nHiE '(BIG)?SERIAL[[:space:]]+PRIMARY[[:space:]]+KEY' "${SQL_FILES[@]}" 2>/dev/null || true)

  while IFS= read -r hit; do
    violation MUST DB-06 "$(echo "$hit" | cut -d: -f1,2)" "TIMESTAMP (without tz) — use TIMESTAMPTZ instead"
  done < <(grep -nHiE '[[:space:]]TIMESTAMP([[:space:]]|,|$)' "${SQL_FILES[@]}" 2>/dev/null | grep -viE 'TIMESTAMPTZ|WITH TIME ZONE' || true)

  for f in "${SQL_FILES[@]}"; do
    if grep -qiE '^\s*--\s*\+goose Up' "$f" && ! grep -qiE '^\s*--\s*\+goose Down' "$f"; then
      violation MUST DB-12 "$f" "no goose Down block — the migration cannot be rolled back"
    fi
    if grep -qiE 'GEOMETRY[[:space:]]*\(' "$f" && ! grep -qiE 'USING[[:space:]]+GIST' "$f"; then
      violation MUST GIS-05 "$f" "GEOMETRY column present but no GIST index — the spatial query will do a full scan"
    fi
  done
fi

if [[ ${#GO_FILES[@]} -gt 0 ]]; then
  while IFS= read -r hit; do
    violation MUST DB-18 "$(echo "$hit" | cut -d: -f1,2)" "SELECT * — list the columns explicitly"
  done < <(scan 'SELECT[[:space:]]+\*' "${GO_FILES[@]}")

  while IFS= read -r hit; do
    violation MUST SEC-15 "$(echo "$hit" | cut -d: -f1,2)" "a VALUE is interpolated into SQL via Sprintf — use a parameter instead (SQL injection)"
  done < <(scan 'Sprintf\(.*(SELECT|INSERT|UPDATE|DELETE|WHERE).*%s' "${GO_FILES[@]}" | grep -viE '%s FROM|SELECT %s|%s WHERE|, where,' || true)

  while IFS= read -r hit; do
    violation MUST DB-19 "$(echo "$hit" | cut -d: -f1,2)" "ORDER BY + LIMIT with no tie-break — rows repeat/skip across pages"
  done < <(scan 'ORDER BY[^,)]*LIMIT' "${GO_FILES[@]}")
fi

# =============================================================================
section "D · HTTP layer and Gin"
# =============================================================================

if [[ ${#GO_FILES[@]} -gt 0 ]]; then
  while IFS= read -r hit; do
    violation MUST STR-13 "$(echo "$hit" | cut -d: -f1,2)" "gin.Default() — use gin.New() instead (Default adds its own logger, causing double logging)"
  done < <(scan 'gin\.Default\(\)' "${GO_FILES[@]}")

  while IFS= read -r hit; do
    violation MUST API-12 "$(echo "$hit" | cut -d: -f1,2)" "c.Bind*/BindJSON — use ShouldBindJSON instead (Bind* writes its own 400)"
  done < <(scan '\bc\.(Bind|BindJSON|BindQuery|BindUri|MustBindWith)\(' "${GO_FILES[@]}")

  while IFS= read -r hit; do
    violation MUST STR-19 "$(echo "$hit" | cut -d: -f1,2)" "c.JSON used for an error response — use AbortWithStatusJSON instead (the chain must stop)"
  done < <(scan 'c\.JSON\([[:space:]]*http\.Status(BadRequest|Unauthorized|Forbidden|NotFound|Conflict|TooManyRequests|InternalServerError|ServiceUnavailable)' "${GO_FILES[@]}")

  while IFS= read -r hit; do
    violation MUST STR-10 "$(echo "$hit" | cut -d: -f1,2)" "*gin.Context passed down to a lower layer — pass c.Request.Context() instead"
  done < <(scan '\.(svc|Svc|service|Service)\.[A-Z][A-Za-z]*\([[:space:]]*c[,)]' "${GO_FILES[@]}")

  for f in "${GO_FILES[@]}"; do
    if grep -q 'gin\.New()' "$f" && ! grep -q 'ContextWithFallback' "$f"; then
      violation MUST STR-14 "$f" "gin.New() present but ContextWithFallback not set — cancellation signal is lost"
    fi
    if grep -qE '&http\.Server\{' "$f" && ! grep -q 'ReadTimeout' "$f"; then
      violation MUST RES-07 "$f" "http.Server without timeouts — set ReadHeaderTimeout/ReadTimeout/WriteTimeout/IdleTimeout"
    fi
    if grep -qE '(&)?http\.Client\{[[:space:]]*\}' "$f"; then
      violation MUST RES-08 "$f" "http.Client without a timeout — the default is INFINITE"
    fi
  done
fi

# route permission check
while IFS= read -r f; do
  while IFS= read -r hit; do
    line=$(echo "$hit" | cut -d: -f2-)
    echo "$line" | grep -qE '/(health|ready|metrics|version)' && continue
    echo "$line" | grep -q 'RequirePermission\|RequireAny\|RequireAll' && continue
    violation MUST GEN-10 "$(echo "$hit" | cut -d: -f1,2)" "endpoint declared with no permission check — add RequirePermission or write the justification in a comment"
  done < <(scan '^[[:space:]]*[a-zA-Z_][a-zA-Z0-9_]*\.(GET|POST|PUT|DELETE|PATCH)\(' "$f")

  while IFS= read -r hit; do
    violation WARNINGS API-01b "$(echo "$hit" | cut -d: -f1,2)" "path contains '/list' — a list resource should live at the collection root (GET /resource)"
  done < <(scan '\.(GET|POST)\("/list"|"/[a-z-]+/list"' "$f")
done < <(find "$ROOT" -name 'routes*.go' -not -name '*_test.go' 2>/dev/null)

# =============================================================================
section "E · Logging, error handling, Turkish text"
# =============================================================================

if [[ ${#GO_FILES[@]} -gt 0 ]]; then
  while IFS= read -r hit; do
    violation MUST OBS-01 "$(echo "$hit" | cut -d: -f1,2)" "unstructured log — use log/slog instead"
  done < <(scan '(fmt\.Print(ln|f)?\(|[^g]log\.(Print|Printf|Println|Fatal|Fatalf)\()' "${GO_FILES[@]}")

  # Empty error block: both "if err != nil {" and "if err := f(); err != nil {" forms.
  for f in "${GO_FILES[@]}"; do
    awk -v F="$f" '
      /if .*err != nil[[:space:]]*\{[[:space:]]*$/ { line=NR; pending=1; next }
      pending && /^[[:space:]]*\}[[:space:]]*$/ { print F":"line; pending=0; next }
      { pending=0 }
    ' "$f" 2>/dev/null | while IFS= read -r loc; do
      violation MUST GEN-19 "$loc" "error swallowed (empty block) — handle it or return it up the call stack"
    done
  done

  # PUT DTO: every field must be a pointer [API-06]
  for f in "${GO_FILES[@]}"; do
    awk -v F="$f" '
      /^type[[:space:]]+[A-Za-z]*UpdateRequest[[:space:]]+struct[[:space:]]*\{/ { inb=1; next }
      inb && /^\}/ { inb=0; next }
      inb && /^[[:space:]]*\/\// { next }
      inb && /^[[:space:]]+[A-Z][A-Za-z0-9_]*[[:space:]]+[^*[:space:]]/ {
        if ($0 !~ /Version/) print F":"NR
      }
    ' "$f" 2>/dev/null | while IFS= read -r loc; do
      violation MUST API-06 "$loc" "PUT DTO field is not a pointer — updating one field zeroes out the others"
    done
  done

  while IFS= read -r hit; do
    violation WARNINGS TR-05 "$(echo "$hit" | cut -d: -f1,2)" "strings.ToLower/ToUpper — for Turkish text use cases.Lower(language.Turkish) instead"
  done < <(scan 'strings\.(ToLower|ToUpper|EqualFold)\(' "${GO_FILES[@]}")

  for f in "${GO_FILES[@]}"; do
    n=$(wc -l < "$f")
    base=$(basename "$f")
    if [[ "$base" == "main.go" && $n -gt 150 ]]; then
      violation WARNINGS STR-11 "$f" "main.go is $n lines — must not exceed 150 (wiring only)"
    elif [[ $n -gt 500 ]]; then
      violation WARNINGS STR-05 "$f" "$n lines — must not exceed 500, split the module"
    fi
  done
fi

# =============================================================================
section "F · Docker and compose"
# =============================================================================

while IFS= read -r f; do
  grep -qE '^FROM .*:latest' "$f" && violation MUST OPS-02 "$f" "base image is :latest — pin a version"
  grep -qE '^\s*USER ' "$f" || violation MUST OPS-03 "$f" "no USER — the container runs as root"
  grep -qiE '^\s*HEALTHCHECK' "$f" || violation MUST OPS-04 "$f" "no HEALTHCHECK"
done < <(find "$ROOT" -name 'Dockerfile*' -not -path '*/vendor/*' 2>/dev/null)

while IFS= read -r f; do
  while IFS= read -r hit; do
    violation MUST VER-02 "$(echo "$hit" | cut -d: -f1,2)" "image is :latest — pin a version"
  done < <(grep -nHE '^\s*image:[[:space:]]*[^[:space:]]+:latest' "$f" 2>/dev/null || true)

  while IFS= read -r hit; do
    violation MUST SEC-18 "$(echo "$hit" | cut -d: -f1,2)" "secret EMBEDDED in compose — use a \${VARIABLE} reference instead"
  done < <(grep -nHiE '^\s*[A-Z_]*(PASSWORD|SECRET|API_KEY|APIKEY|TOKEN|PRIVATE_KEY)[A-Z_]*:[[:space:]]*[^$[:space:]]' "$f" 2>/dev/null || true)

  while IFS= read -r hit; do
    violation WARNINGS SEC-01 "$(echo "$hit" | cut -d: -f1,2)" "'ports:' exposes the service externally — a non-gateway service should use 'expose:' instead"
  done < <(grep -nHE '^\s*ports:' "$f" 2>/dev/null || true)

  grep -q 'memory:' "$f" || violation WARNINGS PERF-05 "$f" "no memory limit set — a leak takes down the whole host"
  grep -q 'max-size:' "$f" || violation WARNINGS OPS-12 "$f" "no log rotation set — the json-file driver will fill the disk"
done < <(find "$ROOT" -name 'docker-compose*.yml' -o -name 'compose*.yml' 2>/dev/null)

# =============================================================================
section "G · Repo hygiene"
# =============================================================================

if [[ -d "$ROOT/.git" || -f "$ROOT/.gitignore" ]]; then
  if [[ ! -f "$ROOT/.gitignore" ]] || ! grep -q '\.env' "$ROOT/.gitignore" 2>/dev/null; then
    violation MUST SEC-20 "$ROOT/.gitignore" ".env pattern missing from .gitignore — a secret can enter git"
  fi
fi
while IFS= read -r d; do
  [[ -f "$d/.dockerignore" ]] || violation WARNINGS OPS-06 "$d/.dockerignore" "no .dockerignore — .env can end up in the image"
done < <(find "$ROOT" -name 'Dockerfile' -exec dirname {} \; 2>/dev/null | sed 's|/deployments$||' | sort -u)

# =============================================================================
printf '\n%s\n' "─────────────────────────────────────────────"
if [[ $ERRORS -eq 0 && $WARNINGS -eq 0 ]]; then
  printf '%sCLEAN%s — no violations in the automatically checkable rules\n' "$GRN" "$NC"
elif [[ $ERRORS -eq 0 ]]; then
  printf '%s%d warning(s)%s, no errors\n' "$YEL" "$WARNINGS" "$NC"
else
  printf '%s%d ERROR(S)%s, %d warning(s)\n' "$RED" "$ERRORS" "$NC" "$WARNINGS"
fi
printf '%sNote: this script checks ~8%% of the rules. The rest is left to human/AI\n' "$DIM"
printf 'review — scan the RULE-MAP.md §1 signal table.%s\n' "$NC"

[[ $ERRORS -gt 0 ]] && exit 1
exit 0
