#!/usr/bin/env bash
# =============================================================================
#  koleksiyon-kosum.sh — Postman koleksiyonunu koştur, doğruluğu ve süreyi incele
#
#  Kullanım:
#    ./arac/koleksiyon-kosum.sh <koleksiyon.json> [seçenekler]
#
#    --env <ortam.json>     Postman ortam dosyası
#    --taban-url <URL>      baseUrl değişkenini ez (örn. http://localhost:9000)
#    --tekrar <N>           koleksiyonun tamamının kaç kez koşacağı (varsayılan 3)
#    --kod-dizini <dizin>   servis kaynak kökü — yavaşlık için kod kanıtı aranır
#    --sadece-analiz        hiç istek atma; yalnızca koleksiyonu statik incele
#    --json                 insan çıktısı yerine makine okunur JSON bas
#
#  Çıkış:  0 = koşum başarılı ve ölçüm geçerli
#          1 = assertion başarısız / istek hatası / geçerlilik kapısı takıldı
#          2 = araç yok, hedef ayakta değil, veya kullanım hatası
#
#  Neden bu araç var ([ARAC-06]):
#    47 servisin 27'sinde Postman koleksiyonu var, o 27'nin yalnızca 9'unda
#    herhangi bir test scripti var. Yani koleksiyonların üçte ikisi hiçbir şey
#    doğrulamıyor: ölü artefakt. [15-YENI-SERVIS-CHECKLIST.md] "koleksiyon çalışır
#    durumda" diye işaretletiyor ama bunu koşturan hiçbir CI adımı yok.
#    Bu script o adımdır ([TEST-23]).
#
#  Dürüstlük notu — atlanamaz ([PERF-32]):
#    Bu script SLO KARARI VERMEZ ve p95 YAZMAZ. [PERF-02] ölçümün p95/p99
#    üzerinden yapılmasını ister; 3 örnekle p95 hesaplanamaz. Burada üretilen
#    min/medyan/maks yalnızca bir KOKU TESTİDİR. SLO kararı için yük testi
#    aracı kullanılır ([PERF-33], [PERF-21]).
#
#  Tasarım notu: kardeşi standart-kontrol.sh gibi bu da HEURİSTİKTİR, kanıt
#  değildir. Endpoint sınıflandırması ve kod analizi metin desenine bakar;
#  yanlış pozitif çıkarsa kuralı DARALT, sessizce kapatma ([ARAC-02]).
# =============================================================================
set -uo pipefail

# ----------------------------------------------------------------------------
# Sabitler — [PERF-01] hedefleri (ms)
# ----------------------------------------------------------------------------
readonly HEDEF_TEK=100      # basit okuma (tek kayıt) p95 < 100 ms
readonly HEDEF_LISTE=200    # liste/sayfa      p95 < 200 ms
readonly HEDEF_YAZMA=300    # yazma            p95 < 300 ms
readonly HEDEF_AGIR=3000    # ağır rapor/export p95 < 3 sn
readonly HEDEF_SAGLIK=100   # /health — [PERF-01]'de ayrı satırı yok, tek kayıt sayıldı

readonly VARSAYILAN_TEKRAR=3
readonly GURULTU_ORANI=5    # maks/min > 5 ise ortam gürültülü, ölçüm yorumlanamaz
readonly ASGARI_ISTEK=3     # bundan az istekle yorum yapılmaz
readonly ISTEK_ZAMAN_ASIMI_MS=15000

RED=$'\033[0;31m'; YEL=$'\033[0;33m'; GRN=$'\033[0;32m'; DIM=$'\033[2m'; BLD=$'\033[1m'; NC=$'\033[0m'
[[ -t 1 ]] || { RED=""; YEL=""; GRN=""; DIM=""; BLD=""; NC=""; }

# ----------------------------------------------------------------------------
# Argümanlar
# ----------------------------------------------------------------------------
KOLEKSIYON=""
ORTAM=""
TABAN_URL=""
TEKRAR=$VARSAYILAN_TEKRAR
KOD_DIZINI=""
SADECE_ANALIZ=0
JSON_MOD=0

kullanim() {
  sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'
}

hata_cik() { printf '%sHATA%s  %s\n' "$RED" "$NC" "$1" >&2; exit "${2:-2}"; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --env)          ORTAM="${2:-}";      shift 2 || hata_cik "--env bir dosya bekler" ;;
    --taban-url)    TABAN_URL="${2:-}";  shift 2 || hata_cik "--taban-url bir URL bekler" ;;
    --tekrar)       TEKRAR="${2:-}";     shift 2 || hata_cik "--tekrar bir sayı bekler" ;;
    --kod-dizini)   KOD_DIZINI="${2:-}"; shift 2 || hata_cik "--kod-dizini bir dizin bekler" ;;
    --sadece-analiz) SADECE_ANALIZ=1;    shift ;;
    --json)         JSON_MOD=1;          shift ;;
    -h|--help)      kullanim; exit 0 ;;
    -*)             hata_cik "bilinmeyen seçenek: $1" ;;
    *)              [[ -z "$KOLEKSIYON" ]] && KOLEKSIYON="$1" || hata_cik "fazladan argüman: $1"; shift ;;
  esac
done

[[ -n "$KOLEKSIYON" ]] || { kullanim >&2; hata_cik "koleksiyon dosyası verilmedi"; }
[[ -f "$KOLEKSIYON" ]] || hata_cik "koleksiyon dosyası bulunamadı: $KOLEKSIYON"
[[ -z "$ORTAM" || -f "$ORTAM" ]] || hata_cik "ortam dosyası bulunamadı: $ORTAM"
[[ -z "$KOD_DIZINI" || -d "$KOD_DIZINI" ]] || hata_cik "kod dizini bulunamadı: $KOD_DIZINI"
[[ "$TEKRAR" =~ ^[0-9]+$ && "$TEKRAR" -ge 1 ]] || hata_cik "--tekrar pozitif tam sayı olmalı: '$TEKRAR'"

# node hem JSON ayrıştırmak hem newman'ı koşturmak için zorunlu.
command -v node >/dev/null 2>&1 || hata_cik "node bulunamadı — bu araç node gerektirir (newman da node üzerinde koşar).
        Kurulum: https://nodejs.org  ·  Windows: winget install OpenJS.NodeJS.LTS"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

BULGULAR="$TMP/bulgular.tsv"; : > "$BULGULAR"
HATA=0; UYARI=0

# yaz <format> [args...] — JSON modunda insan çıktısı susar
yaz() { [[ $JSON_MOD -eq 1 ]] || printf "$@"; }
baslik() { yaz '\n%s── %s %s\n' "$DIM" "$1" "$NC"; }

# ihlal <seviye> <kural-id> <konum> <mesaj>
ihlal() {
  local sev="$1" id="$2" loc="$3" msg="$4"
  printf '%s\t%s\t%s\t%s\n' "$sev" "$id" "$loc" "$msg" >> "$BULGULAR"
  if [[ "$sev" == "ZORUNLU" ]]; then
    yaz '%sHATA%s   [%s] %s\n         %s\n' "$RED" "$NC" "$id" "$loc" "$msg"
    HATA=$((HATA+1))
  else
    yaz '%sUYARI%s  [%s] %s\n         %s\n' "$YEL" "$NC" "$id" "$loc" "$msg"
    UYARI=$((UYARI+1))
  fi
}

# ============================================================================
#  node yardımcıları — JSON'u bash'te elle ayrıştırmak kırılgan olurdu
# ============================================================================

cat > "$TMP/ortak.js" <<'JS_ORTAK'
'use strict';
// Endpoint sınıflandırması — SEZGİSELDİR ([ARAC-01]).
// Metot + yol deseninden çıkarılır; gerçek maliyeti bilmez.
// Bilinen kaçaklar:
//   - POST /search bir OKUMA'dır ama metoda bakan kural onu "yazma" sanır;
//     bu yüzden yolda search/arama/sorgu/filtre geçen POST'lar liste sayılır.
//   - GET /x/{id}/alt-liste "tek kayıt" değil listedir; son segment id değilse
//     liste sayılır, bu doğru sonucu verir ama garantisi yoktur.
//   - "ağır" tespiti yalnızca ada/yola bakar; adı masum ama pahalı bir uç kaçar.
const HEDEF = { tek: 100, saglik: 100, liste: 200, yazma: 300, agir: 3000 };
const SINIF_AD = {
  tek: 'tek kayıt okuma', saglik: 'sağlık ucu',
  liste: 'liste okuma', yazma: 'yazma', agir: 'ağır rapor/export',
};

function yolCikar(url) {
  let raw = '';
  if (typeof url === 'string') raw = url;
  else if (url && typeof url === 'object') {
    raw = url.raw || ((url.path || []).join('/'));
  }
  raw = String(raw || '');
  raw = raw.split('?')[0];
  raw = raw.replace(/^\{\{[^}]*\}\}/, '');          // {{baseUrl}} at
  raw = raw.replace(/^[a-z]+:\/\/[^/]+/i, '');      // şema+host at
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
  const yol = yolCikar(url).toLowerCase();
  const ad = String(name || '').toLowerCase();
  const hepsi = yol + ' ' + ad;
  if (/(export|report|rapor|bulk|toplu|import|batch|excel|pdf|dokum|döküm|arsiv|arşiv)/.test(hepsi)) return 'agir';
  if (/\/(health|healthz|ready|readyz|live|liveness|metrics|version)(\/|$)/.test(yol)) return 'saglik';
  const m = String(method || 'GET').toUpperCase();
  if (m === 'GET' || m === 'HEAD') {
    const segs = yol.split('/').filter(Boolean);
    return idBenzeri(segs[segs.length - 1]) ? 'tek' : 'liste';
  }
  // Arama/sorgu uçları POST ile yazılır ama okumadır — liste hedefine tabidir.
  if (/(search|arama|sorgu|query|filter|filtre|lookup|autocomplete|suggest|oneri|öneri)/.test(yol)) return 'liste';
  return 'yazma';
}

// Bir item'ın KENDİ test scriptlerindeki assertion sayısı.
function assertionSay(item) {
  const ev = (item && item.event) || [];
  let n = 0;
  for (const e of ev) {
    if (!e || e.listen !== 'test') continue;
    const src = (e.script && e.script.exec) || [];
    const kod = Array.isArray(src) ? src.join('\n') : String(src || '');
    const temiz = kod.replace(/^\s*\/\/.*$/gm, '');
    // pm.test bloğu ile içindeki pm.expect'i TOPLAMAK çift sayardı; büyük olan alınır.
    const blok = (temiz.match(/pm\.test\s*\(/g) || []).length;
    const iddia = (temiz.match(/pm\.expect\s*\(/g) || []).length
                + (temiz.match(/pm\.response\.to\./g) || []).length
                + (temiz.match(/\btests\s*\[/g) || []).length;   // Postman v1 mirası
    n += Math.max(blok, iddia);
  }
  return n;
}

function tsv(s) { return String(s == null ? '' : s).replace(/[\t\r\n]+/g, ' '); }

module.exports = { HEDEF, SINIF_AD, yolCikar, idBenzeri, sinifla, assertionSay, tsv };
JS_ORTAK

cat > "$TMP/analiz.js" <<'JS_ANALIZ'
'use strict';
// Statik koleksiyon analizi — servis ayakta olmadan çalışır.
const fs = require('fs');
const { sinifla, yolCikar, assertionSay, tsv, SINIF_AD, HEDEF } = require(process.argv[3]);

let kol;
try {
  kol = JSON.parse(fs.readFileSync(process.argv[2], 'utf8'));
} catch (e) {
  console.error('AYRISTIRMA_HATASI\t' + e.message);
  process.exit(3);
}
if (!kol || !Array.isArray(kol.item)) {
  console.error('AYRISTIRMA_HATASI\tGeçerli bir Postman v2.x koleksiyonu değil (item dizisi yok)');
  process.exit(3);
}

const satirlar = [];
let toplamIstek = 0, toplamOwn = 0, assertionsuz = 0;
const kolAssert = assertionSay(kol);   // koleksiyon düzeyi test scripti tüm isteklere uygulanır

function gez(items, yolAd, mirasAssert) {
  for (const it of items || []) {
    if (Array.isArray(it.item)) {
      gez(it.item, yolAd + '/' + (it.name || ''), mirasAssert + assertionSay(it));
      continue;
    }
    if (!it.request) continue;
    toplamIstek++;
    const r = it.request;
    const metot = (typeof r === 'string' ? 'GET' : (r.method || 'GET')).toUpperCase();
    const url = typeof r === 'string' ? r : r.url;
    const own = assertionSay(it);
    toplamOwn += own;
    if (own + mirasAssert === 0) assertionsuz++;
    satirlar.push(['R', tsv(it.name), metot, tsv(yolCikar(url)), own, mirasAssert,
                   sinifla(metot, url, it.name)].join('\t'));
  }
}
gez(kol.item, '', kolAssert);

const out = [];
out.push(['M', 'ad', tsv((kol.info && kol.info.name) || '(adsız)')].join('\t'));
out.push(['M', 'toplam_istek', toplamIstek].join('\t'));
out.push(['M', 'toplam_assertion', toplamOwn + kolAssert].join('\t'));
out.push(['M', 'koleksiyon_duzeyi_assertion', kolAssert].join('\t'));
out.push(['M', 'assertionsuz_istek', assertionsuz].join('\t'));
for (const s of satirlar) out.push(s);
for (const k of Object.keys(HEDEF)) out.push(['S', k, SINIF_AD[k], HEDEF[k]].join('\t'));
process.stdout.write(out.join('\n') + '\n');
JS_ANALIZ

cat > "$TMP/olcum.js" <<'JS_OLCUM'
'use strict';
// newman JSON raporunu okur: süre istatistikleri + yanıt doğruluğu.
const fs = require('fs');
const { sinifla, yolCikar, tsv, HEDEF } = require(process.argv[3]);

let rap;
try { rap = JSON.parse(fs.readFileSync(process.argv[2], 'utf8')); }
catch (e) { console.error('AYRISTIRMA_HATASI\t' + e.message); process.exit(3); }

const run = (rap && rap.run) || {};
const exe = run.executions || [];
const grup = new Map();
let yanitsiz = 0, toplamCalisma = 0;
const bulgular = [];   // [seviye, kuralId, konum, mesaj]
const gorulen = new Set();

function bul(sev, id, loc, msg) {
  const anahtar = sev + '|' + id + '|' + loc + '|' + msg;
  if (gorulen.has(anahtar)) return;   // 3 tekrar aynı ihlali 3 kez basmasın
  gorulen.add(anahtar);
  bulgular.push([sev, id, loc, msg]);
}

function govde(res) {
  if (!res || !res.stream) return null;
  try {
    const buf = Buffer.from(res.stream.data || res.stream);
    return buf.toString('utf8');
  } catch (_) { return null; }
}

function basligiAl(res, ad) {
  const h = (res && res.header) || [];
  for (const x of h) if (x && String(x.key).toLowerCase() === ad) return String(x.value);
  return '';
}

for (const ex of exe) {
  toplamCalisma++;
  const it = ex.item || {};
  const ad = it.name || '(adsız)';
  const req = ex.request || {};
  const metot = String(req.method || 'GET').toUpperCase();
  const yol = yolCikar(req.url);
  const sinif = sinifla(metot, req.url, ad);
  const anahtar = ad + ' ' + metot + ' ' + yol;
  if (!grup.has(anahtar)) grup.set(anahtar, { ad, metot, yol, sinif, sureler: [], kodlar: new Set() });
  const g = grup.get(anahtar);

  const res = ex.response;
  if (!res || typeof res.code !== 'number') { yanitsiz++; continue; }
  g.sureler.push(res.responseTime || 0);
  g.kodlar.add(res.code);

  const konum = metot + ' ' + yol;
  const ct = basligiAl(res, 'content-type');
  const kod = res.code;

  // ---- Content-Type ----
  if (!/application\/json/i.test(ct)) {
    // 204/304 gövdesizdir, Content-Type beklemek yanlış olur.
    if (kod !== 204 && kod !== 304) {
      bul('UYARI', '04-§4', konum, "Content-Type 'application/json' değil: '" + (ct || '(yok)') + "'");
    }
  }

  const ham = govde(res);
  let obj = null, jsonMu = false;
  if (ham != null && ham.trim() !== '') {
    try { obj = JSON.parse(ham); jsonMu = true; } catch (_) { jsonMu = false; }
  }

  // ---- Durum kodu sınıfı ----
  // İstek adı "400 — boş gövde" gibi bir durum kodu ile başlıyorsa bu bir NEGATİF
  // testtir: 4xx beklenen sonuçtur, ihlal değildir. Beklenti tutmuyorsa asıl bulgu odur.
  const beklenenEsl = String(ad).match(/^\s*([1-5]\d\d)\b/);
  const beklenen = beklenenEsl ? Number(beklenenEsl[1]) : null;
  if (beklenen !== null && beklenen !== kod) {
    bul('ZORUNLU', 'TEST-24', konum, 'istek adı ' + beklenen + ' bekliyor ama ' + kod + ' döndü (' + ad + ')');
  } else if (beklenen === null) {
    if (kod >= 500) bul('ZORUNLU', 'PERF-01', konum, 'sunucu hatası ' + kod + ' — 5xx oranı hedefi %0,1 ([PERF-01])');
    else if (kod >= 400) bul('UYARI', 'TEST-23', konum, 'istemci hatası ' + kod + ' — koleksiyon güncel değil ya da ortam eksik');
  }

  if (!jsonMu) {
    if (kod !== 204 && kod !== 304 && ham && ham.trim() !== '') {
      bul('UYARI', '04-§4', konum, 'yanıt gövdesi JSON olarak ayrıştırılamadı');
    }
    continue;
  }

  // ---- Hata gövdesi [API-13] ----
  if (kod >= 400) {
    const ok = obj && typeof obj === 'object' && obj.error === true && typeof obj.message === 'string';
    if (!ok) bul('ZORUNLU', 'API-13', konum, 'hata gövdesi {"error":true,"message":"..."} biçiminde değil ([04] §4.1)');
    else if (obj.code === undefined) bul('BILGI', 'API-14', konum, 'hata gövdesinde makine-okunur "code" yok (ÖNERİLEN)');
    continue;
  }

  if (kod < 200 || kod >= 300) continue;

  // ---- Başarı zarfı ----
  // [API-16]: liste = data + meta, TEK KAYIT DOĞRUDAN OBJEDİR (sarmalanmaz).
  if (sinif === 'liste') {
    if (Array.isArray(obj)) {
      bul('ZORUNLU', 'API-16', konum, 'liste yanıtı çıplak dizi — {"data":[...],"meta":{...}} olmalı ([04] §4.2)');
    } else if (obj && typeof obj === 'object') {
      if (!('data' in obj)) bul('ZORUNLU', 'API-16', konum, 'liste yanıtında "data" alanı yok ([04] §4.2)');
      const m = obj.meta;
      if (!m || typeof m !== 'object') {
        bul('ZORUNLU', 'API-19', konum, 'liste yanıtında "meta" yok — sayfalamasız liste ucu yasak ([API-19])');
      } else {
        for (const alan of ['page', 'limit']) {
          if (m[alan] === undefined) bul('ZORUNLU', 'API-16', konum, 'meta.' + alan + ' yok ([04] §4.2)');
        }
        if (m.total_items === undefined && m.total === undefined) {
          bul('ZORUNLU', 'API-17', konum, 'meta.total_items yok — filtreli toplam dönmeli ([API-17])');
        }
        if (typeof m.limit === 'number' && m.limit > 200) {
          bul('ZORUNLU', 'API-18', konum, 'meta.limit=' + m.limit + ' — üst sınır 200 ([API-18])');
        }
      }
      if (obj.data && typeof obj.data === 'object' && !Array.isArray(obj.data) && obj.data.data !== undefined) {
        bul('ZORUNLU', 'API-16', konum, 'çift sarmalama (data.data) ([API-16])');
      }
    }
  } else if (sinif === 'saglik') {
    if (!obj || typeof obj !== 'object' || obj.status === undefined) {
      bul('UYARI', 'TEST-04', konum, '/health gövdesinde "status" yok — beklenen {"status":"healthy",...}');
    }
  } else if (sinif === 'tek' || sinif === 'yazma') {
    if (obj && typeof obj === 'object' && !Array.isArray(obj)
        && Object.keys(obj).length === 1 && obj.data !== undefined) {
      bul('UYARI', 'API-16', konum, 'tek kayıt "data" içine sarmalanmış — doğrudan obje dönmeli ([API-16])');
    }
  }
}

// ---- Süre istatistikleri ----
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
    satirlar.push(['T', tsv(g.ad), g.metot, tsv(g.yol), 0, '', '', '', 'yanıtsız', g.sinif, '', ''].join('\t'));
    continue;
  }
  const mn = Math.min(...g.sureler), mx = Math.max(...g.sureler), md = medyan(g.sureler);
  // Gürültü ölçütü: oran TEK BAŞINA yeterli değil. 2ms→9ms de 4,5 kat eder ama
  // bu ölçüm gürültüsüdür, anlamlı bir fark değil. Bu yüzden mutlak fark da aranır.
  if (mn > 0 && mx / mn > 5 && (mx - mn) > 20) gurultulu++;
  const hedef = HEDEF[g.sinif];
  const durum = md < hedef ? 'hedefin altında' : 'HEDEFİ AŞIYOR';
  const fark = genelOrt > 0 ? Math.round(((md - genelOrt) / genelOrt) * 100) : 0;
  satirlar.push(['T', tsv(g.ad), g.metot, tsv(g.yol), n, mn, md, mx,
                 [...g.kodlar].join(','), g.sinif, durum, fark].join('\t'));
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
for (const b of bulgular) out.push(['B', b[0], b[1], tsv(b[2]), tsv(b[3])].join('\t'));
process.stdout.write(out.join('\n') + '\n');
JS_OLCUM

# ============================================================================
#  1 · Statik koleksiyon analizi (servis olmadan çalışır)
# ============================================================================

ANALIZ="$TMP/analiz.tsv"
if ! node "$TMP/analiz.js" "$KOLEKSIYON" "$TMP/ortak.js" > "$ANALIZ" 2>"$TMP/analiz.err"; then
  hata_cik "koleksiyon okunamadı: $(cat "$TMP/analiz.err")"
fi

meta() { awk -F'\t' -v k="$2" '$1=="M" && $2==k {print $3}' "$1" | head -1; }

KOL_AD="$(meta "$ANALIZ" ad)"
TOPLAM_ISTEK="$(meta "$ANALIZ" toplam_istek)"
TOPLAM_ASSERTION="$(meta "$ANALIZ" toplam_assertion)"
ASSERTIONSUZ="$(meta "$ANALIZ" assertionsuz_istek)"
KOL_DUZEY_ASSERTION="$(meta "$ANALIZ" koleksiyon_duzeyi_assertion)"

yaz '%s\n' "koleksiyon-kosum — Postman koleksiyonu koşumu ve inceleme [ARAC-06]"
yaz '%s\n' "koleksiyon: $KOL_AD"
yaz '%s\n' "dosya: $KOLEKSIYON · $TOPLAM_ISTEK istek · $TOPLAM_ASSERTION assertion"

baslik "A · Koleksiyon envanteri ve endpoint sınıflandırması"
yaz '%s%s%s\n' "$DIM" "sınıf sezgiseldir: metot + yol deseninden çıkarılır, gerçek maliyeti bilmez ([ARAC-01])" "$NC"
yaz '\n%-30s %-6s %-38s %-20s %-8s %s\n' "İSTEK" "METOT" "YOL" "SINIF" "HEDEF" "ASSERTION"
while IFS=$'\t' read -r tip ad metot yol own miras sinif; do
  [[ "$tip" == "R" ]] || continue
  sinif_ad="$(awk -F'\t' -v k="$sinif" '$1=="S" && $2==k {print $3}' "$ANALIZ")"
  s_hedef="$(awk -F'\t' -v k="$sinif" '$1=="S" && $2==k {print $4}' "$ANALIZ")"
  tot=$((own + miras))
  if [[ $tot -eq 0 ]]; then
    yaz '%-30.30s %-6s %-38.38s %-20.20s %-8s %syok%s\n' "$ad" "$metot" "$yol" "$sinif_ad" "<${s_hedef}ms" "$RED" "$NC"
  else
    yaz '%-30.30s %-6s %-38.38s %-20.20s %-8s %d%s\n' "$ad" "$metot" "$yol" "$sinif_ad" "<${s_hedef}ms" "$tot" \
        "$([[ $miras -gt 0 ]] && echo " (${miras} miras)" || echo "")"
  fi
done < "$ANALIZ"
yaz '\n%s%s%s\n' "$DIM" "hedefler: tek kayıt <${HEDEF_TEK}ms · liste <${HEDEF_LISTE}ms · yazma <${HEDEF_YAZMA}ms · ağır <${HEDEF_AGIR}ms ([PERF-01])" "$NC"

# ---- Assertion kapısı — yüksek sesle ----
ASSERTION_VAR=1
if [[ "$TOPLAM_ASSERTION" -eq 0 ]]; then
  ASSERTION_VAR=0
  yaz '\n%s%s KOLEKSİYONDA HİÇ ASSERTION YOK %s\n' "$RED$BLD" "▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄" "$NC"
  yaz '%s\n' "  $TOPLAM_ISTEK isteğin hiçbirinde test scripti yok. Bu koleksiyonu koşturmak"
  yaz '%s\n' "  \"200 döndü\" demekten ibarettir; gövdeyi, alanı, sözleşmeyi DOĞRULAMAZ."
  yaz '%s\n' "  Bu bir ÖLÜ ARTEFAKTTIR: bakımı yapılmadan repoda durur ve yanlış güven üretir."
  yaz '%s\n\n' "  Bu koşumun 'başarılı' çıkması hiçbir şeyi kanıtlamaz."
  ihlal ZORUNLU TEST-24 "$KOLEKSIYON" "koleksiyondaki $TOPLAM_ISTEK isteğin hiçbirinde assertion yok — her istek en az bir assertion içermeli"
elif [[ "$ASSERTIONSUZ" -gt 0 ]]; then
  ihlal ZORUNLU TEST-24 "$KOLEKSIYON" "$TOPLAM_ISTEK istekten $ASSERTIONSUZ tanesinde hiç assertion yok ([TEST-24])"
fi
[[ "$KOL_DUZEY_ASSERTION" -gt 0 ]] && \
  yaz '%s%s%s\n' "$DIM" "not: $KOL_DUZEY_ASSERTION assertion koleksiyon düzeyinde tanımlı, tüm isteklere miras kalıyor" "$NC"

# ============================================================================
#  2 · Koşum
# ============================================================================

KOSUM_YAPILDI=0
NEWMAN_RAPOR="$TMP/newman.json"
OLCUM="$TMP/olcum.tsv"; : > "$OLCUM"

if [[ $SADECE_ANALIZ -eq 1 ]]; then
  baslik "B · Koşum"
  yaz '%s\n' "--sadece-analiz verildi: hiçbir istek atılmadı, süre ölçümü yok."
else
  baslik "B · Koşum — newman"

  NEWMAN=""
  if command -v newman >/dev/null 2>&1; then
    NEWMAN="newman"
  elif command -v npx >/dev/null 2>&1; then
    # npx --yes: newman kurulu değilse geçici indirir. Ağ yoksa bu da başarısız olur.
    if npx --yes newman --version >/dev/null 2>&1; then
      NEWMAN="npx --yes newman"
      yaz '%s%s%s\n' "$DIM" "newman kurulu değil, 'npx --yes newman' ile geçici sürüm kullanılıyor (yavaş)" "$NC"
    fi
  fi

  if [[ -z "$NEWMAN" ]]; then
    printf '%sHATA%s  newman bulunamadı ve npx ile de çalıştırılamadı.\n' "$RED" "$NC" >&2
    printf '      Kurulum:  npm install -g newman\n' >&2
    printf '      Tek seferlik:  npx --yes newman run "%s"\n' "$KOLEKSIYON" >&2
    printf '      CI adımı için: [14-GIT-CI.md] pipeline'"'"'ına ekle ([TEST-23]).\n' >&2
    printf '\n      Servis olmadan yalnızca statik inceleme için: --sadece-analiz\n' >&2
    exit 2
  fi

  # -n N: koleksiyonun TAMAMINI N kez koşar.
  # Neden -n ve tek endpointi arka arkaya vurmak DEĞİL:
  #   Aynı ucu peş peşe 3 kez çağırmak ilk isteğin doldurduğu cache'i (Redis, PG
  #   shared_buffers, DNS, TLS oturumu, bağlantı havuzu) ölçer — 2. ve 3. istek
  #   yapay olarak hızlı çıkar. -n ile istekler doğal olarak serpiştirilir
  #   (health, search, stats, sonra tekrar health) ve her tekrar arasına başka
  #   uçların yükü girer. Bu da mükemmel değildir ama peş peşe vuruştan dürüsttür.
  KOMUT=( $NEWMAN run "$KOLEKSIYON" -n "$TEKRAR"
          --reporters cli,json --reporter-json-export "$NEWMAN_RAPOR"
          --timeout-request "$ISTEK_ZAMAN_ASIMI_MS" --suppress-exit-code )
  [[ -n "$ORTAM" ]]     && KOMUT+=( --environment "$ORTAM" )
  [[ -n "$TABAN_URL" ]] && KOMUT+=( --env-var "baseUrl=$TABAN_URL" )

  yaz '%s\n' "koşuluyor: ${TEKRAR}× tam koleksiyon (endpoint başına $TEKRAR örnek, serpiştirilmiş)"
  if [[ $JSON_MOD -eq 1 ]]; then
    "${KOMUT[@]}" >/dev/null 2>&1
  else
    "${KOMUT[@]}"
  fi

  [[ -f "$NEWMAN_RAPOR" ]] || hata_cik "newman rapor üretmedi — koşum başlatılamadı"

  if ! node "$TMP/olcum.js" "$NEWMAN_RAPOR" "$TMP/ortak.js" > "$OLCUM" 2>"$TMP/olcum.err"; then
    hata_cik "newman raporu okunamadı: $(cat "$TMP/olcum.err")"
  fi
  KOSUM_YAPILDI=1
fi

# ============================================================================
#  3 · Doğruluk bulguları + süre tablosu + geçerlilik kapısı
# ============================================================================

GECERSIZ=0
GECERSIZ_NEDEN=()
NEDEN_DOSYA="$TMP/nedenler.txt"; : > "$NEDEN_DOSYA"

if [[ $KOSUM_YAPILDI -eq 1 ]]; then
  YANITSIZ="$(meta "$OLCUM" yanitsiz)"
  TOPLAM_CALISMA="$(meta "$OLCUM" toplam_calisma)"
  ENDPOINT_SAYI="$(meta "$OLCUM" endpoint)"
  GENEL_ORT="$(meta "$OLCUM" genel_ortalama_medyan)"
  GURULTULU="$(meta "$OLCUM" gurultulu_endpoint)"
  AS_TOPLAM="$(meta "$OLCUM" assertion_toplam)"
  AS_BASARISIZ="$(meta "$OLCUM" assertion_basarisiz)"
  ISTEK_BASARISIZ="$(meta "$OLCUM" istek_basarisiz)"

  YANITLI=$(( TOPLAM_CALISMA - YANITSIZ ))
  if [[ "$YANITLI" -eq 0 ]]; then
    printf '%sHATA%s  Hiçbir isteğe yanıt alınamadı (%s çalışmanın tamamı bağlantı hatası).\n' "$RED" "$NC" "$TOPLAM_CALISMA" >&2
    printf '      Hedef ayakta değil ya da baseUrl yanlış.\n' >&2
    printf '      Kontrol:  docker compose ps  ·  curl -i <taban-url>/health\n' >&2
    printf '      Taban URL ver:  --taban-url http://localhost:9000\n' >&2
    printf '      Servis olmadan yalnızca statik inceleme için: --sadece-analiz\n' >&2
    exit 2
  fi

  baslik "C · Yanıt doğruluğu — zarf, durum kodu, Content-Type ([04])"
  BULGU_SAYI=0
  while IFS=$'\t' read -r tip sev id loc msg; do
    [[ "$tip" == "B" ]] || continue
    BULGU_SAYI=$((BULGU_SAYI+1))
    if [[ "$sev" == "BILGI" ]]; then
      yaz '%sBİLGİ%s  [%s] %s\n         %s\n' "$DIM" "$NC" "$id" "$loc" "$msg"
    else
      ihlal "$sev" "$id" "$loc" "$msg"
    fi
  done < "$OLCUM"
  [[ $BULGU_SAYI -eq 0 ]] && yaz '%sBulgu yok%s — yanıtlar standardın zarfına uyuyor görünüyor.\n' "$GRN" "$NC"

  if [[ "$AS_BASARISIZ" -gt 0 ]]; then
    ihlal ZORUNLU TEST-23 "$KOLEKSIYON" "$AS_TOPLAM assertion'dan $AS_BASARISIZ tanesi başarısız — ayrıntı için newman cli çıktısına bak"
  fi
  if [[ "$ISTEK_BASARISIZ" -gt 0 || "$YANITSIZ" -gt 0 ]]; then
    ihlal ZORUNLU TEST-23 "$KOLEKSIYON" "$ISTEK_BASARISIZ istek hatası, $YANITSIZ yanıtsız çalışma"
  fi

  # ---- Geçerlilik kapısı ----
  [[ "$TEKRAR" -lt 2 ]]                  && { GECERSIZ=1; GECERSIZ_NEDEN+=("tekrar sayısı $TEKRAR (<2) — tek örnekten dağılım çıkarılamaz"); }
  [[ "$TOPLAM_ISTEK" -lt $ASGARI_ISTEK ]] && { GECERSIZ=1; GECERSIZ_NEDEN+=("koleksiyonda $TOPLAM_ISTEK istek var (<$ASGARI_ISTEK) — karşılaştırma tabanı yok"); }
  [[ "$ASSERTION_VAR" -eq 0 ]]           && { GECERSIZ=1; GECERSIZ_NEDEN+=("koleksiyonda hiç assertion yok — süreler doğrulanmamış yanıtlara ait ([TEST-24])"); }
  [[ "$YANITLI" -eq 0 ]]                 && { GECERSIZ=1; GECERSIZ_NEDEN+=("hiçbir yanıt alınamadı"); }
  [[ "$GURULTULU" -gt 0 ]]               && { GECERSIZ=1; GECERSIZ_NEDEN+=("$GURULTULU endpoint'te maks/min oranı >$GURULTU_ORANI — ortam gürültülü"); }

  # tüm yanıtlar 4xx/5xx mi?
  BASARILI_YANIT=$(awk -F'\t' '$1=="T" && $9!="yanıtsız" {print $9}' "$OLCUM" | tr ',' '\n' | awk '$1>=200 && $1<400' | wc -l)
  [[ "$BASARILI_YANIT" -eq 0 ]] && { GECERSIZ=1; GECERSIZ_NEDEN+=("hiçbir endpoint 2xx/3xx dönmedi — ölçülen şey hata yolu"); }

  for _n in ${GECERSIZ_NEDEN[@]+"${GECERSIZ_NEDEN[@]}"}; do printf '%s\n' "$_n"; done > "$NEDEN_DOSYA"

  baslik "D · Süre ölçümü — ${TEKRAR} örnek/endpoint"
  if [[ $GECERSIZ -eq 1 ]]; then
    yaz '\n%s%s BU ÖLÇÜM YORUMLANAMAZ %s\n' "$RED$BLD" "▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄" "$NC"
    for n in "${GECERSIZ_NEDEN[@]}"; do yaz '  · %s\n' "$n"; done
    yaz '%s\n' "  Süreler aşağıda ham veri olarak listelenir; PERFORMANS YORUMU YAPILMAZ."
    ihlal ZORUNLU PERF-32 "$KOLEKSIYON" "ölçüm geçerlilik kapısına takıldı — bu koşumdan performans sonucu çıkarılamaz"
  fi

  yaz '\n%-34s %-18s %6s %6s %6s %8s %s\n' "İSTEK" "SINIF" "MIN" "MED" "MAKS" "HEDEF" "DURUM"
  while IFS=$'\t' read -r tip ad metot yol n mn md mx kodlar sinif durum fark; do
    [[ "$tip" == "T" ]] || continue
    hedef="$(awk -F'\t' -v k="$sinif" '$1=="S" && $2==k {print $4}' "$ANALIZ")"
    sinif_ad="$(awk -F'\t' -v k="$sinif" '$1=="S" && $2==k {print $3}' "$ANALIZ")"
    if [[ "$n" -eq 0 ]]; then
      yaz '%-34.34s %-18.18s %s(yanıt yok)%s\n' "$ad" "$sinif_ad" "$RED" "$NC"
      continue
    fi
    if [[ $GECERSIZ -eq 1 ]]; then
      yaz '%-34.34s %-18.18s %6s %6s %6s %8s %s(yorum yok)%s\n' "$ad" "$sinif_ad" "$mn" "$md" "$mx" "<${hedef}ms" "$DIM" "$NC"
    else
      if [[ "$md" -lt "$hedef" ]]; then renk="$GRN"; else renk="$RED"; fi
      if [[ "$fark" -ge 0 ]]; then kiyas="koşum ortalamasının %${fark} ÜSTÜNDE"; else kiyas="koşum ortalamasının %${fark#-} altında"; fi
      yaz '%-34.34s %-18.18s %6s %s%6s%s %6s %8s %s\n' "$ad" "$sinif_ad" "$mn" "$renk" "$md" "$NC" "$mx" "<${hedef}ms" "$kiyas"
      if [[ "$md" -ge "$hedef" ]]; then
        ihlal UYARI PERF-01 "$metot $yol" "medyan ${md}ms, $sinif_ad hedefi <${hedef}ms — ama bu p95 DEĞİLDİR, karar için yük testi gerekir"
      fi
    fi
  done < "$OLCUM"

  yaz '\n%s%s%s\n' "$DIM" "koşumdaki endpoint medyanlarının ortalaması: ${GENEL_ORT}ms" "$NC"
  yaz '\n%s%s%s\n' "$BLD" "── DÜRÜSTLÜK NOTU [PERF-32] ──" "$NC"
  yaz '%s\n' "  Yukarıdaki sayılar p95 DEĞİLDİR ve p95 hesaplanamaz: endpoint başına $TEKRAR örnek var."
  yaz '%s\n' "  [PERF-02] ölçümün p95/p99 üzerinden yapılmasını ZORUNLU kılar; $TEKRAR örnek bunu karşılamaz."
  yaz '%s\n' "  Bu tablo bir KOKU TESTİDİR: 'burada bir şey var mı?' sorusuna bakar, 'SLO tutuyor mu?'"
  yaz '%s\n' "  sorusuna DEĞİL. SLO kararı için yük testi aracı kullanılır ([PERF-33], [PERF-21]: k6/vegeta)."
  yaz '%s\n' "  Ayrıca ölçüm istemci tarafındadır: ağ, gateway ve makinenin o anki yükü sürelerin içindedir."
fi

# ============================================================================
#  4 · Kod analizi — yavaşlığın kaynakta kanıtı
# ============================================================================

kod_bulgu() { ihlal "$1" "$2" "$3" "$4"; }

if [[ -n "$KOD_DIZINI" ]]; then
  baslik "E · Kod analizi — $KOD_DIZINI"
  yaz '%s%s%s\n' "$DIM" "metin deseni tabanlıdır, SEZGİSELDİR ([ARAC-01]); her bulgu dosya:satır kanıtıyla verilir" "$NC"

  # İstek yolundaki kodu ararız: migration ve seed dosyaları bir kez, açılışta koşar;
  # oradaki döngü-içi sorgu ya da COUNT(*) endpoint süresini etkilemez. Bu yüzden
  # performans sezgiselleri onları KAPSAM DIŞI bırakır (yanlış pozitif kaynağıydı).
  mapfile -t KD_GO < <(find "$KOD_DIZINI" -name '*.go' -not -name '*_test.go' \
    -not -path '*/vendor/*' -not -path '*/migration*/*' -not -path '*/seed*/*' 2>/dev/null)
  mapfile -t KD_SQL < <(find "$KOD_DIZINI" -name '*.sql' -not -path '*/vendor/*' 2>/dev/null)
  yaz '%s\n' "$(( ${#KD_GO[@]} )) go · $(( ${#KD_SQL[@]} )) sql dosyası tarandı (migration/seed hariç)"

  if [[ ${#KD_GO[@]} -eq 0 ]]; then
    yaz '%s\n' "Go dosyası yok — kod analizi atlandı."
  else
    tara() { local pat="$1"; shift; grep -nHE "$pat" "$@" 2>/dev/null | grep -vE ':[0-9]+:[[:space:]]*//' || true; }
    # grep çıktısı 'yol:satır:içerik'. Yolda 'C:' gibi sürücü harfi olabildiği için
    # 'cut -d:' YANLIŞ keser; açgözlü .* ile en uzun yol alınır, sonrası satır no'dur.
    konum() { sed -E 's/^(.*):([0-9]+):.*$/\1:\2/'; }

    # --- SELECT * [DB-18] ---
    while IFS= read -r hit; do
      [[ -n "$hit" ]] || continue
      kod_bulgu ZORUNLU DB-18 "$hit" \
        "SELECT * görüldü — gereksiz kolon taşır, index-only scan'i engeller, şema değişince yanıt sessizce şişer. Kolonları açıkça yaz."
    done < <(tara 'SELECT[[:space:]]+\*' "${KD_GO[@]}" | konum)

    # --- ORDER BY tie-break'siz / LIMIT'siz [DB-19] ---
    while IFS= read -r hit; do
      [[ -n "$hit" ]] || continue
      kod_bulgu ZORUNLU DB-19 "$hit" \
        "ORDER BY + LIMIT ama tie-break kolonu yok — eşit değerlerde sıra kararsızdır, sayfalar arası kayıt tekrarlanır/atlanır. '(created_at DESC, id ASC)' gibi bileşik sıra kullan ([DB-26])."
    done < <(tara 'ORDER BY[^,)]*LIMIT' "${KD_GO[@]}" | konum)

    while IFS= read -r hit; do
      [[ -n "$hit" ]] || continue
      echo "$hit" | grep -qiE 'LIMIT' && continue
      # Sorgular parça parça (const + concat) kuruluyorsa LIMIT başka satırdadır.
      # Aynı DOSYADA hiç LIMIT yoksa şüphe gerçektir; varsa susarız — yanlış pozitif
      # üretmektense kaçırmayı seçiyoruz, çünkü gürültü aracın güvenilirliğini yer.
      dosya="$(echo "$hit" | sed -E 's/^(.*):[0-9]+:.*$/\1/')"
      grep -qiE 'LIMIT' "$dosya" 2>/dev/null && continue
      kod_bulgu UYARI DB-19 "$(echo "$hit" | konum)" \
        "ORDER BY var ama dosyada hiç LIMIT yok — tablo büyüdükçe tüm sonuç kümesi sıralanır. Sayfalama ekle ([API-19])."
    done < <(tara 'ORDER BY' "${KD_GO[@]}")

    # --- Döngü içinde sorgu: N+1 şüphesi ---
    # for bloğunun süslü parantez derinliğini sayarak blok içi sorgu arar.
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
        kod_bulgu ZORUNLU PERF-22 "$loc" \
          "döngü içinde veritabanı çağrısı (N+1 şüphesi) — N kayıt N sorgu demektir, ağ gidiş-dönüşü N ile çarpılır. Tek sorguya çevir (JOIN / WHERE id = ANY(\$1)) ([PERF-22] madde 3)."
      done
    done

    # --- COUNT(*) ile sayfalama ---
    while IFS= read -r hit; do
      [[ -n "$hit" ]] || continue
      kod_bulgu UYARI PERF-22 "$hit" \
        "COUNT(*) sayfalama için kullanılıyor — Postgres'te filtreli COUNT tam tarama yapar, tablo büyüdükçe liste ucunun süresini COUNT belirler. Tahmini sayım ya da 'sonraki sayfa var mı' (limit+1) yaklaşımını değerlendir."
    done < <(tara 'COUNT\([*]\)' "${KD_GO[@]}" | konum)

    # --- timeout'suz http.Client [RES-08] ---
    for f in "${KD_GO[@]}"; do
      if grep -qE '(&)?http\.Client\{[[:space:]]*\}' "$f"; then
        loc="$(grep -nE '(&)?http\.Client\{[[:space:]]*\}' "$f" | head -1 | cut -d: -f1)"
        kod_bulgu ZORUNLU RES-08 "$f:$loc" \
          "timeout'suz http.Client — varsayılan SONSUZDUR. Upstream yanıt vermezse goroutine ve bağlantı sızar, yavaşlık bu servise yayılır. Timeout ver ([RES-08])."
      fi
    done

    # --- WHERE kolonunda index görünmüyor [DB-26] ---
    if [[ ${#KD_SQL[@]} -gt 0 ]]; then
      # Operatör AYRI SÖZCÜK olmalı: 'AND ST_Intersects(' içindeki 'st_' + 'IN' eşleşmesi
      # 'st_in' diye sahte bir kolon üretiyordu ([ARAC-02]: kuralı daralt, kapatma).
      mapfile -t WCOL < <(grep -hoiE '(WHERE|AND)[[:space:]]+[a-z_][a-z0-9_]*([[:space:]]*(=|<>|!=|>=|<=|>|<)|[[:space:]]+(LIKE|ILIKE|IN)[[:space:](])' "${KD_GO[@]}" 2>/dev/null \
        | sed -E 's/^(WHERE|AND)[[:space:]]+//I' \
        | sed -E 's/[[:space:]]*(=|<>|!=|>=|<=|>|<).*$//' \
        | sed -E 's/[[:space:]]+(LIKE|ILIKE|IN)[[:space:](].*$//I' \
        | tr 'A-Z' 'a-z' | sort -u | grep -vE '^(id|1|true|false|null|deleted_at|and|or|not)$')
      INDEKS_METNI="$(grep -hiE 'CREATE( UNIQUE)? INDEX|PRIMARY KEY|UNIQUE[[:space:]]*\(' "${KD_SQL[@]}" 2>/dev/null | tr 'A-Z' 'a-z')"
      for c in "${WCOL[@]}"; do
        [[ -n "$c" ]] || continue
        if ! echo "$INDEKS_METNI" | grep -qE "[(,[:space:]]$c([),[:space:]]|$)"; then
          loc="$(grep -nHiE "(WHERE|AND)[[:space:]]+$c([[:space:]]*(=|<>|>=|<=|>|<)|[[:space:]]+(LIKE|ILIKE|IN)[[:space:](])" "${KD_GO[@]}" 2>/dev/null | head -1 | konum)"
          kod_bulgu UYARI DB-26 "${loc:-$KOD_DIZINI}" \
            "'$c' kolonu WHERE'de filtreleniyor ama migration'larda bu kolon için CREATE INDEX görünmüyor — filtre tam tarama yapar. Index ekle ([DB-26]); doğrulama: EXPLAIN (ANALYZE, BUFFERS) ([PERF-18])."
        fi
      done
    else
      yaz '%s%s%s\n' "$DIM" "not: .sql dosyası bulunamadı — index kontrolü yapılamadı (migration'lar başka repoda olabilir)" "$NC"
    fi

    # --- cache adayı [CACHE-02] ---
    if ! grep -rqiE 'redis|valkey|cache' "$KOD_DIZINI" --include='*.go' 2>/dev/null; then
      kod_bulgu UYARI CACHE-02 "$KOD_DIZINI" \
        "serviste redis/valkey/cache izi yok. Okuma ağırlıklı ve seyrek değişen veri servisi ise cache adayıdır ([08], [CACHE-02]). DİKKAT: [CACHE-01] cache'i ÖLÇMEDEN eklemeyi yasaklar — önce yavaşlığı göster."
    fi

    # --- Yavaş endpoint → ilgili dosya işareti ---
    if [[ $KOSUM_YAPILDI -eq 1 && $GECERSIZ -eq 0 ]]; then
      while IFS=$'\t' read -r tip ad metot yol n mn md mx kodlar sinif durum fark; do
        [[ "$tip" == "T" ]] || continue
        [[ "$durum" == "HEDEFİ AŞIYOR" ]] || continue
        son="$(basename "$yol")"
        eslesme="$(grep -rnE "\"/?${son}\"|/${son}\"" "$KOD_DIZINI" --include='*.go' 2>/dev/null | head -3 | konum)"
        if [[ -n "$eslesme" ]]; then
          yaz '\n%sÖNCELİK%s  %s %s (medyan %sms) — kaynakta eşleşen yer:\n' "$YEL" "$NC" "$metot" "$yol" "$md"
          while IFS= read -r e; do yaz '           %s\n' "$e"; done <<< "$eslesme"
        else
          yaz '\n%sÖNCELİK%s  %s %s (medyan %sms) — yol dizgisi kaynakta bulunamadı, handler eşlemesi yapılamadı.\n' "$YEL" "$NC" "$metot" "$yol" "$md"
        fi
      done < "$OLCUM"
    fi
  fi
fi

# ============================================================================
#  5 · Özet
# ============================================================================

if [[ $JSON_MOD -eq 1 ]]; then
  export KK_GECERSIZ="$GECERSIZ" KK_TEKRAR="$TEKRAR"
  node -e '
    const fs = require("fs");
    const [bulgularF, analizF, olcumF, nedenF] = process.argv.slice(1);
    const oku = f => { try { return fs.readFileSync(f, "utf8").split(/\r?\n/).filter(Boolean); } catch (_) { return []; } };
    const meta = (sat, k) => { for (const s of sat) { const p = s.split("\t"); if (p[0] === "M" && p[1] === k) return p[2]; } return null; };
    const analiz = oku(analizF), olcum = oku(olcumF);
    const cikti = {
      arac: "koleksiyon-kosum",
      kural: "ARAC-06",
      koleksiyon: { ad: meta(analiz, "ad"), istek: +meta(analiz, "toplam_istek"),
                    assertion: +meta(analiz, "toplam_assertion"),
                    assertionsuz_istek: +meta(analiz, "assertionsuz_istek") },
      olcum_gecerli: olcum.length === 0 ? null : process.env.KK_GECERSIZ !== "1",
      gecersizlik_nedenleri: oku(nedenF),
      p95_hesaplandi_mi: false,
      slo_karari: null,
      slo_notu: "Bu araç SLO kararı vermez ([PERF-32]). [PERF-02] p95/p99 ister; endpoint başına " +
                (process.env.KK_TEKRAR || "?") + " örnek bunu karşılamaz. Yük testi kullanın ([PERF-33]).",
      endpointler: olcum.filter(s => s.startsWith("T\t")).map(s => {
        const p = s.split("\t");
        return { ad: p[1], metot: p[2], yol: p[3], ornek: +p[4],
                 min_ms: p[5] === "" ? null : +p[5], medyan_ms: p[6] === "" ? null : +p[6],
                 maks_ms: p[7] === "" ? null : +p[7], durum_kodlari: p[8],
                 sinif: p[9], sinif_sezgisel: true, hedefe_gore: p[10] || null };
      }),
      bulgular: oku(bulgularF).map(s => { const p = s.split("\t");
        return { seviye: p[0], kural: p[1], konum: p[2], mesaj: p[3] }; }),
    };
    process.stdout.write(JSON.stringify(cikti, null, 2) + "\n");
  ' "$BULGULAR" "$ANALIZ" "$OLCUM" "$NEDEN_DOSYA"
else
  printf '\n%s\n' "─────────────────────────────────────────────"
  if [[ $HATA -eq 0 && $UYARI -eq 0 ]]; then
    printf '%sTEMİZ%s — koşum başarılı, kontrol edilebilen kurallarda ihlal yok\n' "$GRN" "$NC"
  elif [[ $HATA -eq 0 ]]; then
    printf '%s%d uyarı%s, hata yok\n' "$YEL" "$UYARI" "$NC"
  else
    printf '%s%d HATA%s, %d uyarı\n' "$RED" "$HATA" "$NC" "$UYARI"
  fi
  printf '%sNot: bu araç koleksiyonu koşturur ve süre ölçer; SLO kararı VERMEZ ([PERF-32]).\n' "$DIM"
  printf 'Endpoint sınıfı ve kod bulguları heuristiktir, kanıt değildir ([ARAC-01]).\n'
  printf 'CI adımı olarak eklenmelidir — koşturulmayan koleksiyon ölü artefakttır ([TEST-23]).%s\n' "$NC"
fi

[[ $HATA -gt 0 ]] && exit 1
exit 0
