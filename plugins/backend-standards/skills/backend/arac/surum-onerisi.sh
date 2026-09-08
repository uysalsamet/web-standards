#!/usr/bin/env bash
# =============================================================================
#  surum-onerisi.sh — bağımlılık güncelliği raporu (ÖNERİ; asla FAIL değil)
#
#  Kullanım:
#    ./arac/surum-onerisi.sh [kök-dizin] [seçenekler]
#
#  Seçenekler:
#    --atla-ag        Ağ gerektiren adımı atla; yalnızca go.mod 'go' direktifi
#                     tablosunu üret. (CI'da ağ yoksa veya hızlı bakış için.)
#    --major-tara     Doğrudan bağımlılıklar için bir üst major hattını
#                     (path/vN+1) ayrıca sorgula. Ek ağ maliyeti getirir.
#    --limit <n>      En fazla n modülü sorgula (büyük monorepolarda hız için).
#    --zaman-asimi <sn>  Modül başına sorgu zaman aşımı. Varsayılan 120.
#    --json           Özeti makine okunur JSON olarak da bas.
#
#  ÇIKIŞ KODU: HER ZAMAN 0 — bulgu olsa bile.
#  ------------------------------------------------------------------------
#  Neden her zaman 0:
#  Bu araç "standarda uyulmuş mu" sorusunu YANITLAMAZ. Onu [VER-01] sorar ve
#  standart-kontrol.sh denetler; orada ihlal FAIL'dir ve merge'i durdurur.
#  Buradaki soru bambaşkadır: "upstream'de daha yeni bir sürüm var mı?"
#  Bunun cevabı bizim kontrolümüzde değildir — biz kod yazmasak da bir
#  bağımlılık yarın yeni sürüm çıkarabilir. Böyle bir olaya bağlı FAIL,
#  pipeline'ı bizim yapmadığımız bir değişiklik yüzünden kırar. Kırılan
#  pipeline ise ya baypas edilir ya da kontrol tamamen kapatılır ([CI-20]
#  ile aynı mantık: uzun/gürültülü pipeline atlanmaya başlanır).
#  Ayrıca [VER-03] sürüm yükseltmesini kendi PR'ı yapar; her yeni sürüm
#  otomatik alınmaz. Yükseltme bir KARARDIR, refleks değil.
#  Bu yüzden araç bulgu üretir, karar üretmez: çıkış kodu her zaman 0.
#  ------------------------------------------------------------------------
#
#  Kurallar:
#    [VER-21] ÖNERİLEN — Bağımlılık güncelliği düzenli aralıklarla gözden
#             geçirilir. Bu araç ÖNERİ üretir; pipeline'ı kırmaz.
#             [VER-01]'in yerine geçmez, onunla karıştırılmaz.
#    [ARAC-07] Bu araç.
#    Atıf: [VER-01] go direktifi standarda eşit olmalı (FAIL eden kural,
#          standart-kontrol.sh'nin işi) · [VER-08]/[ADR] her major atlaması
#          tek tek, ilgili ADR okunarak ele alınır · [GEN-03] tabloda
#          olmayan bağımlılık onay gerektirir — yeni sürüm de onay ister.
#
#  DÜRÜSTLÜK NOTU (bkz. arac/README.md "Sınırlar — dürüstlük bölümü"):
#    - Ağ gerektirir. Ağ yoksa yalnızca 'go' direktifi tablosu üretilir ve
#      bu açıkça yazılır; sessizce "temiz" denmez.
#    - `go list -m -u` MAJOR SINIRINI GEÇEMEZ: v2 -> v3 farklı modül yoludur.
#      Bu yüzden major hattı ayrı bir sorguyla (--major-tara) taranır ve
#      taranmadıysa raporda "taranmadı" yazar.
#    - "Yeni sürüm var" bilgisi bir kalite yargısı DEĞİLDİR. Yeni sürüm
#      daha iyi olmayabilir; bakımı durmuş olabilir; kırıcı olabilir.
# =============================================================================
set -uo pipefail

RED=$'\033[0;31m'; YEL=$'\033[0;33m'; GRN=$'\033[0;32m'; DIM=$'\033[2m'; NC=$'\033[0m'
[[ -t 1 ]] || { RED=""; YEL=""; GRN=""; DIM=""; NC=""; }

# standart-kontrol.sh ile aynı biçim; ama burada tek seviye var: ONERI.
# Bilinçli: bu araçta "ZORUNLU" seviyesi YOKTUR, çünkü karar vermez.
ONERI_SAY=0
oneri() {  # oneri <kural-id> <konum> <mesaj>
  printf '%sÖNERİ%s  [%s] %s\n         %s\n' "$YEL" "$NC" "$1" "$2" "$3"
  ONERI_SAY=$((ONERI_SAY+1))
}
baslik() { printf '\n%s── %s %s\n' "$DIM" "$1" "$NC"; }
bilgi()  { printf '%s%s%s\n' "$DIM" "$1" "$NC"; }

# 02-TEKNOLOJI-SURUMLERI.md §1 — [VER-01]
STANDART_GO="1.25.12"

ROOT="."
ATLA_AG=0
MAJOR_TARA=0
LIMIT=0
ZAMAN_ASIMI=120
JSON_CIKTI=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --atla-ag)      ATLA_AG=1; shift ;;
    --major-tara)   MAJOR_TARA=1; shift ;;
    --limit)        LIMIT="${2:-0}"; shift 2 ;;
    --zaman-asimi)  ZAMAN_ASIMI="${2:-120}"; shift 2 ;;
    --json)         JSON_CIKTI=1; shift ;;
    -h|--help)      sed -n '4,20p' "$0" | sed 's/^#\{1,\} \{0,1\}//'; exit 0 ;;
    -*)             printf '%sKULLANIM HATASI%s bilinmeyen seçenek: %s\n' "$RED" "$NC" "$1"; exit 0 ;;
    *)              ROOT="$1"; shift ;;
  esac
done

if [[ ! -d "$ROOT" ]]; then
  printf '%sKULLANIM HATASI%s dizin yok: %s\n' "$RED" "$NC" "$ROOT"
  exit 0   # bu araç hiçbir koşulda pipeline kırmaz
fi

printf '%s\n' "backend-standartlari — bağımlılık güncelliği önerileri [ARAC-07]"
printf '%s\n' "kök: $ROOT · standart go: $STANDART_GO"
bilgi "Bu araç ÖNERİ üretir ve HİÇBİR ZAMAN FAIL vermez ([VER-21])."
bilgi "Standarda uyum denetimi ayrı iştir: [VER-01] · arac/standart-kontrol.sh"

mapfile -t GOMODS < <(find "$ROOT" -name 'go.mod' -not -path '*/vendor/*' 2>/dev/null | sort)
if [[ ${#GOMODS[@]} -eq 0 ]]; then
  printf '\n%sgo.mod bulunamadı — yapacak iş yok.%s\n' "$DIM" "$NC"
  exit 0
fi

# ---------------------------------------------------------------------------
# 1 · go direktifi dağılımı  (ağ GEREKTİRMEZ)
# ---------------------------------------------------------------------------
baslik "1 · go direktifi dağılımı — ${#GOMODS[@]} modül"

TMPD="$(mktemp -d "${TMPDIR:-/tmp}/surum-onerisi-XXXXXX")" || { printf 'geçici dizin açılamadı\n'; exit 0; }
trap 'rm -rf "$TMPD"' EXIT

GO_SATIRLARI="$TMPD/go-direktif.txt"
: > "$GO_SATIRLARI"
for f in "${GOMODS[@]}"; do
  v="$(grep -m1 -E '^go[[:space:]]+[0-9]' "$f" 2>/dev/null | awk '{print $2}')"
  [[ -z "$v" ]] && v="(yok)"
  printf '%s\t%s\n' "$v" "$f" >> "$GO_SATIRLARI"
done

printf '  %-12s %-7s %s\n' "sürüm" "adet" "durum"
printf '  %s\n' "────────────────────────────────────────────────────────"
UYUMSUZ=0
FARKLI_SURUM=0
while IFS=' ' read -r adet ver; do
  [[ -z "$ver" ]] && continue
  FARKLI_SURUM=$((FARKLI_SURUM+1))
  if [[ "$ver" == "$STANDART_GO" ]]; then
    printf '  %-12s %-7s %sstandart%s\n' "$ver" "$adet" "$GRN" "$NC"
  else
    printf '  %-12s %-7s %sstandart %s DEĞİL%s\n' "$ver" "$adet" "$RED" "$STANDART_GO" "$NC"
    UYUMSUZ=$((UYUMSUZ+adet))
  fi
done < <(cut -f1 "$GO_SATIRLARI" | sort | uniq -c | sort -rn | sed 's/^ *//')

if [[ $UYUMSUZ -gt 0 ]]; then
  printf '\n'
  oneri VER-01 "$ROOT" \
    "$UYUMSUZ/${#GOMODS[@]} modülün 'go' direktifi standart $STANDART_GO değil. Bu, bu aracın değil [VER-01]'in konusudur ve orada FAIL'dir: 'bash arac/standart-kontrol.sh $ROOT' koş."
fi
if [[ $FARKLI_SURUM -gt 1 ]]; then
  oneri VER-21 "$ROOT" \
    "Depoda $FARKLI_SURUM farklı 'go' sürümü var. [VER-03] yükseltmeyi TÜM servisler için birlikte ister; sürüm dağılımı tek başına bir tutarlılık borcudur (aynı kod farklı dil sürümünde derleniyor)."
fi
bilgi "  Modül kırılımı: $GO_SATIRLARI (geçici) — ayrıntı için --json"

# ---------------------------------------------------------------------------
# 2 · Upstream sürüm taraması (ağ GEREKTİRİR)
# ---------------------------------------------------------------------------
AG_ATLANDI_NEDEN=""
if [[ $ATLA_AG -eq 1 ]]; then
  AG_ATLANDI_NEDEN="--atla-ag verildi"
elif ! command -v go >/dev/null 2>&1; then
  AG_ATLANDI_NEDEN="'go' komutu PATH'te yok"
fi

GUNCEL_SAY=0
MAJOR_SAY=0
GUNCEL_DOSYA="$TMPD/guncel.txt"
MAJOR_DOSYA="$TMPD/major.txt"
: > "$GUNCEL_DOSYA"
: > "$MAJOR_DOSYA"

if [[ -n "$AG_ATLANDI_NEDEN" ]]; then
  baslik "2 · Upstream sürüm taraması — ATLANDI"
  printf '  %sAtlanma nedeni: %s%s\n' "$YEL" "$AG_ATLANDI_NEDEN" "$NC"
  printf '  Bu adım `go list -m -u all` çalıştırır; bu komut modül proxysine\n'
  printf '  (GOPROXY, varsayılan proxy.golang.org) AĞ üzerinden sorar. Ağ ya da\n'
  printf '  go yoksa "yeni sürüm var mı" sorusu YANITLANAMAZ.\n'
  printf '  %sÖnemli: bu, "bağımlılıklar güncel" anlamına GELMEZ — bilinmiyor demektir.%s\n' "$DIM" "$NC"
  printf '  Ağ olan bir makinede tekrar koş, ya da yerel proxy ver:\n'
  printf '    GOPROXY=https://proxy.golang.org,direct bash arac/surum-onerisi.sh %s\n' "$ROOT"
else
  baslik "2 · Upstream sürüm taraması"
  bilgi "  \`go list -m -u all\` · modül başına zaman aşımı ${ZAMAN_ASIMI}s · GOWORK=off"
  bilgi "  (GOWORK=off: go.work varsa 'all' tüm çalışma alanına yayılır ve modülün"
  bilgi "   kendi bağımlılıkları ayırt edilemez. Her modül tek tek sorgulanır.)"

  ZA_KOMUT=""
  command -v timeout >/dev/null 2>&1 && ZA_KOMUT="timeout $ZAMAN_ASIMI"

  SAYAC=0
  TARANAN=0
  for f in "${GOMODS[@]}"; do
    [[ $LIMIT -gt 0 && $SAYAC -ge $LIMIT ]] && { bilgi "  --limit $LIMIT doldu, kalan modüller sorgulanmadı."; break; }
    SAYAC=$((SAYAC+1)); TARANAN=$SAYAC
    d="$(dirname "$f")"
    ad="$(basename "$d")"
    HAM="$TMPD/ham-$SAYAC.txt"

    # -mod=readonly [VER-04]: bu araç ASLA go.mod/go.sum yazmaz. Salt okuma.
    if ! (cd "$d" && GOWORK=off GOFLAGS=-mod=readonly $ZA_KOMUT \
            go list -m -u -f '{{.Path}}|{{.Version}}|{{if .Update}}{{.Update.Version}}{{end}}|{{.Indirect}}' all) \
            > "$HAM" 2>"$TMPD/err-$SAYAC.txt"; then
      oneri VER-21 "$f" "sorgulanamadı — $(head -3 "$TMPD/err-$SAYAC.txt" | tr '\n' ' ' | cut -c1-180)"
      continue
    fi

    while IFS='|' read -r yol mevcut yeni dolayli; do
      [[ -z "${yeni:-}" ]] && continue
      [[ -z "${mevcut:-}" ]] && continue
      # major/kırıcı atlama mı? Go'da v0.x.y'de MINOR kırıcı sayılır (semver madde 4).
      km="$(printf '%s' "$mevcut" | sed -E 's/^v([0-9]+)\.([0-9]+).*/\1 \2/')"
      ky="$(printf '%s' "$yeni"   | sed -E 's/^v([0-9]+)\.([0-9]+).*/\1 \2/')"
      m_maj="${km%% *}"; m_min="${km##* }"
      y_maj="${ky%% *}"; y_min="${ky##* }"
      kirici=0
      if [[ "$m_maj" != "$y_maj" ]]; then
        kirici=1
      elif [[ "$m_maj" == "0" && "$m_min" != "$y_min" ]]; then
        kirici=1
      fi
      etiket="doğrudan"; [[ "$dolayli" == "true" ]] && etiket="dolaylı"
      if [[ $kirici -eq 1 ]]; then
        printf '%s\t%s\t%s\t%s\t%s\n' "$ad" "$yol" "$mevcut" "$yeni" "$etiket" >> "$MAJOR_DOSYA"
      else
        printf '%s\t%s\t%s\t%s\t%s\n' "$ad" "$yol" "$mevcut" "$yeni" "$etiket" >> "$GUNCEL_DOSYA"
      fi
    done < "$HAM"

    # --major-tara: go list -m -u major sınırını geçemez; bir üst hattı ayrıca sor.
    if [[ $MAJOR_TARA -eq 1 ]]; then
      while IFS='|' read -r yol mevcut _yeni dolayli; do
        [[ "$dolayli" == "true" ]] && continue
        [[ -z "$mevcut" ]] && continue
        maj="$(printf '%s' "$mevcut" | sed -E 's/^v([0-9]+).*/\1/')"
        [[ "$maj" =~ ^[0-9]+$ ]] || continue
        [[ "$maj" -lt 1 ]] && continue
        ust=$((maj+1))
        taban="$(printf '%s' "$yol" | sed -E 's#/v[0-9]+$##')"
        sonuc="$(cd "$d" && GOWORK=off GOFLAGS=-mod=readonly $ZA_KOMUT \
                  go list -m -f '{{.Path}} {{.Version}}' "$taban/v$ust@latest" 2>/dev/null)"
        [[ -n "$sonuc" ]] && printf '%s\t%s\t%s\t%s\t%s\n' \
          "$ad" "$yol" "$mevcut" "$(printf '%s' "$sonuc" | awk '{print $2}') ($taban/v$ust)" "doğrudan/major-hat" >> "$MAJOR_DOSYA"
      done < "$HAM"
    fi
  done

  # -- güvenli güncellemeler
  if [[ -s "$GUNCEL_DOSYA" ]]; then
    GUNCEL_SAY="$(sort -u "$GUNCEL_DOSYA" | wc -l | tr -d ' ')"
    printf '\n  %sAynı major içinde yeni sürüm (%s benzersiz kayıt)%s\n' "$DIM" "$GUNCEL_SAY" "$NC"
    printf '  %-24s %-46s %-14s %-14s %s\n' "servis" "modül" "mevcut" "yeni" "tür"
    sort -u "$GUNCEL_DOSYA" | awk -F'\t' '{printf "  %-24s %-46s %-14s %-14s %s\n", $1, $2, $3, $4, $5}'
    oneri VER-21 "$ROOT" \
      "Aynı major içinde $GUNCEL_SAY güncelleme mevcut. Bunlar semver'e göre geriye uyumlu OLMALI; yine de [VER-03] gereği ayrı bir yükseltme PR'ında ve tüm servisler için birlikte alınır. Zorunlu değildir."
  else
    [[ -n "$AG_ATLANDI_NEDEN" ]] || printf '\n  %sAynı major içinde güncelleme yok.%s\n' "$GRN" "$NC"
  fi

  # -- kırıcı olabilecekler
  if [[ -s "$MAJOR_DOSYA" ]]; then
    MAJOR_SAY="$(sort -u "$MAJOR_DOSYA" | wc -l | tr -d ' ')"
    printf '\n  %sKIRICI OLABİLEN atlama (%s benzersiz kayıt) — major değişimi veya v0.x minor%s\n' "$YEL" "$MAJOR_SAY" "$NC"
    printf '  %-24s %-46s %-14s %-14s %s\n' "servis" "modül" "mevcut" "yeni" "tür"
    sort -u "$MAJOR_DOSYA" | awk -F'\t' '{printf "  %-24s %-46s %-14s %-14s %s\n", $1, $2, $3, $4, $5}'
    oneri VER-08 "$ROOT" \
      "$MAJOR_SAY kırıcı olabilen atlama var. Bunlar TEK TEK ele alınır: ilgili adr/ kaydı okunur, değişiklik günlüğü incelenir, her biri kendi PR'ı olur. Toplu 'go get -u' ile alınmaz."
    bilgi "  Not: v0.x hattında MINOR artışı da kırıcı sayılır (semver §4: v0 için API kararlılığı taahhüdü yoktur)."
  fi

  if [[ $MAJOR_TARA -eq 0 ]]; then
    bilgi "  Major HAT taraması yapılmadı (--major-tara ile açılır). \`go list -m -u\`"
    bilgi "  major sınırını geçemez: v2 -> v3 farklı modül yoludur, ayrı sorgu gerekir."
  fi
fi

# ---------------------------------------------------------------------------
# 3 · Özet
# ---------------------------------------------------------------------------
printf '\n%s\n' "─────────────────────────────────────────────"
printf '%s modül (%s tarandı) · %s standart dışı go direktifi · %s güncelleme · %s kırıcı olabilen atlama\n' \
  "${#GOMODS[@]}" "${TARANAN:-0}" "$UYUMSUZ" "${GUNCEL_SAY:-0}" "${MAJOR_SAY:-0}"
if [[ -n "$AG_ATLANDI_NEDEN" ]]; then
  printf '%sUpstream taraması ATLANDI (%s) — "güncel" değil, "bilinmiyor".%s\n' "$YEL" "$AG_ATLANDI_NEDEN" "$NC"
fi
printf '%s%d öneri.%s Hiçbiri FAIL değildir ([VER-21]); çıkış kodu 0.\n' "$YEL" "$ONERI_SAY" "$NC"
printf '%sStandarda UYUM denetimi bu araçta değil, [VER-01] altında ve FAIL üretir:\n' "$DIM"
printf '  bash arac/standart-kontrol.sh %s\n' "$ROOT"
printf 'Yeni sürüm ≠ daha iyi sürüm. Yükseltme [VER-03] gereği kendi PR-i olur ve\n'
printf '[GEN-03] gereği tabloya işlenir; refleksle alınmaz.%s\n' "$NC"

if [[ $JSON_CIKTI -eq 1 ]]; then
  printf '{"kural":"VER-21","arac":"ARAC-07","cikis_kodu":0,'
  printf '"modul":%d,"standart_go":"%s","standart_disi_modul":%d,' \
    "${#GOMODS[@]}" "$STANDART_GO" "$UYUMSUZ"
  printf '"go_direktif_dagilimi":['
  ilk=1
  while IFS=' ' read -r adet ver; do
    [[ -z "$ver" ]] && continue
    [[ $ilk -eq 0 ]] && printf ','
    printf '{"surum":"%s","adet":%s,"standart":%s}' "$ver" "$adet" \
      "$([[ "$ver" == "$STANDART_GO" ]] && echo true || echo false)"
    ilk=0
  done < <(cut -f1 "$GO_SATIRLARI" | sort | uniq -c | sort -rn | sed 's/^ *//')
  printf '],"ag_atlandi":%s,"ag_atlanma_nedeni":"%s",' \
    "$([[ -n "$AG_ATLANDI_NEDEN" ]] && echo true || echo false)" "$AG_ATLANDI_NEDEN"
  printf '"guncelleme":%s,"kirici_atlama":%s,"oneri":%d}\n' \
    "${GUNCEL_SAY:-0}" "${MAJOR_SAY:-0}" "$ONERI_SAY"
fi

# [VER-21] gereği: bulgu olsa da olmasa da 0. Gerekçe dosya başındaki blokta.
exit 0
