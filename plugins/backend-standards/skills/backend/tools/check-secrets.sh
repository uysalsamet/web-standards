#!/usr/bin/env bash
# =============================================================================
#  check-secrets.sh — scans the repo for secret leaks  [TOOL-05]
#
#  Usage:    bash tools/check-secrets.sh [root-dir]
#  Exit:     0 = clean | 1 = at least one CRITICAL finding
#
#  This script ONLY DETECTS and WARNS. It FIXES NOTHING:
#  no git rm, no history cleanup, no rotation trigger, no file moves.
#  A secret leak is an incident response; a human makes the call. This
#  script is read-only.
#
#  Design note: this is a heuristic, not proof ([TOOL-01]). If it produces a
#  false positive, extend the exclusion list; do not silently disable the
#  check ([TOOL-02]).
#
#  MASKING RULE — [SEC-25]: an audit report must never publish the secret it
#  found. Only the file path, line number, finding type, and VARIABLE NAME
#  are printed. The value itself is never printed; at most the first 4
#  characters plus a length are shown so a finding can be distinguished from
#  another. Rationale: for patterns like AWS/JWT the first 4 characters are
#  already a fixed prefix that just names the finding type, so on its own it
#  does not make the secret usable; for values of 6 characters or fewer, not
#  even the prefix is shown.
# =============================================================================
set -uo pipefail

ROOT="${1:-.}"
CRITICAL=0
WARNINGS=0

RED=$'\033[0;31m'; YEL=$'\033[0;33m'; GRN=$'\033[0;32m'; DIM=$'\033[2m'; NC=$'\033[0m'
[[ -t 1 ]] || { RED=""; YEL=""; GRN=""; DIM=""; NC=""; }

# violation <severity> <rule-id> <location> <message>
violation() {
  local sev="$1" id="$2" loc="$3" msg="$4"
  if [[ "$sev" == "CRITICAL" ]]; then
    printf '%sCRITICAL%s [%s] %s\n         %s\n' "$RED" "$NC" "$id" "$loc" "$msg"
    CRITICAL=$((CRITICAL+1))
  else
    printf '%sWARN%s  [%s] %s\n         %s\n' "$YEL" "$NC" "$id" "$loc" "$msg"
    WARNINGS=$((WARNINGS+1))
  fi
}

section() { printf '\n%s── %s %s\n' "$DIM" "$1" "$NC"; }

# mask <value> → "abcd... (32 characters)"
# The full value is NEVER returned.
mask() {
  local v="$1" n=${#1}
  if (( n <= 6 )); then printf '**** (%d characters)' "$n"
  else printf '%s... (%d characters)' "${v:0:4}" "$n"; fi
}

# -----------------------------------------------------------------------------
# FALSE-POSITIVE EXCLUSION LIST — kept here in plain sight on purpose.
# If the lowercased value contains one of these patterns, it is not counted as
# a finding: placeholder, sample file value, env reference, template and
# format markers. The list is meant to be extended; extend it here instead of
# turning the check off.
# -----------------------------------------------------------------------------
FILTER='example|sample|dummy|test|change[-_ ]?me|xxx|your-|your_|yourname|redacted|placeholder|<|\$\{|\$\(|%s|%v|todo|fixme|foobar|\(|getenv|process\.env|os\.environ|viper\.|config\.|settings\.|null|none|empty|\.\.\.'

# Pattern that looks like a secret ASSIGNMENT: key name + separator + a literal
# value of 8+ characters.
# TRQ = single and double quote characters. ANSI-C quoting ($'...') is used in
# the tr/sed/grep expressions below for readability.
TRQ=$'\'"'
ASSIGN_PAT=$'(password|passwd|parola|sifre|secret|token|api_key|apikey|private_key|connection_string|conn_string)[\'"]?[[:space:]]*[:=][[:space:]]*[\'"]?[^\'"[:space:],;)}]{8,}'

# Strips comment lines (//, #, --). A sample secret inside a comment must not
# count as a violation.
# (same approach as scan() in check-standards.sh)
strip_comments() { grep -vE ':[0-9]+:[[:space:]]*(//|#|--)' || true; }

# Splits a grep hit line (file:line:content).
# On Windows paths the drive letter ("C:\...") itself contains a colon, so the
# drive prefix is recognized explicitly instead of relying on a naive
# ${h%%:*} cut.
hit_loc() { printf '%s' "$1" | sed -E 's/^(([A-Za-z]:)?[^:]*:[0-9]+):.*$/\1/'; }
hit_txt() { printf '%s' "$1" | sed -E 's/^([A-Za-z]:)?[^:]*:[0-9]+://'; }

shorten() { printf '%s' "$1" | tr 'A-Z' 'a-z'; }

# looks_secret <value> → returns 0 if it looks like a secret.
# Second exclusion layer: the FILTER list filters out known placeholders, this
# function filters out NATURAL LANGUAGE text. A real secret is either a
# mix of letters and digits, or long; UI strings such as "Password" /
# "Invalid password" in i18n translation files satisfy neither. (Accepted
# false negative: a purely alphabetic weak password like "postgres" slips
# through here — the compose check catches those.)
looks_secret() {
  local v="$1"
  (( ${#v} >= 20 )) && return 0
  printf '%s' "$v" | grep -q '[0-9]' && printf '%s' "$v" | grep -q '[A-Za-z]' && return 0
  return 1
}

# -----------------------------------------------------------------------------
# Source files to scan. vendor/, node_modules/, .git/, testdata/ are skipped.
# Files over 2 MB are skipped: data/lock files would choke the scan. This
# limit is deliberate.
# -----------------------------------------------------------------------------
src_files() {
  find "$ROOT" \
    \( -path '*/vendor/*' -o -path '*/node_modules/*' -o -path '*/.git/*' \
       -o -path '*/testdata/*' -o -path '*/dist/*' -o -path '*/build/*' \) -prune -o \
    -type f -size -2048k \
    \( -name '*.go' -o -name '*.yml' -o -name '*.yaml' -o -name '*.json' \
       -o -name '*.sql' -o -name 'Dockerfile*' \) -print 2>/dev/null
}

mapfile -t SRC_FILES < <(src_files)

printf '%s\n' "secret scan — DETECTION ONLY, no fix is applied  [TOOL-05]"
printf '%s\n' "root: $ROOT · ${#SRC_FILES[@]} source file(s) to scan"

# =============================================================================
section "A · Secret files TRACKED by git  [SEC-18][SEC-20][SEC-22]"
# =============================================================================
# This is the most critical finding: if the file is committed, the secret has
# already leaked.

if git -C "$ROOT" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  TRACKED_SECRETS='(^|/)\.env($|\.)|\.(pem|key|p12|pfx|jks)$|(^|/)id_rsa$|(^|/)credentials\.json$|(^|/)serviceaccount[^/]*\.json$'
  # .env.example / .env.sample / .env.template SHOULD be in git [SEC-21] — excluded.
  found=0
  while IFS= read -r f; do
    [[ -z "$f" ]] && continue
    found=1
    kind="secret file"
    case "$f" in
      *.pem|*.key|*.p12|*.pfx|*.jks|*id_rsa)        kind="private key / certificate" ;;
      *credentials.json|*serviceaccount*.json)      kind="service account credentials file" ;;
      *.env|*.env.*)                                kind="environment variable file" ;;
    esac
    violation CRITICAL SEC-18 "$f" "TRACKED by git ($kind) — committed; it persists in history and in every clone. [SEC-22] rotation is required."
  done < <(git -C "$ROOT" ls-files 2>/dev/null \
             | grep -E "$TRACKED_SECRETS" \
             | grep -vE '(^|/)\.env\.(example|sample|template)$' || true)
  (( found == 0 )) && printf '%s   no tracked secret file found.%s\n' "$DIM" "$NC"
else
  printf '%s   not a git repository — tracked-file check SKIPPED.%s\n' "$DIM" "$NC"
  printf '%s   (this check is the most conclusive proof of a leak; it cannot be done on a non-git copy)%s\n' "$DIM" "$NC"
fi

# =============================================================================
section "B · .gitignore gaps  [SEC-20]"
# =============================================================================

GI="$ROOT/.gitignore"
if [[ ! -f "$GI" ]]; then
  violation CRITICAL SEC-20 "$GI" "no .gitignore — secret files have no protection at all; creating one is the first step"
else
  grep -qE '(^|/)\.env' "$GI" 2>/dev/null || \
    violation WARNINGS SEC-20 "$GI" "no '.env' pattern — an environment file could be committed by mistake"
  grep -qE '\*\.pem' "$GI" 2>/dev/null || \
    violation WARNINGS SEC-20 "$GI" "no '*.pem' pattern — a certificate/private key could be committed"
  grep -qE '\*\.key' "$GI" 2>/dev/null || \
    violation WARNINGS SEC-20 "$GI" "no '*.key' pattern — a private key could be committed"
fi

# =============================================================================
section "C · Secret embedded in source code  [SEC-18]"
# =============================================================================

if (( ${#SRC_FILES[@]} > 0 )); then

  # C1 — literal-value secret assignment (password=, secret=, token=, api_key= ...)
  while IFS= read -r hit; do
    [[ -z "$hit" ]] && continue
    loc=$(hit_loc "$hit"); txt=$(hit_txt "$hit")
    m=$(printf '%s' "$txt" | grep -oiE "$ASSIGN_PAT" | head -1)
    [[ -z "$m" ]] && continue
    key=$(printf '%s' "$m" | sed -E 's/[:=].*$//' | tr -d "$TRQ ")
    val=$(printf '%s' "$m" | sed -E $'s/^[^:=]*[:=][[:space:]]*[\'"]?//' | sed -E $'s/[\'",;].*$//')
    (( ${#val} < 8 )) && continue
    shorten "$val" | grep -qE "$FILTER" && continue
    looks_secret "$val" || continue
    violation CRITICAL SEC-18 "$loc" "embedded secret: field '$key' has a literal value assigned → $(mask "$val")"
    # Compose files are scanned separately and more precisely in section D;
    # they are excluded here to avoid double reporting.
  done < <(grep -nHiE "$ASSIGN_PAT" "${SRC_FILES[@]}" 2>/dev/null \
             | grep -vE '(docker-)?compose[^:]*\.(yml|yaml):' | strip_comments)

  # C2 — AWS access key pattern
  while IFS= read -r hit; do
    [[ -z "$hit" ]] && continue
    v=$(hit_txt "$hit" | grep -oE 'AKIA[0-9A-Z]{16}' | head -1)
    [[ -z "$v" ]] && continue
    violation CRITICAL SEC-18 "$(hit_loc "$hit")" "AWS access key pattern → $(mask "$v")"
  done < <(grep -nHE 'AKIA[0-9A-Z]{16}' "${SRC_FILES[@]}" 2>/dev/null | strip_comments)

  # C3 — JWT pattern (header.payload)
  while IFS= read -r hit; do
    [[ -z "$hit" ]] && continue
    v=$(hit_txt "$hit" | grep -oE 'eyJ[A-Za-z0-9_-]{10,}\.eyJ[A-Za-z0-9_-]{4,}' | head -1)
    [[ -z "$v" ]] && continue
    violation CRITICAL SEC-18 "$(hit_loc "$hit")" "embedded JWT → $(mask "$v")  — a token must never be hard-coded [SEC-25]"
  done < <(grep -nHE 'eyJ[A-Za-z0-9_-]{10,}\.eyJ' "${SRC_FILES[@]}" 2>/dev/null | strip_comments)

  # C4 — connection string containing a password (postgres://user:password@host)
  # No part of the value is ever printed raw; the password is masked.
  while IFS= read -r hit; do
    [[ -z "$hit" ]] && continue
    dsn=$(hit_txt "$hit" | grep -oiE $'(postgres(ql)?|mysql|mongodb(\\+srv)?|redis|amqps?)://[^:@[:space:]\'"]+:[^@[:space:]\'"]{4,}@' | head -1)
    [[ -z "$dsn" ]] && continue
    parola=$(printf '%s' "$dsn" | sed -E 's|^[^:]*://[^:]*:||; s/@$//')
    shorten "$parola" | grep -qE "$FILTER" && continue
    looks_secret "$parola" || continue
    violation CRITICAL SEC-18 "$(hit_loc "$hit")" "password embedded in a connection string (DSN) → $(mask "$parola")"
  done < <(grep -nHiE '(postgres(ql)?|mysql|mongodb(\+srv)?|redis|amqps?)://[^:@[:space:]]+:[^@[:space:]]{4,}@' "${SRC_FILES[@]}" 2>/dev/null | strip_comments)

  # C5 — provider token prefixes (Slack, GitHub)
  while IFS= read -r hit; do
    [[ -z "$hit" ]] && continue
    v=$(hit_txt "$hit" | grep -oE '(xox[baprs]-[A-Za-z0-9-]{10,}|ghp_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{20,})' | head -1)
    [[ -z "$v" ]] && continue
    violation CRITICAL SEC-18 "$(hit_loc "$hit")" "provider token prefix (Slack/GitHub) → $(mask "$v")"
  done < <(grep -nHE '(xox[baprs]-[A-Za-z0-9-]{10,}|ghp_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{20,})' "${SRC_FILES[@]}" 2>/dev/null | strip_comments)

  # C6 — private key block header (content is never read, never printed)
  while IFS= read -r hit; do
    [[ -z "$hit" ]] && continue
    violation CRITICAL SEC-18 "$(hit_loc "$hit")" "private key block embedded in code (BEGIN … PRIVATE KEY) — content was not read"
  done < <(grep -nHE 'BEGIN (RSA |EC |DSA |OPENSSH |PGP )?PRIVATE KEY' "${SRC_FILES[@]}" 2>/dev/null | strip_comments)
fi

# Private key files are also searched for as files (they don't carry a source extension).
while IFS= read -r f; do
  [[ -z "$f" ]] && continue
  violation CRITICAL SEC-18 "$f" "private key file on disk — can leak into an image/artifact even if not in git [SEC-20]"
done < <(grep -rlE 'BEGIN (RSA |EC |DSA |OPENSSH |PGP )?PRIVATE KEY' "$ROOT" \
           --exclude-dir=vendor --exclude-dir=node_modules --exclude-dir=.git \
           --exclude-dir=testdata --include='*.pem' --include='*.key' --include='id_rsa' 2>/dev/null || true)

# =============================================================================
section "D · Secret embedded in docker-compose  [SEC-18]"
# =============================================================================
# A ${VARIABLE} reference is fine; a LITERAL value is the problem.

while IFS= read -r f; do
  [[ -z "$f" ]] && continue
  while IFS= read -r hit; do
    [[ -z "$hit" ]] && continue
    loc=$(hit_loc "$hit"); txt=$(hit_txt "$hit")
    key=$(printf '%s' "$txt" | sed -E 's/^[[:space:]]*-?[[:space:]]*//; s/[:=].*$//' | tr -d "$TRQ ")
    val=$(printf '%s' "$txt" | sed -E 's/^[^:=]*[:=][[:space:]]*//; s/[[:space:]]*(#.*)?$//' | tr -d "$TRQ")
    [[ -z "$val" ]] && continue
    shorten "$val" | grep -qE "$FILTER" && continue
    violation CRITICAL SEC-18 "$loc" "secret EMBEDDED in compose: '$key' → $(mask "$val")  — use a \${$key} reference instead"
  done < <(grep -nHiE '^[[:space:]]*-?[[:space:]]*[A-Z_]*(PASSWORD|PASSWD|SECRET|API_KEY|APIKEY|TOKEN|PRIVATE_KEY)[A-Z_]*[:=][[:space:]]*[^$[:space:]]' "$f" 2>/dev/null | strip_comments)
done < <(find "$ROOT" \( -path '*/vendor/*' -o -path '*/node_modules/*' -o -path '*/.git/*' \) -prune -o \
           -type f \( -name 'docker-compose*.yml' -o -name 'docker-compose*.yaml' -o -name 'compose*.yml' \) -print 2>/dev/null)

# =============================================================================
section "E · Secret in a log line  [SEC-25][SEC-26]"
# =============================================================================

mapfile -t GO_FILES < <(find "$ROOT" \( -path '*/vendor/*' -o -path '*/.git/*' -o -path '*/testdata/*' \) -prune -o \
                          -type f -name '*.go' -print 2>/dev/null)

if (( ${#GO_FILES[@]} > 0 )); then
  while IFS= read -r hit; do
    [[ -z "$hit" ]] && continue
    field=$(hit_txt "$hit" | grep -oiE '(password|passwd|parola|sifre|şifre|token|secret|api_key|apikey)' | head -1)
    violation CRITICAL SEC-25 "$(hit_loc "$hit")" "a secret field NAME appears in a log call: '$field' — mask it before logging"
    # Looking for the secret name inside QUOTES: slog field names and format
    # strings are quoted that way. The reason for this narrower match is
    # that identifier accesses like MQTT's token.Error() were being mistaken
    # for a secret ([TOOL-02]: narrow the rule).
  done < <(grep -nHE $'(log|Log|logger|slog)\\.[A-Za-z]+\\(.*[\'"][^\'"]{0,24}(password|passwd|parola|sifre|şifre|token|secret|api_key|apikey)[^\'"]{0,24}[\'"]' "${GO_FILES[@]}" 2>/dev/null | strip_comments)

  while IFS= read -r hit; do
    [[ -z "$hit" ]] && continue
    violation WARNINGS SEC-26 "$(hit_loc "$hit")" "log line uses %+v / %#v — this also prints any secret inside the struct"
  done < <(grep -nHE '(log|Log|logger|slog)\.[A-Za-z]+\(.*%[+#]v' "${GO_FILES[@]}" 2>/dev/null | strip_comments)
fi

# =============================================================================
printf '\n%s\n' "─────────────────────────────────────────────"
if (( CRITICAL == 0 && WARNINGS == 0 )); then
  printf '%sCLEAN%s — no secret leak found in the scanned patterns\n' "$GRN" "$NC"
elif (( CRITICAL == 0 )); then
  printf '%s%d warning(s)%s, no critical finding\n' "$YEL" "$WARNINGS" "$NC"
else
  printf '%s%d CRITICAL%s, %d warning(s)\n' "$RED" "$CRITICAL" "$NC" "$WARNINGS"
fi

if (( CRITICAL > 0 )); then
  printf '\n%s' "$RED"
  printf '%s\n' "════════════════════════════════════════════════════════════════════════"
  printf '%s\n' " CRITICAL — SECRET LEAK. THIS SCRIPT FIXED NOTHING."
  printf '%s\n' "════════════════════════════════════════════════════════════════════════"
  printf '%s' "$NC"
  printf '%s\n' "
This script ran read-only: it did not run git rm, did not clean history, did
not move any file, did not rotate any secret. The following is YOUR decision:

 1. ROTATE FIRST — [SEC-22]. If a secret entered git, reverting the commit is
    NOT ENOUGH; it stays in history, in clones, in CI cache, and in image
    layers. Change the value: password, API key, certificate, service
    account key. Any step taken without rotation is cosmetic.

 2. Untrack the file and add it to .gitignore — [SEC-20].
    Values go out, .env.example comes in: variable names present, values are
    placeholders — [SEC-21].

 3. History cleanup (git filter-repo / BFG) is A SEPARATE AND HEAVY DECISION:
    every commit hash changes, open PRs and existing clones break, it needs
    team coordination. It does not replace rotation, it complements it.
    This is not this script's job — it advises, it does not act.

 4. Determine the scope of the leak: how long has the secret been committed,
    is the repo public, are there forks/clones, did the value get printed to
    logs — [SEC-25], [SEC-26].

 5. This scan runs as a required CI step; a critical finding breaks the
    pipeline — [SEC-38], [CI-26]."
fi

printf '\n%sLimits [TOOL-01]: this scan is a heuristic, not proof. It is pattern-based —\n' "$DIM"
printf 'it does not compute entropy; it misses an unnamed or base64-embedded secret. Files\n'
printf 'over 2 MB, vendor/, node_modules/, testdata/ and GIT HISTORY are not scanned; only\n'
printf 'the working tree and the tracked-file list are examined. A clean result does not\n'
printf 'mean "no secret".%s\n' "$NC"

(( CRITICAL > 0 )) && exit 1
exit 0
