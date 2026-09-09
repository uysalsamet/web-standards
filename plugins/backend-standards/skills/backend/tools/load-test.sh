#!/usr/bin/env bash
# =============================================================================
#  load-test.sh — compares a k6 load test against the standard's own targets
#
#  Usage:
#    ./tools/load-test.sh <target-url> [options]
#
#  Options:
#    --scenario <k6.js>      Your own k6 scenario. If not given, a simple GET
#                            scenario is generated into a temp file and deleted
#                            at the end of the run.
#    --duration <30s>        Test duration (10s, 1m, 2m30s...). Default 30s.
#    --vu <10>               Concurrent virtual users. Default 10.
#    --class <single|list|write|heavy>
#                            Which [PERF-01] target to compare against.
#                            Default: list.
#    --save <file>           A copy of the k6 summary is written here. DEFAULT: OFF.
#                            An audit tool does not drop files into the working
#                            directory uninvited: if it did, `git add .` would
#                            commit it. Give the path explicitly if you want a
#                            comparison archive.
#    --compare <file>        Print a diff table against a previous run's summary JSON.
#    --summary <file>        Don't run k6; evaluate the given summary JSON.
#                            (For the tool's own tests and re-interpreting an archive.)
#    --json                  Also print the result as machine-readable JSON.
#
#  Exit code:
#    0 = [PERF-01] targets met
#    1 = target exceeded
#    2 = k6 missing / measurement cannot be interpreted / usage error
#
#  Rules:
#    [PERF-33] A load test result is compared against the [PERF-01] targets; no
#              "looks fast" judgment is made.
#    [PERF-34] Measurement validity gate: an invalid measurement PRODUCES NO
#              pass/fail verdict. A measurement that cannot be interpreted is
#              treated as if no measurement was taken.
#    [TOOL-08] This tool.
#    References: [PERF-01] target table · [PERF-02] the decision is based on
#          p95/p99 · [PERF-21] no capacity claim without a load test.
#
#  HONESTY NOTE (see tools/README.md, "Limits — honesty section"):
#    A load test measurement depends on the ENVIRONMENT. The same code gives a
#    different number on a different machine, a different network, a
#    different data volume. The absolute numbers here are NOT a quality proof;
#    what's actually meaningful is the DIFFERENCE from a previous run in the
#    same environment (--compare). You do not look at a single run and say
#    "the service can handle this many requests."
# =============================================================================
set -uo pipefail

RED=$'\033[0;31m'; YEL=$'\033[0;33m'; GRN=$'\033[0;32m'; DIM=$'\033[2m'; NC=$'\033[0m'
[[ -t 1 ]] || { RED=""; YEL=""; GRN=""; DIM=""; NC=""; }

# same format as check-standards.sh: severity · rule-id · location · message
ERRORS=0
WARNINGS=0
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
note()  { printf '%s%s%s\n' "$DIM" "$1" "$NC"; }

usage() {
  sed -n '4,25p' "$0" | sed 's/^#\{1,\} \{0,1\}//'
  exit 2
}

# ---------------------------------------------------------------------------
# Arguments
# ---------------------------------------------------------------------------
TARGET=""
SCENARIO=""
DURATION="30s"
VU="10"
CLASS=""
# Default empty: the tool never writes a file anywhere on its own. Anyone who
# wants a comparison archive states its path themselves with --save ([TOOL-08]).
SAVE=""
COMPARE=""
EXTERNAL_SUMMARY=""
JSON_OUT=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --scenario)     SCENARIO="${2:-}"; shift 2 ;;
    --duration)     DURATION="${2:-}"; shift 2 ;;
    --vu)           VU="${2:-}"; shift 2 ;;
    --class)        CLASS="${2:-}"; shift 2 ;;
    --save)         SAVE="${2:-}"; shift 2 ;;
    --compare)      COMPARE="${2:-}"; shift 2 ;;
    --summary)      EXTERNAL_SUMMARY="${2:-}"; shift 2 ;;
    --json)         JSON_OUT=1; shift ;;
    -h|--help)      usage ;;
    -*)             printf '%sUSAGE ERROR%s unknown option: %s\n\n' "$RED" "$NC" "$1"; usage ;;
    *)              if [[ -z "$TARGET" ]]; then TARGET="$1"; else
                      printf '%sUSAGE ERROR%s extra argument: %s\n\n' "$RED" "$NC" "$1"; usage
                    fi; shift ;;
  esac
done

if [[ -z "$TARGET" && -z "$EXTERNAL_SUMMARY" ]]; then
  printf '%sUSAGE ERROR%s no target URL given.\n\n' "$RED" "$NC"
  usage
fi

if [[ -z "$CLASS" ]]; then
  CLASS="list"
  CLASS_DEFAULT=1
else
  CLASS_DEFAULT=0
fi

# [PERF-01] target table — p95 ceiling in ms
case "$CLASS" in
  single) HEDEF_P95=100;  SINIF_AD="single record read" ;;
  list)   HEDEF_P95=200;  SINIF_AD="list / page" ;;
  write)  HEDEF_P95=300;  SINIF_AD="write" ;;
  heavy)  HEDEF_P95=3000; SINIF_AD="heavy report / export" ;;
  *) printf '%sUSAGE ERROR%s --class is invalid: "%s" (single|list|write|heavy)\n' "$RED" "$NC" "$CLASS"; exit 2 ;;
esac
TARGET_ERROR_RATE=0.001   # [PERF-01] 5xx rate < 0.1%

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

# "1h2m30s" / "45s" / "2m" -> seconds. Returns empty if it can't be parsed.
duration_seconds() {
  awk -v s="$1" 'BEGIN{
    t=0; ok=0; buf="";
    n=split(s, ch, "");
    for(i=1;i<=n;i++){
      c=ch[i];
      if(c ~ /[0-9.]/){ buf=buf c; continue }
      if(buf==""){ print ""; exit }
      if(c=="h"){ t+=buf*3600; ok=1 }
      else if(c=="m"){ t+=buf*60; ok=1 }
      else if(c=="s"){ t+=buf; ok=1 }
      else { print ""; exit }
      buf="";
    }
    if(buf!=""){ t+=buf; ok=1 }
    if(!ok){ print ""; exit }
    printf "%.0f", t
  }'
}

# metric <summary.json> <metric-name> <field>
# Reads metrics.<name>.<field> from a k6 --summary-export output.
# No jq/python dependency ([VER-07] in spirit): the metric objects are flat
# (they contain no nested object), so searching for the "name" -> first "{" ->
# first "}" span for a literal field is enough. Field names contain
# parentheses ("p(95)"), so index() is used instead of a regex.
metric() {
  local file="$1" m="$2" f="$3"
  [[ -f "$file" ]] || return 0
  tr -d '\n\r' < "$file" | awk -v M="$m" -v F="$f" '
  {
    t=$0
    p=index(t, "\"" M "\"");           if(p==0) exit
    s=substr(t,p)
    q=index(s,"{");                    if(q==0) exit
    s=substr(s,q)
    e=index(s,"}");                    if(e==0) exit
    b=substr(s,1,e)
    k=index(b, "\"" F "\"");           if(k==0) exit
    v=substr(b, k+length(F)+2)
    sub(/^[ \t]*:[ \t]*/,"",v)
    if(match(v,/^-?[0-9]+(\.[0-9]+)?([eE][-+]?[0-9]+)?/)) print substr(v,1,RLENGTH)
  }'
}

# nb <value> [decimals] — prints "—" if empty, formats the number otherwise
nb() { awk -v v="${1:-}" -v d="${2:-2}" 'BEGIN{ if(v==""){print "—"} else printf "%."d"f", v }'; }

# compare_to <a> <op> <b> -> 0 true, 1 false. An empty value is ALWAYS false (no decision from missing data).
compare_to() {
  awk -v a="${1:-}" -v o="$2" -v b="${3:-}" 'BEGIN{
    if(a==""||b==""){ exit 1 }
    if(o==">"  && a>b)  exit 0
    if(o==">=" && a>=b) exit 0
    if(o=="<"  && a<b)  exit 0
    if(o=="<=" && a<=b) exit 0
    exit 1
  }'
}

TEMIZLE=()
cleanup() {
  local f
  for f in ${TEMIZLE[@]+"${TEMIZLE[@]}"}; do
    [[ -n "$f" && -f "$f" ]] && rm -f "$f"
  done
}
trap cleanup EXIT

printf '%s\n' "backend-standards — load test evaluation [TOOL-08]"

# ---------------------------------------------------------------------------
# 1 · Obtain the measurement
# ---------------------------------------------------------------------------
SUMMARY=""
DURATION_S=""

if [[ -n "$EXTERNAL_SUMMARY" ]]; then
  if [[ ! -f "$EXTERNAL_SUMMARY" ]]; then
    printf '%sERROR%s   [TOOL-08] summary file not found: %s\n' "$RED" "$NC" "$EXTERNAL_SUMMARY"
    exit 2
  fi
  SUMMARY="$EXTERNAL_SUMMARY"
  note "evaluating external summary: $EXTERNAL_SUMMARY (k6 was not run)"
else
  if ! command -v k6 >/dev/null 2>&1; then
    printf '\n%sERROR%s   [TOOL-08] k6 is not installed — cannot measure.\n' "$RED" "$NC"
    printf '         [PERF-21]: without a load test, you don'"'"'t get to say "it can handle this many requests".\n'
    printf '         This tool does not produce estimates; it requires a measurement.\n'
    printf '\n         Install:\n'
    printf '           macOS         : brew install k6\n'
    printf '           Debian/Ubuntu : https://grafana.com/docs/k6/latest/set-up/install-k6/\n'
    printf '                           (apt repo + key steps are there)\n'
    printf '           Windows       : winget install k6 --source winget\n'
    printf '           With Go       : go install go.k6.io/k6@latest\n'
    printf '           Docker        : docker run --rm -i grafana/k6 run - < scenario.js\n'
    printf '\n         If you already have a k6 summary on hand, you can evaluate it without k6:\n'
    printf '           bash tools/load-test.sh --summary <summary.json> --class list\n'
    exit 2
  fi

  DURATION_S="$(duration_seconds "$DURATION")"
  if [[ -z "$DURATION_S" ]]; then
    printf '%sUSAGE ERROR%s --duration could not be parsed: "%s" (e.g.: 30s, 2m, 1m30s)\n' "$RED" "$NC" "$DURATION"
    exit 2
  fi
  if ! [[ "$VU" =~ ^[0-9]+$ ]] || [[ "$VU" -lt 1 ]]; then
    printf '%sUSAGE ERROR%s --vu must be a positive integer: "%s"\n' "$RED" "$NC" "$VU"
    exit 2
  fi
  if [[ -n "$SCENARIO" && ! -f "$SCENARIO" ]]; then
    printf '%sUSAGE ERROR%s scenario file not found: %s\n' "$RED" "$NC" "$SCENARIO"
    exit 2
  fi

  if [[ -z "$SCENARIO" ]]; then
    SCENARIO="$(mktemp "${TMPDIR:-/tmp}/load-test-XXXXXX.js")" \
      || { printf '%sERROR%s could not create a temp file\n' "$RED" "$NC"; exit 2; }
    TEMIZLE+=("$SCENARIO")
    cat > "$SCENARIO" <<'K6_SENARYO'
// Default scenario generated by load-test.sh — deleted at the end of the run.
// Deliberately SIMPLE: fixed VU, a single GET endpoint.
// No threshold is defined: the pass/fail verdict is given by load-test.sh
// against the [PERF-01] targets. The decision logic must not live in two places.
import http from 'k6/http';
import { check } from 'k6';

export const options = {
  vus: Number(__ENV.YT_VU),
  duration: __ENV.YT_SURE,
  discardResponseBodies: false,
};

export default function () {
  const res = http.get(__ENV.YT_HEDEF);
  check(res, { 'response is not 4xx/5xx': (r) => r.status > 0 && r.status < 400 });
}
K6_SENARYO
  fi

  SUMMARY="$(mktemp "${TMPDIR:-/tmp}/yuk-ozet-XXXXXX.json")" \
    || { printf '%sERROR%s could not create a temp file\n' "$RED" "$NC"; exit 2; }
  TEMIZLE+=("$SUMMARY")

  note "target: $TARGET · duration: $DURATION ($DURATION_S s) · VU: $VU · class: $CLASS"
  section "k6 is running"
  k6 run \
    --vus "$VU" --duration "$DURATION" \
    --summary-export "$SUMMARY" \
    --summary-trend-stats "min,med,avg,p(95),p(99),max" \
    -e "YT_HEDEF=$TARGET" -e "YT_VU=$VU" -e "YT_SURE=$DURATION" \
    "$SCENARIO"
  K6_CODE=$?

  if [[ ! -s "$SUMMARY" ]]; then
    printf '\n%sERROR%s   [TOOL-08] k6 produced no summary file (k6 exit code %s).\n' "$RED" "$NC" "$K6_CODE"
    printf '         --summary-export was removed in some k6 versions. Add a\n'
    printf '         handleSummary() to your scenario and write the summary yourself, then:\n'
    printf '           bash tools/load-test.sh --summary <summary.json> --class %s\n' "$CLASS"
    exit 2
  fi
fi

# ---------------------------------------------------------------------------
# 2 · Extract the metrics
# ---------------------------------------------------------------------------
P50="$(metric "$SUMMARY" http_req_duration 'med')"
P95="$(metric "$SUMMARY" http_req_duration 'p(95)')"
P99="$(metric "$SUMMARY" http_req_duration 'p(99)')"
AVG="$(metric "$SUMMARY" http_req_duration 'avg')"
MIN="$(metric "$SUMMARY" http_req_duration 'min')"
MAX="$(metric "$SUMMARY" http_req_duration 'max')"
REQUESTS="$(metric "$SUMMARY" http_reqs 'count')"
RATE="$(metric "$SUMMARY" http_reqs 'rate')"
ERROR_RATE="$(metric "$SUMMARY" http_req_failed 'value')"
ERROR_COUNT="$(metric "$SUMMARY" http_req_failed 'passes')"

if [[ -z "$P95" || -z "$REQUESTS" ]]; then
  printf '\n%sERROR%s   [TOOL-08] could not parse the summary JSON: %s\n' "$RED" "$NC" "$SUMMARY"
  printf '         Expected shape: metrics.http_req_duration.{min,med,avg,p(95),p(99),max}\n'
  printf '         and metrics.http_reqs.count · metrics.http_req_failed.value\n'
  printf '         k6 must have been run with --summary-trend-stats "min,med,avg,p(95),p(99),max".\n'
  exit 2
fi
[[ -z "$ERROR_RATE" ]] && ERROR_RATE=0

# If an external summary was given, the test duration is unknown; derive it from request count / request rate.
if [[ -z "$DURATION_S" ]]; then
  DURATION_S="$(awk -v c="${REQUESTS:-0}" -v r="${RATE:-0}" 'BEGIN{ if(r>0) printf "%.0f", c/r; else print "" }')"
fi

section "Measurement"
printf '  requests        : %s\n' "$(nb "$REQUESTS" 0)"
printf '  duration (s)    : %s\n' "${DURATION_S:-—}"
printf '  error rate      : %%%s  (%s failed request(s))\n' \
  "$(awk -v v="$ERROR_RATE" 'BEGIN{printf "%.3f", v*100}')" "$(nb "${ERROR_COUNT:-}" 0)"
printf '  min / p50       : %s ms / %s ms\n' "$(nb "$MIN")" "$(nb "$P50")"
printf '  p95 / p99 / max : %s ms / %s ms / %s ms\n' "$(nb "$P95")" "$(nb "$P99")" "$(nb "$MAX")"
printf '  average         : %s ms %s(the verdict is NOT based on this number — [PERF-02])%s\n' \
  "$(nb "$AVG")" "$DIM" "$NC"

# ---------------------------------------------------------------------------
# 3 · [PERF-34] Measurement validity gate
#
#      A measurement can only meaningfully say "passed" if the measurement
#      itself is valid. Producing a verdict from an invalid measurement is
#      more dangerous than not measuring at all: someone who never measured
#      knows they don't know; someone who measured invalidly doesn't know
#      that what they believe is wrong.
# ---------------------------------------------------------------------------
section "Measurement validity gate [PERF-34]"
INVALID=0
gate() {  # gate <what-happened> <why-it-cant-be-interpreted> <what-to-do>
  printf '%sINVALID%s [PERF-34] %s\n' "$RED" "$NC" "$1"
  printf '         why : %s\n' "$2"
  printf '         do  : %s\n' "$3"
  INVALID=$((INVALID+1))
}

# 3.1 insufficient sample size
if compare_to "$REQUESTS" "<" 100; then
  gate "total requests $(nb "$REQUESTS" 0) — fewer than 100" \
       "p95 is the slowest 5% of the sample. Under 100 requests, fewer than 5 responses fall into that slice; a single slow request determines p95 on its own. The resulting number is noise, not statistics." \
       "Increase --duration and/or --vu; collect at least 100, preferably 1000+ requests."
fi

# 3.2 warm-up dominates
if [[ -n "$DURATION_S" ]] && compare_to "$DURATION_S" "<" 10; then
  gate "duration $DURATION_S s — shorter than 10 seconds" \
       "The first seconds are warm-up: the connection pool is empty, DNS hasn't resolved, the cache is cold, the GC/allocator hasn't warmed up. In a short test, what's measured is the warm-up cost, not the service's steady state." \
       "Give at least 30s for --duration. If warm-up is heavy, add a separate warm-up phase to the scenario and keep it out of the measurement."
fi

# 3.3 what's being measured is the error path
if compare_to "$ERROR_RATE" ">" 0.50; then
  gate "error rate %$(awk -v v="$ERROR_RATE" 'BEGIN{printf "%.1f", v*100}') — higher than 50%" \
       "More than half the requests failed. The measured duration is that of the ERROR path, not the business path; the error path is usually much shorter and makes p95 look artificially GOOD." \
       "Fix the error first (wrong URL/port, service down, missing auth, rate limit, TLS). A load test is run against a working service."
fi

# 3.4 tail disconnected from the body
if [[ -n "$P50" ]] && compare_to "$P50" ">" 0; then
  RATIO="$(awk -v a="$P95" -v b="$P50" 'BEGIN{printf "%.1f", a/b}')"
  if compare_to "$RATIO" ">" 10; then
    gate "p95/p50 = ${RATIO}x — greater than 10" \
         "The tail is 10x longer than the body. This is either environment noise (shared CPU, a build running alongside, VPN, laptop thermal throttling) or queue saturation (connection pool/worker exhausted, requests waiting). Either way, p95 is measuring wait time, not the service's own latency." \
         "Repeat the measurement on a quiet machine. If it recurs, the saturation is real: lower VU gradually to trace the saturation curve and apply the [PERF-18] profiling sequence."
  fi
fi

# 3.5 no distribution — suspicious
if [[ -n "$MIN" && -n "$MAX" ]] && compare_to "$REQUESTS" ">" 1; then
  FARK="$(awk -v a="$MAX" -v b="$MIN" 'BEGIN{printf "%.6f", a-b}')"
  if compare_to "$FARK" "<" 0.5; then
    gate "every response took the same time (min $(nb "$MIN" 3) ms ≈ max $(nb "$MAX" 3) ms)" \
         "A real service never produces a uniform duration, because of the network, the scheduler, and GC. This distribution shows either a perfect cache hit, a fixed mock/stub response, or that the request never reached the service at all (gateway/proxy short-circuit, 304, static file)." \
         "Verify the response body and status code; disable the cache or add a cache-busting parameter. Prove that what you're measuring is what you meant to measure."
  fi
fi

# 3.6 the client is corrupting its own measurement
if [[ -n "$TARGET" ]] \
   && [[ "$TARGET" == *localhost* || "$TARGET" == *127.0.0.1* || "$TARGET" == *"::1"* ]] \
   && [[ "$VU" =~ ^[0-9]+$ ]] && [[ "$VU" -gt 50 ]]; then
  gate "target is localhost and VU=$VU — greater than 50" \
       "The load generator and the service are competing for the same CPU on the same machine. At this VU level, part of the measured latency is k6's own saturation: the bill gets charged to the service, but the client is the culprit." \
       "Move the load generator to a separate machine. If you're staying on localhost, keep VU at 50 or below."
fi

if [[ $INVALID -eq 0 ]]; then
  printf '%sPASSED%s  all six gates are clean — the measurement can be interpreted\n' "$GRN" "$NC"
fi

# ---------------------------------------------------------------------------
# 4 · Comparison — a previous run in the same environment
# ---------------------------------------------------------------------------
if [[ -n "$COMPARE" ]]; then
  section "Difference from the previous run"
  if [[ ! -f "$COMPARE" ]]; then
    violation WARNINGS TOOL-08 "$COMPARE" "comparison file not found — the diff could not be computed"
  else
    PREV_P95="$(metric "$COMPARE" http_req_duration 'p(95)')"
    PREV_P99="$(metric "$COMPARE" http_req_duration 'p(99)')"
    PREV_ERROR="$(metric "$COMPARE" http_req_failed 'value')"
    PREV_REQUESTS="$(metric "$COMPARE" http_reqs 'count')"
    if [[ -z "$PREV_P95" ]]; then
      violation WARNINGS TOOL-08 "$COMPARE" "could not parse the previous summary — a k6 summary-export shape is expected"
    else
      delta() {  # delta <new> <old> <name> <unit>
        awk -v y="${1:-}" -v e="${2:-}" -v ad="$3" -v br="$4" 'BEGIN{
          if(e==""||y==""){ printf "  %-10s: —\n", ad; exit }
          d=y-e; p=(e!=0)? d/e*100 : 0;
          printf "  %-10s: %.2f%s -> %.2f%s   (%+.2f%s, %+.1f%%)\n", ad, e, br, y, br, d, br, p
        }'
      }
      delta "$P95" "$PREV_P95" "p95" " ms"
      delta "$P99" "$PREV_P99" "p99" " ms"
      delta "$(awk -v v="$ERROR_RATE" 'BEGIN{printf "%.4f", v*100}')" \
           "$(awk -v v="${PREV_ERROR:-0}" 'BEGIN{printf "%.4f", v*100}')" "errors" " %"
      delta "$REQUESTS" "$PREV_REQUESTS" "requests" ""
      note "  The diff is only meaningful for the SAME environment, SAME data volume, and SAME scenario."
    fi
  fi
fi

# ---------------------------------------------------------------------------
# 5 · Verdict
# ---------------------------------------------------------------------------
section "Verdict — [PERF-01] targets"
[[ $CLASS_DEFAULT -eq 1 ]] && note "  --class not given; defaulted to 'list'."
printf '  class: %s · target p95 < %s ms · target 5xx rate < 0.1%%\n' "$SINIF_AD" "$HEDEF_P95"

RESULT="undetermined"
if [[ $INVALID -gt 0 ]]; then
  printf '\n%sTHIS MEASUREMENT CANNOT BE INTERPRETED%s — %d validity gate(s) failed.\n' "$RED" "$NC" "$INVALID"
  printf '[PERF-34] An invalid measurement PRODUCES NO pass/fail verdict. Apply the "do"\n'
  printf 'items above and repeat the test. This run counts as no measurement having been\n'
  printf 'taken at all; per [PERF-21], do not make a capacity claim based on this result.\n'
  RESULT="uninterpretable"
else
  if compare_to "$P95" ">" "$HEDEF_P95"; then
    violation MUST PERF-33 "${TARGET:-$SUMMARY}" \
      "p95 $(nb "$P95") ms — the '$SINIF_AD' target is $HEDEF_P95 ms; $(awk -v a="$P95" -v b="$HEDEF_P95" 'BEGIN{printf "exceeded by %.0f ms (%.1fx)", a-b, a/b}') ([PERF-01])"
  fi
  if [[ -n "$P99" ]] && compare_to "$P99" ">" "$(awk -v h="$HEDEF_P95" 'BEGIN{print h*2}')"; then
    violation WARNINGS PERF-33 "${TARGET:-$SUMMARY}" \
      "p99 $(nb "$P99") ms — more than twice the p95 target; the tail is long, per [PERF-02] p99 must also be watched"
  fi
  if compare_to "$ERROR_RATE" ">" "$TARGET_ERROR_RATE"; then
    violation MUST PERF-33 "${TARGET:-$SUMMARY}" \
      "error rate %$(awk -v v="$ERROR_RATE" 'BEGIN{printf "%.3f", v*100}') — target is 0.1% ([PERF-01])"
  fi
  if [[ $ERRORS -eq 0 ]]; then
    printf '\n%sTARGETS MET%s — p95 %s ms < %s ms · error rate %%%s < %%0.1\n' \
      "$GRN" "$NC" "$(nb "$P95")" "$HEDEF_P95" \
      "$(awk -v v="$ERROR_RATE" 'BEGIN{printf "%.3f", v*100}')"
    RESULT="passed"
  else
    RESULT="failed"
  fi
fi

# ---------------------------------------------------------------------------
# 6 · Archive — a comparison is only possible once an archive exists
# ---------------------------------------------------------------------------
if [[ -z "$SAVE" ]]; then
  note "no archive written (default). To compare with the next run:"
  printf '         --save <path>/load-test-last.json   then: --compare <path>/load-test-last.json
'
elif [[ "$SUMMARY" != "$SAVE" ]]; then
  if cp -f "$SUMMARY" "$SAVE" 2>/dev/null; then
    note "summary saved: $SAVE   → next run: --compare $SAVE"
  else
    violation WARNINGS TOOL-08 "$SAVE" "could not save the summary — does the directory exist and is it writable?"
  fi
fi

printf '\n%s\n' "─────────────────────────────────────────────"
printf '%sNote: these numbers belong to the ENVIRONMENT, not the code. The same code gives\n' "$DIM"
printf 'a different result on another machine. Chase the DIFFERENCE in the same environment\n'
printf '(--compare), not the absolute number.\n'
printf 'This tool only looks at the [PERF-01] p95 and error-rate targets; for the\n'
printf 'saturation curve, CPU/memory usage, and the DB side, apply the [PERF-18] profiling sequence.%s\n' "$NC"

if [[ $JSON_OUT -eq 1 ]]; then
  printf '{"rule":"PERF-33","tool":"TOOL-08","result":"%s","class":"%s","hedef_p95_ms":%s,' \
    "$RESULT" "$CLASS" "$HEDEF_P95"
  printf '"p50_ms":%s,"p95_ms":%s,"p99_ms":%s,"min_ms":%s,"max_ms":%s,' \
    "${P50:-null}" "${P95:-null}" "${P99:-null}" "${MIN:-null}" "${MAX:-null}"
  printf '"requests":%s,"duration_s":%s,"error_rate":%s,"invalid_gates":%d,"errors":%d,"warnings":%d}\n' \
    "${REQUESTS:-null}" "${DURATION_S:-null}" "${ERROR_RATE:-null}" "$INVALID" "$ERRORS" "$WARNINGS"
fi

[[ $INVALID -gt 0 ]] && exit 2
[[ $ERRORS -gt 0 ]] && exit 1
exit 0
