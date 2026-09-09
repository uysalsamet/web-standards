#!/usr/bin/env bash
# =============================================================================
#  run-collection.sh — run a Postman collection, examine correctness and timing
#
#  Usage:
#    ./tools/run-collection.sh <collection.json> [options]
#
#    --env <environment.json>  Postman environment file
#    --base-url <URL>       override the baseUrl variable (e.g. http://localhost:9000)
#    --repeat <N>            how many times the whole collection runs (default 3)
#    --code-dir <dir>        service source root — used to find code evidence for slowness
#    --analyze-only          send no requests; only statically inspect the collection
#    --json                  print machine-readable JSON instead of human output
#
#  Exit:   0 = run succeeded and the measurement is valid
#          1 = an assertion failed / a request errored / the validity gate tripped
#          2 = tool missing, target not up, or usage error
#
#  Why this tool exists ([TOOL-06]):
#    27 of 47 services have a Postman collection, and only 9 of those 27 have
#    any test script at all. So two-thirds of the collections verify nothing:
#    a dead artefact. [15-NEW-SERVICE-CHECKLIST.md] has you check off "the
#    collection runs", but no CI step actually runs it.
#    This script is that step ([TEST-23]).
#
#  Honesty note — non-negotiable ([PERF-32]):
#    This script DOES NOT DECIDE an SLO and DOES NOT REPORT a p95. [PERF-02]
#    requires the measurement to be based on p95/p99; a p95 cannot be
#    computed from 3 samples. The min/median/max produced here is only a
#    SMOKE TEST. For an SLO decision, use the load test tool ([PERF-33],
#    [PERF-21]).
#
#  Design note: like its sibling check-standards.sh, this is a HEURISTIC, not
#  proof. Endpoint classification and code analysis look at text patterns; if
#  it produces a false positive, NARROW the rule, do not silently disable it
#  ([TOOL-02]).
# =============================================================================
set -uo pipefail

# ----------------------------------------------------------------------------
# Constants — [PERF-01] targets (ms)
# ----------------------------------------------------------------------------
readonly HEDEF_TEK=100      # simple read (single record) p95 < 100 ms
readonly HEDEF_LISTE=200    # list/page          p95 < 200 ms
readonly HEDEF_YAZMA=300    # write               p95 < 300 ms
readonly HEDEF_AGIR=3000    # heavy report/export p95 < 3 s
readonly HEDEF_SAGLIK=100   # /health — [PERF-01] has no separate row for it, counted as a single record

readonly VARSAYILAN_TEKRAR=3
readonly GURULTU_ORANI=5    # max/min > 5 means the environment is noisy, the measurement can't be interpreted
readonly ASGARI_ISTEK=3     # fewer than this many requests, no comment is made
readonly ISTEK_ZAMAN_ASIMI_MS=15000

RED=$'\033[0;31m'; YEL=$'\033[0;33m'; GRN=$'\033[0;32m'; DIM=$'\033[2m'; BLD=$'\033[1m'; NC=$'\033[0m'
[[ -t 1 ]] || { RED=""; YEL=""; GRN=""; DIM=""; BLD=""; NC=""; }

# ----------------------------------------------------------------------------
# Arguments
# ----------------------------------------------------------------------------
COLLECTION=""
ENV_FILE=""
BASE_URL=""
REPEAT=$VARSAYILAN_TEKRAR
CODE_DIR=""
ANALYZE_ONLY=0
JSON_MODE=0

usage() {
  sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'
}

die() { printf '%sERROR%s  %s\n' "$RED" "$NC" "$1" >&2; exit "${2:-2}"; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --env)          ENV_FILE="${2:-}";      shift 2 || die "--env expects a file" ;;
    --base-url)     BASE_URL="${2:-}";  shift 2 || die "--base-url expects a URL" ;;
    --repeat)       REPEAT="${2:-}";     shift 2 || die "--repeat expects a number" ;;
    --code-dir)     CODE_DIR="${2:-}"; shift 2 || die "--code-dir expects a directory" ;;
    --analyze-only) ANALYZE_ONLY=1;     shift ;;
    --json)         JSON_MODE=1;          shift ;;
    -h|--help)      usage; exit 0 ;;
    -*)             die "unknown option: $1" ;;
    *)              [[ -z "$COLLECTION" ]] && COLLECTION="$1" || die "extra argument: $1"; shift ;;
  esac
done

[[ -n "$COLLECTION" ]] || { usage >&2; die "no collection file given"; }
[[ -f "$COLLECTION" ]] || die "collection file not found: $COLLECTION"
[[ -z "$ENV_FILE" || -f "$ENV_FILE" ]] || die "environment file not found: $ENV_FILE"
[[ -z "$CODE_DIR" || -d "$CODE_DIR" ]] || die "code directory not found: $CODE_DIR"
[[ "$REPEAT" =~ ^[0-9]+$ && "$REPEAT" -ge 1 ]] || die "--repeat must be a positive integer: '$REPEAT'"

# node is required both to parse JSON and to run newman.
command -v node >/dev/null 2>&1 || die "node not found — this tool requires node (newman also runs on node).
        Install: https://nodejs.org  ·  Windows: winget install OpenJS.NodeJS.LTS"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

FINDINGS="$TMP/findings.tsv"; : > "$FINDINGS"
ERRORS=0; WARNINGS=0

# emit <format> [args...] — human output is silent in JSON mode
emit() { [[ $JSON_MODE -eq 1 ]] || printf "$@"; }
section() { emit '\n%s── %s %s\n' "$DIM" "$1" "$NC"; }

# violation <severity> <rule-id> <location> <message>
violation() {
  local sev="$1" id="$2" loc="$3" msg="$4"
  printf '%s\t%s\t%s\t%s\n' "$sev" "$id" "$loc" "$msg" >> "$FINDINGS"
  if [[ "$sev" == "MUST" ]]; then
    emit '%sERROR%s   [%s] %s\n         %s\n' "$RED" "$NC" "$id" "$loc" "$msg"
    ERRORS=$((ERRORS+1))
  else
    emit '%sWARN%s  [%s] %s\n         %s\n' "$YEL" "$NC" "$id" "$loc" "$msg"
    WARNINGS=$((WARNINGS+1))
  fi
}

# ============================================================================
#  node helpers — parsing JSON by hand in bash would be fragile
# ============================================================================

cat > "$TMP/ortak.js" <<'JS_ORTAK'
'use strict';
// Endpoint classification — a HEURISTIC ([TOOL-01]).
// Derived from the method + path pattern; it does not know the real cost.
// Known blind spots:
//   - a POST /search is a READ but a method-based rule assumes it is a
//     "write"; that's why a POST whose path contains search/arama/sorgu/filtre
//     is counted as a list.
//   - GET /x/{id}/sub-list is not a "single record" but a list; if the last
//     segment isn't an id it's counted as a list, which gives the right
//     answer here but is not guaranteed in general.
//   - "heavy" detection only looks at the name/path; an endpoint with an
//     innocent name but an expensive implementation slips through.
const TARGET = { tek: 100, saglik: 100, liste: 200, yazma: 300, agir: 3000 };
const SINIF_AD = {
  tek: 'single record read', saglik: 'health endpoint',
  liste: 'list read', yazma: 'write', agir: 'heavy report/export',
};

function yolCikar(url) {
  let raw = '';
  if (typeof url === 'string') raw = url;
  else if (url && typeof url === 'object') {
    raw = url.raw || ((url.path || []).join('/'));
  }
  raw = String(raw || '');
  raw = raw.split('?')[0];
  raw = raw.replace(/^\{\{[^}]*\}\}/, '');          // strip {{baseUrl}}
  raw = raw.replace(/^[a-z]+:\/\/[^/]+/i, '');      // strip scheme+host
  if (!raw.startsWith('/')) raw = '/' + raw;
  return raw;
}

function idBenzeri(seg) {
  if (!seg) return false;
  if (/^\{\{.+\}\}$/.test(seg)) return true;                    // {{parkingId}}
  if (/^:.+/.test(seg)) return true;                            // :id
  if (/^\{.+\}$/.test(seg)) return true;                        // {id}
  if (/^\d+$/.test(seg)) return true;                           // 42
  if (/^[0-9a-f]{8}-[0-9a-f]{4}-/i.test(seg)) return true;      // uuid
  return false;
}

function sinifla(method, url, name) {
  const path = yolCikar(url).toLowerCase();
  const label = String(name || '').toLowerCase();
  const hepsi = path + ' ' + label;
  if (/(export|report|rapor|bulk|toplu|import|batch|excel|pdf|dokum|döküm|arsiv)/.test(hepsi)) return 'agir';
  if (/\/(health|healthz|ready|readyz|live|liveness|metrics|version)(\/|$)/.test(path)) return 'saglik';
  const m = String(method || 'GET').toUpperCase();
  if (m === 'GET' || m === 'HEAD') {
    const segs = path.split('/').filter(Boolean);
    return idBenzeri(segs[segs.length - 1]) ? 'tek' : 'liste';
  }
  // Search/query endpoints are written as POST but are reads — they're held
  // to the list target.
  if (/(search|arama|sorgu|query|filter|filtre|lookup|autocomplete|suggest|advise|öneri)/.test(path)) return 'liste';
  return 'yazma';
}

// The number of assertions in an item's OWN test scripts.
function assertionSay(item) {
  const ev = (item && item.event) || [];
  let n = 0;
  for (const e of ev) {
    if (!e || e.listen !== 'test') continue;
    const src = (e.script && e.script.exec) || [];
    const code = Array.isArray(src) ? src.join('\n') : String(src || '');
    const temiz = code.replace(/^\s*\/\/.*$/gm, '');
    // Summing the pm.test block AND the pm.expect calls inside it would
    // double count; the larger of the two is taken.
    const blok = (temiz.match(/pm\.test\s*\(/g) || []).length;
    const iddia = (temiz.match(/pm\.expect\s*\(/g) || []).length
                + (temiz.match(/pm\.response\.to\./g) || []).length
                + (temiz.match(/\btests\s*\[/g) || []).length;   // legacy Postman v1
    n += Math.max(blok, iddia);
  }
  return n;
}

function tsv(s) { return String(s == null ? '' : s).replace(/[\t\r\n]+/g, ' '); }

module.exports = { TARGET, SINIF_AD, yolCikar, idBenzeri, sinifla, assertionSay, tsv };
JS_ORTAK

cat > "$TMP/analiz.js" <<'JS_ANALIZ'
'use strict';
// Static collection analysis — runs without the service being up.
const fs = require('fs');
const { sinifla, yolCikar, assertionSay, tsv, SINIF_AD, TARGET } = require(process.argv[3]);

let kol;
try {
  kol = JSON.parse(fs.readFileSync(process.argv[2], 'utf8'));
} catch (e) {
  console.error('PARSE_ERROR\t' + e.message);
  process.exit(3);
}
if (!kol || !Array.isArray(kol.item)) {
  console.error('PARSE_ERROR\tNot a valid Postman v2.x collection (no item array)');
  process.exit(3);
}

const satirlar = [];
let toplamIstek = 0, toplamOwn = 0, assertionsuz = 0;
const kolAssert = assertionSay(kol);   // a collection-level test script applies to every request

function gez(items, yolAd, mirasAssert) {
  for (const it of items || []) {
    if (Array.isArray(it.item)) {
      gez(it.item, yolAd + '/' + (it.name || ''), mirasAssert + assertionSay(it));
      continue;
    }
    if (!it.request) continue;
    toplamIstek++;
    const r = it.request;
    const method = (typeof r === 'string' ? 'GET' : (r.method || 'GET')).toUpperCase();
    const url = typeof r === 'string' ? r : r.url;
    const own = assertionSay(it);
    toplamOwn += own;
    if (own + mirasAssert === 0) assertionsuz++;
    satirlar.push(['R', tsv(it.name), method, tsv(yolCikar(url)), own, mirasAssert,
                   sinifla(method, url, it.name)].join('\t'));
  }
}
gez(kol.item, '', kolAssert);

const out = [];
out.push(['M', 'name', tsv((kol.info && kol.info.name) || '(unnamed)')].join('\t'));
out.push(['M', 'toplam_istek', toplamIstek].join('\t'));
out.push(['M', 'toplam_assertion', toplamOwn + kolAssert].join('\t'));
out.push(['M', 'koleksiyon_duzeyi_assertion', kolAssert].join('\t'));
out.push(['M', 'assertionsuz_istek', assertionsuz].join('\t'));
for (const s of satirlar) out.push(s);
for (const k of Object.keys(TARGET)) out.push(['S', k, SINIF_AD[k], TARGET[k]].join('\t'));
process.stdout.write(out.join('\n') + '\n');
JS_ANALIZ

cat > "$TMP/olcum.js" <<'JS_OLCUM'
'use strict';
// Reads a newman JSON report: timing statistics + response correctness.
const fs = require('fs');
const { sinifla, yolCikar, tsv, TARGET } = require(process.argv[3]);

let rap;
try { rap = JSON.parse(fs.readFileSync(process.argv[2], 'utf8')); }
catch (e) { console.error('PARSE_ERROR\t' + e.message); process.exit(3); }

const run = (rap && rap.run) || {};
const exe = run.executions || [];
const grup = new Map();
let yanitsiz = 0, toplamCalisma = 0;
const findings = [];   // [severity, ruleId, location, message]
const gorulen = new Set();

function report(sev, id, loc, msg) {
  const anahtar = sev + '|' + id + '|' + loc + '|' + msg;
  if (gorulen.has(anahtar)) return;   // don't print the same violation 3 times for 3 repeats
  gorulen.add(anahtar);
  findings.push([sev, id, loc, msg]);
}

function body(res) {
  if (!res || !res.stream) return null;
  try {
    const buf = Buffer.from(res.stream.data || res.stream);
    return buf.toString('utf8');
  } catch (_) { return null; }
}

function basligiAl(res, name) {
  const h = (res && res.header) || [];
  for (const x of h) if (x && String(x.key).toLowerCase() === name) return String(x.value);
  return '';
}

for (const ex of exe) {
  toplamCalisma++;
  const it = ex.item || {};
  const name = it.name || '(unnamed)';
  const req = ex.request || {};
  const method = String(req.method || 'GET').toUpperCase();
  const path = yolCikar(req.url);
  const cls = sinifla(method, req.url, name);
  const anahtar = name + ' ' + method + ' ' + path;
  if (!grup.has(anahtar)) grup.set(anahtar, { name, method, path, cls, sureler: [], kodlar: new Set() });
  const g = grup.get(anahtar);

  const res = ex.response;
  if (!res || typeof res.code !== 'number') { yanitsiz++; continue; }
  g.sureler.push(res.responseTime || 0);
  g.kodlar.add(res.code);

  const location = method + ' ' + path;
  const ct = basligiAl(res, 'content-type');
  const code = res.code;

  // ---- Content-Type ----
  if (!/application\/json/i.test(ct)) {
    // 204/304 have no body, so expecting a Content-Type there would be wrong.
    if (code !== 204 && code !== 304) {
      report('WARNINGS', '04-§4', location, "Content-Type is not 'application/json': '" + (ct || '(none)') + "'");
    }
  }

  const ham = body(res);
  let obj = null, jsonMu = false;
  if (ham != null && ham.trim() !== '') {
    try { obj = JSON.parse(ham); jsonMu = true; } catch (_) { jsonMu = false; }
  }

  // ---- Status code class ----
  // If the request name starts with a status code like "400 — empty body",
  // this is a NEGATIVE test: a 4xx is the expected result, not a violation.
  // If the expectation isn't met, that itself is the finding.
  const beklenenEsl = String(name).match(/^\s*([1-5]\d\d)\b/);
  const expected = beklenenEsl ? Number(beklenenEsl[1]) : null;
  if (expected !== null && expected !== code) {
    report('MUST', 'TEST-24', location, 'request name expects ' + expected + ' but got ' + code + ' (' + name + ')');
  } else if (expected === null) {
    if (code >= 500) report('MUST', 'PERF-01', location, 'server error ' + code + ' — the 5xx rate target is 0.1% ([PERF-01])');
    else if (code >= 400) report('WARNINGS', 'TEST-23', location, 'client error ' + code + ' — the collection is stale or the environment is missing something');
  }

  if (!jsonMu) {
    if (code !== 204 && code !== 304 && ham && ham.trim() !== '') {
      report('WARNINGS', '04-§4', location, 'response body could not be parsed as JSON');
    }
    continue;
  }

  // ---- Error body [API-13] ----
  if (code >= 400) {
    const ok = obj && typeof obj === 'object' && obj.error === true && typeof obj.message === 'string';
    if (!ok) report('MUST', 'API-13', location, 'error body is not shaped as {"error":true,"message":"..."} ([04] §4.1)');
    else if (obj.code === undefined) report('BILGI', 'API-14', location, 'error body has no machine-readable "code" (RECOMMENDED)');
    continue;
  }

  if (code < 200 || code >= 300) continue;

  // ---- Success envelope ----
  // [API-16]: a list = data + meta, a SINGLE RECORD IS RETURNED DIRECTLY AS AN OBJECT (not wrapped).
  if (cls === 'liste') {
    if (Array.isArray(obj)) {
      report('MUST', 'API-16', location, 'list response is a bare array — must be {"data":[...],"meta":{...}} ([04] §4.2)');
    } else if (obj && typeof obj === 'object') {
      if (!('data' in obj)) report('MUST', 'API-16', location, 'list response has no "data" field ([04] §4.2)');
      const m = obj.meta;
      if (!m || typeof m !== 'object') {
        report('MUST', 'API-19', location, 'list response has no "meta" — a list endpoint without pagination is not allowed ([API-19])');
      } else {
        for (const field of ['page', 'limit']) {
          if (m[field] === undefined) report('MUST', 'API-16', location, 'meta.' + field + ' missing ([04] §4.2)');
        }
        if (m.total_items === undefined && m.total === undefined) {
          report('MUST', 'API-17', location, 'meta.total_items missing — the filtered total must be returned ([API-17])');
        }
        if (typeof m.limit === 'number' && m.limit > 200) {
          report('MUST', 'API-18', location, 'meta.limit=' + m.limit + ' — the upper bound is 200 ([API-18])');
        }
      }
      if (obj.data && typeof obj.data === 'object' && !Array.isArray(obj.data) && obj.data.data !== undefined) {
        report('MUST', 'API-16', location, 'double-wrapped (data.data) ([API-16])');
      }
    }
  } else if (cls === 'saglik') {
    if (!obj || typeof obj !== 'object' || obj.status === undefined) {
      report('WARNINGS', 'TEST-04', location, '/health body has no "status" — expected {"status":"healthy",...}');
    }
  } else if (cls === 'tek' || cls === 'yazma') {
    if (obj && typeof obj === 'object' && !Array.isArray(obj)
        && Object.keys(obj).length === 1 && obj.data !== undefined) {
      report('WARNINGS', 'API-16', location, 'single record wrapped in "data" — it must be returned as a bare object ([API-16])');
    }
  }
}

// ---- Timing statistics ----
function medyan(a) {
  const s = [...a].sort((x, y) => x - y);
  const n = s.length;
  if (n === 0) return 0;
  return n % 2 ? s[(n - 1) / 2] : Math.round((s[n / 2 - 1] + s[n / 2]) / 2);
}

const satirlar = [];
const medyanlar = [];
for (const g of grup.values()) {
  if (g.sureler.length === 0) continue;
  medyanlar.push(medyan(g.sureler));
}
const genelOrt = medyanlar.length ? Math.round(medyanlar.reduce((a, b) => a + b, 0) / medyanlar.length) : 0;

let gurultulu = 0;
for (const g of grup.values()) {
  const n = g.sureler.length;
  if (n === 0) {
    satirlar.push(['T', tsv(g.name), g.method, tsv(g.path), 0, '', '', '', 'no response', g.cls, '', ''].join('\t'));
    continue;
  }
  const mn = Math.min(...g.sureler), mx = Math.max(...g.sureler), md = medyan(g.sureler);
  // Noise metric: a ratio ALONE is not enough. 2ms→9ms is also a 4.5x ratio
  // but that's measurement noise, not a meaningful difference. That's why an
  // absolute difference is also required.
  if (mn > 0 && mx / mn > 5 && (mx - mn) > 20) gurultulu++;
  const target = TARGET[g.cls];
  const durum = md < target ? 'below target' : 'EXCEEDS TARGET';
  const delta = genelOrt > 0 ? Math.round(((md - genelOrt) / genelOrt) * 100) : 0;
  satirlar.push(['T', tsv(g.name), g.method, tsv(g.path), n, mn, md, mx,
                 [...g.kodlar].join(','), g.cls, durum, delta].join('\t'));
}

const out = [];
out.push(['M', 'yanitsiz', yanitsiz].join('\t'));
out.push(['M', 'toplam_calisma', toplamCalisma].join('\t'));
out.push(['M', 'endpoint', grup.size].join('\t'));
out.push(['M', 'genel_ortalama_medyan', genelOrt].join('\t'));
out.push(['M', 'gurultulu_endpoint', gurultulu].join('\t'));
out.push(['M', 'assertion_toplam', (run.stats && run.stats.assertions && run.stats.assertions.total) || 0].join('\t'));
out.push(['M', 'assertion_basarisiz', (run.stats && run.stats.assertions && run.stats.assertions.failed) || 0].join('\t'));
out.push(['M', 'istek_basarisiz', (run.stats && run.stats.requests && run.stats.requests.failed) || 0].join('\t'));
for (const s of satirlar) out.push(s);
for (const b of findings) out.push(['B', b[0], b[1], tsv(b[2]), tsv(b[3])].join('\t'));
process.stdout.write(out.join('\n') + '\n');
JS_OLCUM

# ============================================================================
#  1 · Static collection analysis (works without the service running)
# ============================================================================

ANALYSIS="$TMP/analiz.tsv"
if ! node "$TMP/analiz.js" "$COLLECTION" "$TMP/ortak.js" > "$ANALYSIS" 2>"$TMP/analiz.err"; then
  die "could not read the collection: $(cat "$TMP/analiz.err")"
fi

meta() { awk -F'\t' -v k="$2" '$1=="M" && $2==k {print $3}' "$1" | head -1; }

COLLECTION_NAME="$(meta "$ANALYSIS" name)"
TOTAL_REQUESTS="$(meta "$ANALYSIS" toplam_istek)"
TOTAL_ASSERTIONS="$(meta "$ANALYSIS" toplam_assertion)"
WITHOUT_ASSERTION="$(meta "$ANALYSIS" assertionsuz_istek)"
COLLECTION_LEVEL_ASSERTION="$(meta "$ANALYSIS" koleksiyon_duzeyi_assertion)"

emit '%s\n' "run-collection — Postman collection run and review [TOOL-06]"
emit '%s\n' "collection: $COLLECTION_NAME"
emit '%s\n' "file: $COLLECTION · $TOTAL_REQUESTS request(s) · $TOTAL_ASSERTIONS assertion(s)"

section "A · Collection inventory and endpoint classification"
emit '%s%s%s\n' "$DIM" "class is a heuristic: derived from the method + path pattern, it does not know the real cost ([TOOL-01])" "$NC"
emit '\n%-30s %-6s %-38s %-20s %-8s %s\n' "REQUEST" "METHOD" "PATH" "CLASS" "TARGET" "ASSERTIONS"
while IFS=$'\t' read -r tip name method path own miras cls; do
  [[ "$tip" == "R" ]] || continue
  class_name="$(awk -F'\t' -v k="$cls" '$1=="S" && $2==k {print $3}' "$ANALYSIS")"
  s_target="$(awk -F'\t' -v k="$cls" '$1=="S" && $2==k {print $4}' "$ANALYSIS")"
  tot=$((own + miras))
  if [[ $tot -eq 0 ]]; then
    emit '%-30.30s %-6s %-38.38s %-20.20s %-8s %snone%s\n' "$name" "$method" "$path" "$class_name" "<${s_target}ms" "$RED" "$NC"
  else
    emit '%-30.30s %-6s %-38.38s %-20.20s %-8s %d%s\n' "$name" "$method" "$path" "$class_name" "<${s_target}ms" "$tot" \
        "$([[ $miras -gt 0 ]] && echo " (${miras} inherited)" || echo "")"
  fi
done < "$ANALYSIS"
emit '\n%s%s%s\n' "$DIM" "targets: single record <${HEDEF_TEK}ms · list <${HEDEF_LISTE}ms · write <${HEDEF_YAZMA}ms · heavy <${HEDEF_AGIR}ms ([PERF-01])" "$NC"

# ---- Assertion gate — announced loudly ----
HAS_ASSERTION=1
if [[ "$TOTAL_ASSERTIONS" -eq 0 ]]; then
  HAS_ASSERTION=0
  emit '\n%s%s NO ASSERTIONS ANYWHERE IN THIS COLLECTION %s\n' "$RED$BLD" "▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄" "$NC"
  emit '%s\n' "  Not one of the $TOTAL_REQUESTS requests has a test script. Running this collection"
  emit '%s\n' "  amounts to saying \"it returned 200\"; it DOES NOT VERIFY the body, a field, or the contract."
  emit '%s\n' "  This is a DEAD ARTEFACT: it sits in the repo unmaintained and creates false confidence."
  emit '%s\n\n' "  This run coming back \"successful\" proves nothing."
  violation MUST TEST-24 "$COLLECTION" "not one of the $TOTAL_REQUESTS requests in the collection has an assertion — every request must have at least one"
elif [[ "$WITHOUT_ASSERTION" -gt 0 ]]; then
  violation MUST TEST-24 "$COLLECTION" "$WITHOUT_ASSERTION of $TOTAL_REQUESTS requests have no assertion at all ([TEST-24])"
fi
[[ "$COLLECTION_LEVEL_ASSERTION" -gt 0 ]] && \
  emit '%s%s%s\n' "$DIM" "note: $COLLECTION_LEVEL_ASSERTION assertion(s) are defined at the collection level and inherited by every request" "$NC"

# ============================================================================
#  2 · Run
# ============================================================================

KOSUM_YAPILDI=0
NEWMAN_REPORT="$TMP/newman.json"
MEASUREMENT="$TMP/olcum.tsv"; : > "$MEASUREMENT"

if [[ $ANALYZE_ONLY -eq 1 ]]; then
  section "B · Run"
  emit '%s\n' "--analyze-only given: no requests were sent, no timing was measured."
else
  section "B · Run — newman"

  NEWMAN=""
  if command -v newman >/dev/null 2>&1; then
    NEWMAN="newman"
  elif command -v npx >/dev/null 2>&1; then
    # npx --yes: fetches newman temporarily if it isn't installed. Fails too if there's no network.
    if npx --yes newman --version >/dev/null 2>&1; then
      NEWMAN="npx --yes newman"
      emit '%s%s%s\n' "$DIM" "newman is not installed, using a temporary copy via 'npx --yes newman' (slow)" "$NC"
    fi
  fi

  if [[ -z "$NEWMAN" ]]; then
    printf '%sERROR%s  newman not found and npx could not run it either.\n' "$RED" "$NC" >&2
    printf '      Install:  npm install -g newman\n' >&2
    printf '      One-off:  npx --yes newman run "%s"\n' "$COLLECTION" >&2
    printf '      For a CI step: add it to [14-GIT-CI.md]'"'"'s pipeline ([TEST-23]).\n' >&2
    printf '\n      For static inspection only, without the service: --analyze-only\n' >&2
    exit 2
  fi

  # -n N: runs the ENTIRE collection N times.
  # Why -n instead of hammering a single endpoint repeatedly:
  #   Calling the same endpoint 3 times in a row measures the cache (Redis, PG
  #   shared_buffers, DNS, TLS session, connection pool) that the first
  #   request already warmed up — the 2nd and 3rd requests come out
  #   artificially fast. With -n the requests are naturally interleaved
  #   (health, search, stats, then health again) and other endpoints' load
  #   falls between each repeat. This isn't perfect either, but it's more
  #   honest than hammering back-to-back.
  CMD=( $NEWMAN run "$COLLECTION" -n "$REPEAT"
          --reporters cli,json --reporter-json-export "$NEWMAN_REPORT"
          --timeout-request "$ISTEK_ZAMAN_ASIMI_MS" --suppress-exit-code )
  [[ -n "$ENV_FILE" ]]     && CMD+=( --environment "$ENV_FILE" )
  [[ -n "$BASE_URL" ]] && CMD+=( --env-var "baseUrl=$BASE_URL" )

  emit '%s\n' "running: ${REPEAT}× full collection ($REPEAT sample(s) per endpoint, interleaved)"
  if [[ $JSON_MODE -eq 1 ]]; then
    "${CMD[@]}" >/dev/null 2>&1
  else
    "${CMD[@]}"
  fi

  [[ -f "$NEWMAN_REPORT" ]] || die "newman produced no report — the run could not start"

  if ! node "$TMP/olcum.js" "$NEWMAN_REPORT" "$TMP/ortak.js" > "$MEASUREMENT" 2>"$TMP/olcum.err"; then
    die "could not read the newman report: $(cat "$TMP/olcum.err")"
  fi
  KOSUM_YAPILDI=1
fi

# ============================================================================
#  3 · Correctness findings + timing table + validity gate
# ============================================================================

INVALID=0
INVALID_REASON=()
REASON_FILE="$TMP/nedenler.txt"; : > "$REASON_FILE"

if [[ $KOSUM_YAPILDI -eq 1 ]]; then
  UNANSWERED="$(meta "$MEASUREMENT" yanitsiz)"
  TOTAL_RUNS="$(meta "$MEASUREMENT" toplam_calisma)"
  ENDPOINT_COUNT="$(meta "$MEASUREMENT" endpoint)"
  OVERALL_AVG="$(meta "$MEASUREMENT" genel_ortalama_medyan)"
  NOISY="$(meta "$MEASUREMENT" gurultulu_endpoint)"
  ASSERT_TOTAL="$(meta "$MEASUREMENT" assertion_toplam)"
  ASSERT_FAILED="$(meta "$MEASUREMENT" assertion_basarisiz)"
  REQUEST_FAILED="$(meta "$MEASUREMENT" istek_basarisiz)"

  ANSWERED=$(( TOTAL_RUNS - UNANSWERED ))
  if [[ "$ANSWERED" -eq 0 ]]; then
    printf '%sERROR%s  Not a single request got a response (all %s runs were connection errors).\n' "$RED" "$NC" "$TOTAL_RUNS" >&2
    printf '      The target is not up, or baseUrl is wrong.\n' >&2
    printf '      Check:  docker compose ps  ·  curl -i <base-url>/health\n' >&2
    printf '      Give a base URL:  --base-url http://localhost:9000\n' >&2
    printf '      For static inspection only, without the service: --analyze-only\n' >&2
    exit 2
  fi

  section "C · Response correctness — envelope, status code, Content-Type ([04])"
  FINDING_COUNT=0
  while IFS=$'\t' read -r tip sev id loc msg; do
    [[ "$tip" == "B" ]] || continue
    FINDING_COUNT=$((FINDING_COUNT+1))
    if [[ "$sev" == "BILGI" ]]; then
      emit '%sINFO%s  [%s] %s\n         %s\n' "$DIM" "$NC" "$id" "$loc" "$msg"
    else
      violation "$sev" "$id" "$loc" "$msg"
    fi
  done < "$MEASUREMENT"
  [[ $FINDING_COUNT -eq 0 ]] && emit '%sNo findings%s — the responses appear to follow the standard'"'"'s envelope.\n' "$GRN" "$NC"

  if [[ "$ASSERT_FAILED" -gt 0 ]]; then
    violation MUST TEST-23 "$COLLECTION" "$ASSERT_FAILED of $ASSERT_TOTAL assertions failed — see the newman cli output for detail"
  fi
  if [[ "$REQUEST_FAILED" -gt 0 || "$UNANSWERED" -gt 0 ]]; then
    violation MUST TEST-23 "$COLLECTION" "$REQUEST_FAILED request error(s), $UNANSWERED unanswered run(s)"
  fi

  # ---- Validity gate ----
  [[ "$REPEAT" -lt 2 ]]                  && { INVALID=1; INVALID_REASON+=("repeat count is $REPEAT (<2) — a distribution cannot be derived from a single sample"); }
  [[ "$TOTAL_REQUESTS" -lt $ASGARI_ISTEK ]] && { INVALID=1; INVALID_REASON+=("the collection has $TOTAL_REQUESTS request(s) (<$ASGARI_ISTEK) — no basis for comparison"); }
  [[ "$HAS_ASSERTION" -eq 0 ]]           && { INVALID=1; INVALID_REASON+=("the collection has no assertions at all — the timings belong to unverified responses ([TEST-24])"); }
  [[ "$ANSWERED" -eq 0 ]]                 && { INVALID=1; INVALID_REASON+=("no response was received at all"); }
  [[ "$NOISY" -gt 0 ]]               && { INVALID=1; INVALID_REASON+=("$NOISY endpoint(s) have a max/min ratio >$GURULTU_ORANI — the environment is noisy"); }

  # were all responses 4xx/5xx?
  OK_RESPONSES=$(awk -F'\t' '$1=="T" && $9!="no response" {print $9}' "$MEASUREMENT" | tr ',' '\n' | awk '$1>=200 && $1<400' | wc -l)
  [[ "$OK_RESPONSES" -eq 0 ]] && { INVALID=1; INVALID_REASON+=("no endpoint returned 2xx/3xx — what was measured is the error path"); }

  for _n in ${INVALID_REASON[@]+"${INVALID_REASON[@]}"}; do printf '%s\n' "$_n"; done > "$REASON_FILE"

  section "D · Timing measurement — ${REPEAT} sample(s)/endpoint"
  if [[ $INVALID -eq 1 ]]; then
    emit '\n%s%s THIS MEASUREMENT CANNOT BE INTERPRETED %s\n' "$RED$BLD" "▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄" "$NC"
    for n in "${INVALID_REASON[@]}"; do emit '  · %s\n' "$n"; done
    emit '%s\n' "  The timings below are listed as raw data; NO PERFORMANCE JUDGMENT IS MADE."
    violation MUST PERF-32 "$COLLECTION" "the measurement tripped the validity gate — no performance conclusion can be drawn from this run"
  fi

  emit '\n%-34s %-18s %6s %6s %6s %8s %s\n' "REQUEST" "CLASS" "MIN" "MED" "MAX" "TARGET" "STATUS"
  while IFS=$'\t' read -r tip name method path n mn md mx kodlar cls durum delta; do
    [[ "$tip" == "T" ]] || continue
    target="$(awk -F'\t' -v k="$cls" '$1=="S" && $2==k {print $4}' "$ANALYSIS")"
    class_name="$(awk -F'\t' -v k="$cls" '$1=="S" && $2==k {print $3}' "$ANALYSIS")"
    if [[ "$n" -eq 0 ]]; then
      emit '%-34.34s %-18.18s %s(no response)%s\n' "$name" "$class_name" "$RED" "$NC"
      continue
    fi
    if [[ $INVALID -eq 1 ]]; then
      emit '%-34.34s %-18.18s %6s %6s %6s %8s %s(no comment)%s\n' "$name" "$class_name" "$mn" "$md" "$mx" "<${target}ms" "$DIM" "$NC"
    else
      if [[ "$md" -lt "$target" ]]; then colour="$GRN"; else colour="$RED"; fi
      if [[ "$delta" -ge 0 ]]; then compare_to="${delta}% ABOVE the run average"; else compare_to="${delta#-}% below the run average"; fi
      emit '%-34.34s %-18.18s %6s %s%6s%s %6s %8s %s\n' "$name" "$class_name" "$mn" "$colour" "$md" "$NC" "$mx" "<${target}ms" "$compare_to"
      if [[ "$md" -ge "$target" ]]; then
        violation WARNINGS PERF-01 "$method $path" "median ${md}ms, $class_name target is <${target}ms — but this is NOT p95, a load test is needed to decide"
      fi
    fi
  done < "$MEASUREMENT"

  emit '\n%s%s%s\n' "$DIM" "average of the endpoint medians in this run: ${OVERALL_AVG}ms" "$NC"
  emit '\n%s%s%s\n' "$BLD" "── HONESTY NOTE [PERF-32] ──" "$NC"
  emit '%s\n' "  The numbers above are NOT p95 and p95 cannot be computed: there are $REPEAT sample(s) per endpoint."
  emit '%s\n' "  [PERF-02] REQUIRES the measurement to be based on p95/p99; $REPEAT sample(s) does not satisfy that."
  emit '%s\n' "  This table is a SMOKE TEST: it answers \"is there something here?\", NOT \"does the SLO hold?\"."
  emit '%s\n' "  For an SLO decision, use the load test tool ([PERF-33], [PERF-21]: k6/vegeta)."
  emit '%s\n' "  Also, the measurement is client-side: the network, the gateway, and the machine's current load are all inside these timings."
fi

# ============================================================================
#  4 · Code analysis — evidence of slowness in the source
# ============================================================================

code_finding() { violation "$1" "$2" "$3" "$4"; }

if [[ -n "$CODE_DIR" ]]; then
  section "E · Code analysis — $CODE_DIR"
  emit '%s%s%s\n' "$DIM" "text-pattern based, a HEURISTIC ([TOOL-01]); every finding is given with a file:line as evidence" "$NC"

  # We search the code for the request path: migration and seed files run once,
  # at startup; a loop-body query or a COUNT(*) there does not affect the
  # endpoint's runtime. That's why the performance heuristics leave them OUT
  # OF SCOPE (they were a source of false positives).
  mapfile -t KD_GO < <(find "$CODE_DIR" -name '*.go' -not -name '*_test.go' \
    -not -path '*/vendor/*' -not -path '*/migration*/*' -not -path '*/seed*/*' 2>/dev/null)
  mapfile -t KD_SQL < <(find "$CODE_DIR" -name '*.sql' -not -path '*/vendor/*' 2>/dev/null)
  emit '%s\n' "$(( ${#KD_GO[@]} )) go · $(( ${#KD_SQL[@]} )) sql file(s) scanned (migration/seed excluded)"

  if [[ ${#KD_GO[@]} -eq 0 ]]; then
    emit '%s\n' "No Go files — code analysis skipped."
  else
    probe() { local pat="$1"; shift; grep -nHE "$pat" "$@" 2>/dev/null | grep -vE ':[0-9]+:[[:space:]]*//' || true; }
    # grep output is 'path:line:content'. Since the path can contain a drive
    # letter like 'C:', 'cut -d:' cuts WRONG; a greedy .* takes the longest
    # path, and what follows is the line number.
    location() { sed -E 's/^(.*):([0-9]+):.*$/\1:\2/'; }

    # --- SELECT * [DB-18] ---
    while IFS= read -r hit; do
      [[ -n "$hit" ]] || continue
      code_finding MUST DB-18 "$hit" \
        "SELECT * found — carries unnecessary columns, blocks an index-only scan, and silently bloats the response when the schema changes. List the columns explicitly."
    done < <(probe 'SELECT[[:space:]]+\*' "${KD_GO[@]}" | location)

    # --- ORDER BY with no tie-break / no LIMIT [DB-19] ---
    while IFS= read -r hit; do
      [[ -n "$hit" ]] || continue
      code_finding MUST DB-19 "$hit" \
        "ORDER BY + LIMIT with no tie-break column — the order is unstable on ties, rows repeat/skip across pages. Use a composite order like '(created_at DESC, id ASC)' ([DB-26])."
    done < <(probe 'ORDER BY[^,)]*LIMIT' "${KD_GO[@]}" | location)

    while IFS= read -r hit; do
      [[ -n "$hit" ]] || continue
      echo "$hit" | grep -qiE 'LIMIT' && continue
      # If queries are built piecewise (const + concat), LIMIT may be on another
      # line. If the SAME FILE has no LIMIT at all, the suspicion is real; if it
      # does, we stay quiet — we'd rather miss one than produce noise, because
      # noise is what erodes trust in the tool.
      file="$(echo "$hit" | sed -E 's/^(.*):[0-9]+:.*$/\1/')"
      grep -qiE 'LIMIT' "$file" 2>/dev/null && continue
      code_finding WARNINGS DB-19 "$(echo "$hit" | location)" \
        "ORDER BY present but the file has no LIMIT anywhere — the whole result set gets sorted as the table grows. Add pagination ([API-19])."
    done < <(probe 'ORDER BY' "${KD_GO[@]}")

    # --- Query inside a loop: N+1 suspicion ---
    # Tracks the for-block's brace depth to find a query inside the block.
    for f in "${KD_GO[@]}"; do
      awk -v F="$f" '
        {
          satir = $0
          sub(/[[:space:]]*\/\/.*$/, "", satir)
          if (dongude) {
            derinlik += gsub(/\{/, "{", satir)
            derinlik -= gsub(/\}/, "}", satir)
            if (satir ~ /\.(Query|QueryRow|QueryContext|QueryRowContext|Exec|ExecContext|Get|Select)\(/)
              print F":"NR
            if (derinlik <= 0) dongude = 0
          } else if (satir ~ /(^|[[:space:]])for[[:space:]].*\{[[:space:]]*$/ || satir ~ /(^|[[:space:]])for[[:space:]]*\{/) {
            dongude = 1; derinlik = 1
          }
        }
      ' "$f" 2>/dev/null | while IFS= read -r loc; do
        code_finding MUST PERF-22 "$loc" \
          "database call inside a loop (N+1 suspicion) — N records means N queries, the network round trip is multiplied by N. Turn it into one query (JOIN / WHERE id = ANY(\$1)) ([PERF-22] item 3)."
      done
    done

    # --- COUNT(*) used for pagination ---
    while IFS= read -r hit; do
      [[ -n "$hit" ]] || continue
      code_finding WARNINGS PERF-22 "$hit" \
        "COUNT(*) is used for pagination — in Postgres a filtered COUNT does a full scan, so COUNT ends up dictating the list endpoint's runtime as the table grows. Consider an estimated count or an 'is there a next page' (limit+1) approach."
    done < <(probe 'COUNT\([*]\)' "${KD_GO[@]}" | location)

    # --- http.Client with no timeout [RES-08] ---
    for f in "${KD_GO[@]}"; do
      if grep -qE '(&)?http\.Client\{[[:space:]]*\}' "$f"; then
        loc="$(grep -nE '(&)?http\.Client\{[[:space:]]*\}' "$f" | head -1 | cut -d: -f1)"
        code_finding MUST RES-08 "$f:$loc" \
          "http.Client with no timeout — the default is INFINITE. If the upstream doesn't respond, goroutines and connections leak, and the slowness spreads to this service. Set a timeout ([RES-08])."
      fi
    done

    # --- WHERE column with no visible index [DB-26] ---
    if [[ ${#KD_SQL[@]} -gt 0 ]]; then
      # The operator must be a SEPARATE WORD: 'AND ST_Intersects(' matching
      # 'st_' + 'IN' was producing a fake column called 'st_in' ([TOOL-02]:
      # narrow the rule, don't disable it).
      mapfile -t WCOL < <(grep -hoiE '(WHERE|AND)[[:space:]]+[a-z_][a-z0-9_]*([[:space:]]*(=|<>|!=|>=|<=|>|<)|[[:space:]]+(LIKE|ILIKE|IN)[[:space:](])' "${KD_GO[@]}" 2>/dev/null \
        | sed -E 's/^(WHERE|AND)[[:space:]]+//I' \
        | sed -E 's/[[:space:]]*(=|<>|!=|>=|<=|>|<).*$//' \
        | sed -E 's/[[:space:]]+(LIKE|ILIKE|IN)[[:space:](].*$//I' \
        | tr 'A-Z' 'a-z' | sort -u | grep -vE '^(id|1|true|false|null|deleted_at|and|or|not)$')
      INDEX_TEXT="$(grep -hiE 'CREATE( UNIQUE)? INDEX|PRIMARY KEY|UNIQUE[[:space:]]*\(' "${KD_SQL[@]}" 2>/dev/null | tr 'A-Z' 'a-z')"
      for c in "${WCOL[@]}"; do
        [[ -n "$c" ]] || continue
        if ! echo "$INDEX_TEXT" | grep -qE "[(,[:space:]]$c([),[:space:]]|$)"; then
          loc="$(grep -nHiE "(WHERE|AND)[[:space:]]+$c([[:space:]]*(=|<>|>=|<=|>|<)|[[:space:]]+(LIKE|ILIKE|IN)[[:space:](])" "${KD_GO[@]}" 2>/dev/null | head -1 | location)"
          code_finding WARNINGS DB-26 "${loc:-$CODE_DIR}" \
            "column '$c' is filtered in a WHERE clause but no CREATE INDEX for it appears in the migrations — the filter does a full scan. Add an index ([DB-26]); verify with EXPLAIN (ANALYZE, BUFFERS) ([PERF-18])."
        fi
      done
    else
      emit '%s%s%s\n' "$DIM" "note: no .sql file found — index check could not be run (migrations may live in another repo)" "$NC"
    fi

    # --- cache candidate [CACHE-02] ---
    if ! grep -rqiE 'redis|valkey|cache' "$CODE_DIR" --include='*.go' 2>/dev/null; then
      code_finding WARNINGS CACHE-02 "$CODE_DIR" \
        "no sign of redis/valkey/cache in the service. If it's read-heavy with rarely changing data, it's a cache candidate ([08], [CACHE-02]). NOTE: [CACHE-01] forbids adding a cache WITHOUT MEASURING first — show the slowness before adding one."
    fi

    # --- Slow endpoint → mark the matching file ---
    if [[ $KOSUM_YAPILDI -eq 1 && $INVALID -eq 0 ]]; then
      while IFS=$'\t' read -r tip name method path n mn md mx kodlar cls durum delta; do
        [[ "$tip" == "T" ]] || continue
        [[ "$durum" == "EXCEEDS TARGET" ]] || continue
        last="$(basename "$path")"
        match="$(grep -rnE "\"/?${last}\"|/${last}\"" "$CODE_DIR" --include='*.go' 2>/dev/null | head -3 | location)"
        if [[ -n "$match" ]]; then
          emit '\n%sPRIORITY%s  %s %s (median %sms) — matching location in source:\n' "$YEL" "$NC" "$method" "$path" "$md"
          while IFS= read -r e; do emit '           %s\n' "$e"; done <<< "$match"
        else
          emit '\n%sPRIORITY%s  %s %s (median %sms) — path string not found in source, could not map to a handler.\n' "$YEL" "$NC" "$method" "$path" "$md"
        fi
      done < "$MEASUREMENT"
    fi
  fi
fi

# ============================================================================
#  5 · Summary
# ============================================================================

if [[ $JSON_MODE -eq 1 ]]; then
  export KK_GECERSIZ="$INVALID" KK_TEKRAR="$REPEAT"
  node -e '
    const fs = require("fs");
    const [bulgularF, analizF, olcumF, nedenF] = process.argv.slice(1);
    const oku = f => { try { return fs.readFileSync(f, "utf8").split(/\r?\n/).filter(Boolean); } catch (_) { return []; } };
    const meta = (sat, k) => { for (const s of sat) { const p = s.split("\t"); if (p[0] === "M" && p[1] === k) return p[2]; } return null; };
    const analiz = oku(analizF), olcum = oku(olcumF);
    const cikti = {
      arac: "run-collection",
      rule: "TOOL-06",
      koleksiyon: { name: meta(analiz, "name"), istek: +meta(analiz, "toplam_istek"),
                    assertion: +meta(analiz, "toplam_assertion"),
                    assertionsuz_istek: +meta(analiz, "assertionsuz_istek") },
      olcum_gecerli: olcum.length === 0 ? null : process.env.KK_GECERSIZ !== "1",
      gecersizlik_nedenleri: oku(nedenF),
      p95_computed: false,
      slo_verdict: null,
      slo_notu: "This tool does not decide an SLO ([PERF-32]). [PERF-02] requires p95/p99; " +
                (process.env.KK_TEKRAR || "?") + " sample(s) per endpoint does not satisfy that. Use the load test tool ([PERF-33]).",
      endpointler: olcum.filter(s => s.startsWith("T\t")).map(s => {
        const p = s.split("\t");
        return { name: p[1], method: p[2], path: p[3], ornek: +p[4],
                 min_ms: p[5] === "" ? null : +p[5], medyan_ms: p[6] === "" ? null : +p[6],
                 maks_ms: p[7] === "" ? null : +p[7], durum_kodlari: p[8],
                 cls: p[9], sinif_sezgisel: true, hedefe_gore: p[10] || null };
      }),
      findings: oku(bulgularF).map(s => { const p = s.split("\t");
        return { level: p[0], rule: p[1], location: p[2], message: p[3] }; }),
    };
    process.stdout.write(JSON.stringify(cikti, null, 2) + "\n");
  ' "$FINDINGS" "$ANALYSIS" "$MEASUREMENT" "$REASON_FILE"
else
  printf '\n%s\n' "─────────────────────────────────────────────"
  if [[ $ERRORS -eq 0 && $WARNINGS -eq 0 ]]; then
    printf '%sCLEAN%s — run succeeded, no violations in the checkable rules\n' "$GRN" "$NC"
  elif [[ $ERRORS -eq 0 ]]; then
    printf '%s%d warning(s)%s, no errors\n' "$YEL" "$WARNINGS" "$NC"
  else
    printf '%s%d ERROR(S)%s, %d warning(s)\n' "$RED" "$ERRORS" "$NC" "$WARNINGS"
  fi
  printf '%sNote: this tool runs the collection and measures timing; it does NOT decide an SLO ([PERF-32]).\n' "$DIM"
  printf 'Endpoint class and code findings are heuristics, not proof ([TOOL-01]).\n'
  printf 'It should be added as a CI step — a collection that never runs is a dead artefact ([TEST-23]).%s\n' "$NC"
fi

[[ $ERRORS -gt 0 ]] && exit 1
exit 0
