#!/usr/bin/env bash
# =============================================================================
#  version-advice.sh — dependency freshness report (ADVICE; never FAIL)
#
#  Usage:
#    ./tools/version-advice.sh [root-dir] [options]
#
#  Options:
#    --skip-network   Skip the step that needs the network; only produce the
#                      go.mod 'go' directive table. (When CI has no network,
#                      or for a quick glance.)
#    --scan-major      Also query the next major line (path/vN+1) for direct
#                      dependencies. Adds extra network cost.
#    --limit <n>       Query at most n modules (for speed in large monorepos).
#    --timeout <sec>   Per-module query timeout. Default 120.
#    --json            Also print the summary as machine-readable JSON.
#
#  EXIT CODE: ALWAYS 0 — even if findings exist.
#  ------------------------------------------------------------------------
#  Why always 0:
#  This tool does NOT answer "was the standard followed?" That question is
#  asked by [VER-01] and audited by check-standards.sh; there, a violation
#  is a FAIL and blocks the merge. The question here is entirely different:
#  "does a newer version exist upstream?" The answer to that is not under
#  our control — even if we write no code, a dependency can release a new
#  version tomorrow. A FAIL tied to such an event breaks the pipeline over
#  a change we did not make. A broken pipeline then either gets bypassed or
#  the check gets disabled entirely (the same logic as [CI-20]: a long/noisy
#  pipeline starts getting skipped).
#  Also, [VER-03] makes a version upgrade its own PR; every new version is
#  not taken automatically. An upgrade is a DECISION, not a reflex.
#  That is why this tool produces findings, not decisions: exit code is
#  always 0.
#  ------------------------------------------------------------------------
#
#  Rules:
#    [VER-21] RECOMMENDED — Dependency freshness is reviewed at regular
#             intervals. This tool produces ADVICE; it does not break the
#             pipeline. It does not replace [VER-01] and is not to be
#             confused with it.
#    [TOOL-07] This tool.
#    References: [VER-01] the 'go' directive must equal the standard (the
#          FAIL-ing rule, the job of check-standards.sh) · [VER-08]/[ADR]
#          every major bump is handled one at a time, after reading the
#          relevant ADR · [GEN-03] a dependency not in the table requires
#          approval — a new version also requires approval.
#
#  HONESTY NOTE (see tools/README.md "Limits — honesty section"):
#    - Requires network. Without network, only the 'go' directive table is
#      produced, and this is stated explicitly; it is never silently
#      reported as "clean".
#    - `go list -m -u` CANNOT CROSS THE MAJOR BOUNDARY: v2 -> v3 is a
#      different module path. So the major line is scanned with a separate
#      query (--scan-major), and if it was not scanned the report says
#      "not scanned".
#    - "A newer version exists" is NOT a quality judgment. The new version
#      may not be better; it may be unmaintained; it may be breaking.
# =============================================================================
set -uo pipefail

RED=$'\033[0;31m'; YEL=$'\033[0;33m'; GRN=$'\033[0;32m'; DIM=$'\033[2m'; NC=$'\033[0m'
[[ -t 1 ]] || { RED=""; YEL=""; GRN=""; DIM=""; NC=""; }

# Same format as check-standards.sh; but here there is only one level: ONERI (advice).
# Deliberate: this tool has NO "MUST" level, because it does not decide.
ADVICE_COUNT=0
advise() {  # advise <rule-id> <location> <message>
  printf '%sADVICE%s  [%s] %s\n         %s\n' "$YEL" "$NC" "$1" "$2" "$3"
  ADVICE_COUNT=$((ADVICE_COUNT+1))
}
section() { printf '\n%s── %s %s\n' "$DIM" "$1" "$NC"; }
note()  { printf '%s%s%s\n' "$DIM" "$1" "$NC"; }

# 02-TECH-VERSIONS.md §1 — [VER-01]
STANDARD_GO="1.25.12"

ROOT="."
SKIP_NETWORK=0
SCAN_MAJOR=0
LIMIT=0
TIMEOUT=120
JSON_OUT=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --skip-network) SKIP_NETWORK=1; shift ;;
    --scan-major)   SCAN_MAJOR=1; shift ;;
    --limit)        LIMIT="${2:-0}"; shift 2 ;;
    --timeout)      TIMEOUT="${2:-120}"; shift 2 ;;
    --json)         JSON_OUT=1; shift ;;
    -h|--help)      sed -n '4,20p' "$0" | sed 's/^#\{1,\} \{0,1\}//'; exit 0 ;;
    -*)             printf '%sUSAGE ERROR%s unknown option: %s\n' "$RED" "$NC" "$1"; exit 0 ;;
    *)              ROOT="$1"; shift ;;
  esac
done

if [[ ! -d "$ROOT" ]]; then
  printf '%sUSAGE ERROR%s directory does not exist: %s\n' "$RED" "$NC" "$ROOT"
  exit 0   # this tool never breaks the pipeline, under any circumstance
fi

printf '%s\n' "backend-standards — dependency freshness advice [TOOL-07]"
printf '%s\n' "root: $ROOT · standard go: $STANDARD_GO"
note "This tool produces ADVICE and NEVER gives a FAIL ([VER-21])."
note "Standard-compliance auditing is a separate job: [VER-01] · tools/check-standards.sh"

mapfile -t GOMODS < <(find "$ROOT" -name 'go.mod' -not -path '*/vendor/*' 2>/dev/null | sort)
if [[ ${#GOMODS[@]} -eq 0 ]]; then
  printf '\n%sno go.mod found — nothing to do.%s\n' "$DIM" "$NC"
  exit 0
fi

# ---------------------------------------------------------------------------
# 1 · go directive distribution  (does NOT require network)
# ---------------------------------------------------------------------------
section "1 · go directive distribution — ${#GOMODS[@]} module(s)"

TMPD="$(mktemp -d "${TMPDIR:-/tmp}/version-advice-XXXXXX")" || { printf 'could not create temp directory\n'; exit 0; }
trap 'rm -rf "$TMPD"' EXIT

GO_LINES="$TMPD/go-direktif.txt"
: > "$GO_LINES"
for f in "${GOMODS[@]}"; do
  v="$(grep -m1 -E '^go[[:space:]]+[0-9]' "$f" 2>/dev/null | awk '{print $2}')"
  [[ -z "$v" ]] && v="(none)"
  printf '%s\t%s\n' "$v" "$f" >> "$GO_LINES"
done

printf '  %-12s %-7s %s\n' "version" "count" "status"
printf '  %s\n' "────────────────────────────────────────────────────────"
UYUMSUZ=0
DISTINCT_VERSIONS=0
while IFS=' ' read -r adet give; do
  [[ -z "$give" ]] && continue
  DISTINCT_VERSIONS=$((DISTINCT_VERSIONS+1))
  if [[ "$give" == "$STANDARD_GO" ]]; then
    printf '  %-12s %-7s %sstandard%s\n' "$give" "$adet" "$GRN" "$NC"
  else
    printf '  %-12s %-7s %sNOT the standard %s%s\n' "$give" "$adet" "$RED" "$STANDARD_GO" "$NC"
    UYUMSUZ=$((UYUMSUZ+adet))
  fi
done < <(cut -f1 "$GO_LINES" | sort | uniq -c | sort -rn | sed 's/^ *//')

if [[ $UYUMSUZ -gt 0 ]]; then
  printf '\n'
  advise VER-01 "$ROOT" \
    "$UYUMSUZ/${#GOMODS[@]} modules' 'go' directive is not the standard $STANDARD_GO. This is the subject of [VER-01], not this tool, and it is a FAIL there: run 'bash tools/check-standards.sh $ROOT'."
fi
if [[ $DISTINCT_VERSIONS -gt 1 ]]; then
  advise VER-21 "$ROOT" \
    "The repo has $DISTINCT_VERSIONS different 'go' versions. [VER-03] requires the upgrade to be taken together for ALL services; a version spread is by itself a consistency debt (the same code compiling under different language versions)."
fi
note "  Module breakdown: $GO_LINES (temporary) — for details use --json"

# ---------------------------------------------------------------------------
# 2 · Upstream version scan (REQUIRES network)
# ---------------------------------------------------------------------------
NETWORK_SKIP_REASON=""
if [[ $SKIP_NETWORK -eq 1 ]]; then
  NETWORK_SKIP_REASON="--skip-network given"
elif ! command -v go >/dev/null 2>&1; then
  NETWORK_SKIP_REASON="'go' command not on PATH"
fi

UPDATE_COUNT=0
MAJOR_COUNT=0
UPDATE_FILE="$TMPD/guncel.txt"
MAJOR_FILE="$TMPD/major.txt"
: > "$UPDATE_FILE"
: > "$MAJOR_FILE"

if [[ -n "$NETWORK_SKIP_REASON" ]]; then
  section "2 · Upstream version scan — SKIPPED"
  printf '  %sReason skipped: %s%s\n' "$YEL" "$NETWORK_SKIP_REASON" "$NC"
  printf '  This step runs `go list -m -u all`; this command asks the module\n'
  printf '  proxy (GOPROXY, default proxy.golang.org) over the NETWORK. Without\n'
  printf '  network or go, "is there a newer version" CANNOT BE ANSWERED.\n'
  printf '  %sImportant: this does NOT mean "dependencies are up to date" — it means unknown.%s\n' "$DIM" "$NC"
  printf '  Run again on a machine with network, or supply a local proxy:\n'
  printf '    GOPROXY=https://proxy.golang.org,direct bash tools/version-advice.sh %s\n' "$ROOT"
else
  section "2 · Upstream version scan"
  note "  \`go list -m -u all\` · per-module timeout ${TIMEOUT}s · GOWORK=off"
  note "  (GOWORK=off: if go.work exists, 'all' spreads across the entire workspace"
  note "   and the module's own dependencies cannot be distinguished. Each module"
  note "   is queried one at a time.)"

  TIMEOUT_CMD=""
  command -v timeout >/dev/null 2>&1 && TIMEOUT_CMD="timeout $TIMEOUT"

  COUNTER=0
  SCANNED=0
  for f in "${GOMODS[@]}"; do
    [[ $LIMIT -gt 0 && $COUNTER -ge $LIMIT ]] && { note "  --limit $LIMIT reached, remaining modules were not queried."; break; }
    COUNTER=$((COUNTER+1)); SCANNED=$COUNTER
    d="$(dirname "$f")"
    name="$(basename "$d")"
    RAW="$TMPD/ham-$COUNTER.txt"

    # -mod=readonly [VER-04]: this tool NEVER writes go.mod/go.sum. Read-only.
    if ! (cd "$d" && GOWORK=off GOFLAGS=-mod=readonly $TIMEOUT_CMD \
            go list -m -u -f '{{.Path}}|{{.Version}}|{{if .Update}}{{.Update.Version}}{{end}}|{{.Indirect}}' all) \
            > "$RAW" 2>"$TMPD/err-$COUNTER.txt"; then
      advise VER-21 "$f" "could not be queried — $(head -3 "$TMPD/err-$COUNTER.txt" | tr '\n' ' ' | cut -c1-180)"
      continue
    fi

    while IFS='|' read -r mod_path current latest indirect; do
      [[ -z "${latest:-}" ]] && continue
      [[ -z "${current:-}" ]] && continue
      # major/breaking bump? In Go, a MINOR bump on v0.x.y counts as breaking (semver item 4).
      km="$(printf '%s' "$current" | sed -E 's/^v([0-9]+)\.([0-9]+).*/\1 \2/')"
      lat_mm="$(printf '%s' "$latest"   | sed -E 's/^v([0-9]+)\.([0-9]+).*/\1 \2/')"
      m_maj="${km%% *}"; m_min="${km##* }"
      y_maj="${lat_mm%% *}"; y_min="${lat_mm##* }"
      breaking=0
      if [[ "$m_maj" != "$y_maj" ]]; then
        breaking=1
      elif [[ "$m_maj" == "0" && "$m_min" != "$y_min" ]]; then
        breaking=1
      fi
      label="direct"; [[ "$indirect" == "true" ]] && label="indirect"
      if [[ $breaking -eq 1 ]]; then
        printf '%s\t%s\t%s\t%s\t%s\n' "$name" "$mod_path" "$current" "$latest" "$label" >> "$MAJOR_FILE"
      else
        printf '%s\t%s\t%s\t%s\t%s\n' "$name" "$mod_path" "$current" "$latest" "$label" >> "$UPDATE_FILE"
      fi
    done < "$RAW"

    # --scan-major: go list -m -u cannot cross the major boundary; query the next line separately.
    if [[ $SCAN_MAJOR -eq 1 ]]; then
      while IFS='|' read -r mod_path current _latest indirect; do
        [[ "$indirect" == "true" ]] && continue
        [[ -z "$current" ]] && continue
        maj="$(printf '%s' "$current" | sed -E 's/^v([0-9]+).*/\1/')"
        [[ "$maj" =~ ^[0-9]+$ ]] || continue
        [[ "$maj" -lt 1 ]] && continue
        upper=$((maj+1))
        base_dir="$(printf '%s' "$mod_path" | sed -E 's#/v[0-9]+$##')"
        result="$(cd "$d" && GOWORK=off GOFLAGS=-mod=readonly $TIMEOUT_CMD \
                  go list -m -f '{{.Path}} {{.Version}}' "$base_dir/v$upper@latest" 2>/dev/null)"
        [[ -n "$result" ]] && printf '%s\t%s\t%s\t%s\t%s\n' \
          "$name" "$mod_path" "$current" "$(printf '%s' "$result" | awk '{print $2}') ($base_dir/v$upper)" "direct/major-line" >> "$MAJOR_FILE"
      done < "$RAW"
    fi
  done

  # -- safe updates
  if [[ -s "$UPDATE_FILE" ]]; then
    UPDATE_COUNT="$(sort -u "$UPDATE_FILE" | wc -l | tr -d ' ')"
    printf '\n  %sNewer version within the same major (%s unique record(s))%s\n' "$DIM" "$UPDATE_COUNT" "$NC"
    printf '  %-24s %-46s %-14s %-14s %s\n' "service" "module" "current" "new" "type"
    sort -u "$UPDATE_FILE" | awk -F'\t' '{printf "  %-24s %-46s %-14s %-14s %s\n", $1, $2, $3, $4, $5}'
    advise VER-21 "$ROOT" \
      "There are $UPDATE_COUNT update(s) within the same major. These SHOULD be backward-compatible per semver; still, per [VER-03] they are taken in a separate upgrade PR, together for all services. Not mandatory."
  else
    [[ -n "$NETWORK_SKIP_REASON" ]] || printf '\n  %sNo update within the same major.%s\n' "$GRN" "$NC"
  fi

  # -- possibly breaking bumps
  if [[ -s "$MAJOR_FILE" ]]; then
    MAJOR_COUNT="$(sort -u "$MAJOR_FILE" | wc -l | tr -d ' ')"
    printf '\n  %sPOSSIBLY BREAKING bump (%s unique record(s)) — major change or v0.x minor%s\n' "$YEL" "$MAJOR_COUNT" "$NC"
    printf '  %-24s %-46s %-14s %-14s %s\n' "service" "module" "current" "new" "type"
    sort -u "$MAJOR_FILE" | awk -F'\t' '{printf "  %-24s %-46s %-14s %-14s %s\n", $1, $2, $3, $4, $5}'
    advise VER-08 "$ROOT" \
      "There are $MAJOR_COUNT possibly breaking bump(s). These are handled ONE AT A TIME: read the relevant adr/ entry, review the changelog, each one becomes its own PR. Never taken in bulk via 'go get -u'."
    note "  Note: a MINOR bump on the v0.x line also counts as breaking (semver §4: there is no API stability commitment for v0)."
  fi

  if [[ $SCAN_MAJOR -eq 0 ]]; then
    note "  Major-line scan was not performed (enabled with --scan-major). \`go list -m -u\`"
    note "  cannot cross the major boundary: v2 -> v3 is a different module path, a separate query is required."
  fi
fi

# ---------------------------------------------------------------------------
# 3 · Summary
# ---------------------------------------------------------------------------
printf '\n%s\n' "─────────────────────────────────────────────"
printf '%s module(s) (%s scanned) · %s non-standard go directive(s) · %s update(s) · %s possibly breaking bump(s)\n' \
  "${#GOMODS[@]}" "${SCANNED:-0}" "$UYUMSUZ" "${UPDATE_COUNT:-0}" "${MAJOR_COUNT:-0}"
if [[ -n "$NETWORK_SKIP_REASON" ]]; then
  printf '%sUpstream scan SKIPPED (%s) — not "up to date", "unknown".%s\n' "$YEL" "$NETWORK_SKIP_REASON" "$NC"
fi
printf '%s%d advice item(s).%s None of them is a FAIL ([VER-21]); exit code is 0.\n' "$YEL" "$ADVICE_COUNT" "$NC"
printf '%sStandard-COMPLIANCE auditing is not in this tool, it is under [VER-01] and produces a FAIL:\n' "$DIM"
printf '  bash tools/check-standards.sh %s\n' "$ROOT"
printf 'A newer version ≠ a better version. An upgrade becomes its own PR per [VER-03] and\n'
printf 'is recorded in the table per [GEN-03]; it is never taken reflexively.%s\n' "$NC"

if [[ $JSON_OUT -eq 1 ]]; then
  printf '{"rule":"VER-21","tool":"TOOL-07","exit_code":0,'
  printf '"module":%d,"standard_go":"%s","non_standard_modules":%d,' \
    "${#GOMODS[@]}" "$STANDARD_GO" "$UYUMSUZ"
  printf '"go_directive_distribution":['
  first=1
  while IFS=' ' read -r adet give; do
    [[ -z "$give" ]] && continue
    [[ $first -eq 0 ]] && printf ','
    printf '{"version":"%s","count":%s,"standard":%s}' "$give" "$adet" \
      "$([[ "$give" == "$STANDARD_GO" ]] && echo true || echo false)"
    first=0
  done < <(cut -f1 "$GO_LINES" | sort | uniq -c | sort -rn | sed 's/^ *//')
  printf '],"network_skipped":%s,"network_skip_reason":"%s",' \
    "$([[ -n "$NETWORK_SKIP_REASON" ]] && echo true || echo false)" "$NETWORK_SKIP_REASON"
  printf '"updates":%s,"breaking_jumps":%s,"advice":%d}\n' \
    "${UPDATE_COUNT:-0}" "${MAJOR_COUNT:-0}" "$ADVICE_COUNT"
fi

# per [VER-21]: 0 whether or not there are findings. Rationale is in the header block.
exit 0
