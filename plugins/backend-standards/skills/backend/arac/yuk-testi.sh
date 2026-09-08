#!/usr/bin/env bash
# =============================================================================
#  yuk-testi.sh — k6 yük testini standardın kendi hedefleriyle karşılaştırır
#
#  Kullanım:
#    ./arac/yuk-testi.sh <hedef-url> [seçenekler]
#
#  Seçenekler:
#    --senaryo <k6.js>       Kendi k6 senaryon. Verilmezse basit bir GET senaryosu
#                            geçici dosyaya üretilir ve koşum sonunda silinir.
#    --sure <30s>            Test süresi (10s, 1m, 2m30s...). Varsayılan 30s.
#    --vu <10>               Eşzamanlı sanal kullanıcı. Varsayılan 10.
#    --sinif <tek|liste|yazma|agir>
#                            Hangi [PERF-01] hedefiyle karşılaştırılacak.
#                            Varsayılan: liste.
#    --kaydet <dosya>        k6 özetinin kopyası buraya yazılır. VARSAYILAN: KAPALI.
#                            Bir denetim aracı, istenmeden çalışma dizinine dosya
#                            bırakmaz: bırakırsa `git add .` ile commit'e girer.
#                            Karşılaştırma yapacaksan yolu açıkça ver.
#    --karsilastir <dosya>   Önceki koşumun özet JSON'u ile fark tablosu bas.
#    --ozet <dosya>          k6 KOŞMA, verilen özet JSON'unu değerlendir.
#                            (Aracın kendi testi ve arşiv yeniden yorumlaması için.)
#    --json                  Sonucu makine okunur JSON olarak da bas.
#
#  Çıkış kodu:
#    0 = [PERF-01] hedefleri karşılandı
#    1 = hedef aşıldı
#    2 = k6 yok / ölçüm yorumlanamaz / kullanım hatası
#
#  Kurallar:
#    [PERF-33] Yük testi sonucu [PERF-01] hedefleriyle karşılaştırılır; "hızlı
#              görünüyor" değerlendirmesi yapılmaz.
#    [PERF-34] Ölçüm geçerlilik kapısı: geçersiz ölçümden geçti/kaldı kararı
#              ÜRETİLMEZ. Yorumlanamayan ölçüm, ölçüm yapılmamış sayılır.
#    [ARAC-08] Bu araç.
#    Atıf: [PERF-01] hedef tablosu · [PERF-02] karar p95/p99 üzerinden ·
#          [PERF-21] yük testi olmadan kapasite iddiası yok.
#
#  DÜRÜSTLÜK NOTU (bkz. arac/README.md "Sınırlar — dürüstlük bölümü"):
#    Yük testi ölçümü ORTAMA bağlıdır. Aynı kod; farklı makinede, farklı ağda,
#    farklı veri hacminde farklı sayı verir. Buradaki mutlak sayılar bir kalite
#    kanıtı DEĞİLDİR; asıl anlamlı olan aynı ortamda önceki koşumla FARKtır
#    (--karsilastir). Tek koşuma bakıp "servis şu kadar isteği kaldırır" denmez.
# =============================================================================
set -uo pipefail

RED=$'\033[0;31m'; YEL=$'\033[0;33m'; GRN=$'\033[0;32m'; DIM=$'\033[2m'; NC=$'\033[0m'
[[ -t 1 ]] || { RED=""; YEL=""; GRN=""; DIM=""; NC=""; }

# standart-kontrol.sh ile aynı biçim: seviye · kural-id · konum · mesaj
HATA=0
UYARI=0
ihlal() {
  local sev="$1" id="$2" loc="$3" msg="$4"
  if [[ "$sev" == "ZORUNLU" ]]; then
    printf '%sHATA%s   [%s] %s\n         %s\n' "$RED" "$NC" "$id" "$loc" "$msg"
    HATA=$((HATA+1))
  else
    printf '%sUYARI%s  [%s] %s\n         %s\n' "$YEL" "$NC" "$id" "$loc" "$msg"
    UYARI=$((UYARI+1))
  fi
}
baslik() { printf '\n%s── %s %s\n' "$DIM" "$1" "$NC"; }
bilgi()  { printf '%s%s%s\n' "$DIM" "$1" "$NC"; }

kullanim() {
  sed -n '4,25p' "$0" | sed 's/^#\{1,\} \{0,1\}//'
  exit 2
}

# ---------------------------------------------------------------------------
# Argümanlar
# ---------------------------------------------------------------------------
HEDEF=""
SENARYO=""
SURE="30s"
VU="10"
SINIF=""
# Varsayılan boş: araç kendiliğinden hiçbir yere dosya yazmaz. Karşılaştırma
# arşivi isteyen --kaydet ile yolunu kendisi belirtir ([ARAC-08]).
KAYDET=""
KARSILASTIR=""
DIS_OZET=""
JSON_CIKTI=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --senaryo)      SENARYO="${2:-}"; shift 2 ;;
    --sure)         SURE="${2:-}"; shift 2 ;;
    --vu)           VU="${2:-}"; shift 2 ;;
    --sinif)        SINIF="${2:-}"; shift 2 ;;
    --kaydet)       KAYDET="${2:-}"; shift 2 ;;
    --karsilastir)  KARSILASTIR="${2:-}"; shift 2 ;;
    --ozet)         DIS_OZET="${2:-}"; shift 2 ;;
    --json)         JSON_CIKTI=1; shift ;;
    -h|--help)      kullanim ;;
    -*)             printf '%sKULLANIM HATASI%s bilinmeyen seçenek: %s\n\n' "$RED" "$NC" "$1"; kullanim ;;
    *)              if [[ -z "$HEDEF" ]]; then HEDEF="$1"; else
                      printf '%sKULLANIM HATASI%s fazladan argüman: %s\n\n' "$RED" "$NC" "$1"; kullanim
                    fi; shift ;;
  esac
done

if [[ -z "$HEDEF" && -z "$DIS_OZET" ]]; then
  printf '%sKULLANIM HATASI%s hedef URL verilmedi.\n\n' "$RED" "$NC"
  kullanim
fi

if [[ -z "$SINIF" ]]; then
  SINIF="liste"
  SINIF_VARSAYILAN=1
else
  SINIF_VARSAYILAN=0
fi

# [PERF-01] hedef tablosu — ms cinsinden p95 tavanı
case "$SINIF" in
  tek)   HEDEF_P95=100;  SINIF_AD="tek kayıt okuma" ;;
  liste) HEDEF_P95=200;  SINIF_AD="liste / sayfa" ;;
  yazma) HEDEF_P95=300;  SINIF_AD="yazma" ;;
  agir)  HEDEF_P95=3000; SINIF_AD="ağır rapor / export" ;;
  *) printf '%sKULLANIM HATASI%s --sinif geçersiz: "%s" (tek|liste|yazma|agir)\n' "$RED" "$NC" "$SINIF"; exit 2 ;;
esac
HEDEF_HATA_ORANI=0.001   # [PERF-01] 5xx oranı < %0,1

# ---------------------------------------------------------------------------
# Yardımcılar
# ---------------------------------------------------------------------------

# "1h2m30s" / "45s" / "2m" -> saniye. Anlaşılamazsa boş döner.
sure_saniye() {
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

# metrik <ozet.json> <metrik-adi> <alan>
# k6 --summary-export çıktısında metrics.<ad>.<alan> sayısını okur.
# jq/python bağımlılığı YOK ([VER-07] ruhu): metrik nesneleri düzdür (iç içe
# nesne içermez), bu yüzden "ad" -> ilk "{" -> ilk "}" aralığında literal alan
# araması yeterlidir. Alan adları parantez içerir ("p(95)"), bu yüzden regex
# değil index() kullanılır.
metrik() {
  local dosya="$1" m="$2" f="$3"
  [[ -f "$dosya" ]] || return 0
  tr -d '\n\r' < "$dosya" | awk -v M="$m" -v F="$f" '
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

# nb <deger> [ondalik] — boşsa "—" basar, sayıysa biçimler
nb() { awk -v v="${1:-}" -v d="${2:-2}" 'BEGIN{ if(v==""){print "—"} else printf "%."d"f", v }'; }

# kiyas <a> <op> <b> -> 0 doğru, 1 yanlış. Boş değer DAİMA yanlış (eksik veriden karar çıkmaz).
kiyas() {
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
temizle() {
  local f
  for f in ${TEMIZLE[@]+"${TEMIZLE[@]}"}; do
    [[ -n "$f" && -f "$f" ]] && rm -f "$f"
  done
}
trap temizle EXIT

printf '%s\n' "backend-standartlari — yük testi değerlendirmesi [ARAC-08]"

# ---------------------------------------------------------------------------
# 1 · Ölçümü elde et
# ---------------------------------------------------------------------------
OZET=""
SURE_SN=""

if [[ -n "$DIS_OZET" ]]; then
  if [[ ! -f "$DIS_OZET" ]]; then
    printf '%sHATA%s   [ARAC-08] özet dosyası yok: %s\n' "$RED" "$NC" "$DIS_OZET"
    exit 2
  fi
  OZET="$DIS_OZET"
  bilgi "dış özet değerlendiriliyor: $DIS_OZET (k6 koşulmadı)"
else
  if ! command -v k6 >/dev/null 2>&1; then
    printf '\n%sHATA%s   [ARAC-08] k6 kurulu değil — ölçüm yapılamıyor.\n' "$RED" "$NC"
    printf '         [PERF-21] yük testi olmadan "şu kadar isteği kaldırır" denmez.\n'
    printf '         Bu araç tahmin üretmez; ölçüm ister.\n'
    printf '\n         Kurulum:\n'
    printf '           macOS         : brew install k6\n'
    printf '           Debian/Ubuntu : https://grafana.com/docs/k6/latest/set-up/install-k6/\n'
    printf '                           (apt deposu + anahtar adımları orada)\n'
    printf '           Windows       : winget install k6 --source winget\n'
    printf '           Go ile        : go install go.k6.io/k6@latest\n'
    printf '           Docker        : docker run --rm -i grafana/k6 run - < senaryo.js\n'
    printf '\n         Elinde hazır bir k6 özeti varsa k6 olmadan değerlendirebilirsin:\n'
    printf '           bash arac/yuk-testi.sh --ozet <ozet.json> --sinif liste\n'
    exit 2
  fi

  SURE_SN="$(sure_saniye "$SURE")"
  if [[ -z "$SURE_SN" ]]; then
    printf '%sKULLANIM HATASI%s --sure çözümlenemedi: "%s" (örn: 30s, 2m, 1m30s)\n' "$RED" "$NC" "$SURE"
    exit 2
  fi
  if ! [[ "$VU" =~ ^[0-9]+$ ]] || [[ "$VU" -lt 1 ]]; then
    printf '%sKULLANIM HATASI%s --vu pozitif tam sayı olmalı: "%s"\n' "$RED" "$NC" "$VU"
    exit 2
  fi
  if [[ -n "$SENARYO" && ! -f "$SENARYO" ]]; then
    printf '%sKULLANIM HATASI%s senaryo dosyası yok: %s\n' "$RED" "$NC" "$SENARYO"
    exit 2
  fi

  if [[ -z "$SENARYO" ]]; then
    SENARYO="$(mktemp "${TMPDIR:-/tmp}/yuk-testi-XXXXXX.js")" \
      || { printf '%sHATA%s geçici dosya açılamadı\n' "$RED" "$NC"; exit 2; }
    TEMIZLE+=("$SENARYO")
    cat > "$SENARYO" <<'K6_SENARYO'
// yuk-testi.sh tarafından üretilen varsayılan senaryo — koşum sonunda silinir.
// Bilinçli olarak SADE: sabit VU, tek endpoint GET.
// Eşik (threshold) TANIMLANMAZ; geçti/kaldı kararını [PERF-01] hedefleriyle
// yuk-testi.sh verir. Karar mantığı iki ayrı yerde durmamalıdır.
import http from 'k6/http';
import { check } from 'k6';

export const options = {
  vus: Number(__ENV.YT_VU),
  duration: __ENV.YT_SURE,
  discardResponseBodies: false,
};

export default function () {
  const res = http.get(__ENV.YT_HEDEF);
  check(res, { 'yanit 4xx/5xx degil': (r) => r.status > 0 && r.status < 400 });
}
K6_SENARYO
  fi

  OZET="$(mktemp "${TMPDIR:-/tmp}/yuk-ozet-XXXXXX.json")" \
    || { printf '%sHATA%s geçici dosya açılamadı\n' "$RED" "$NC"; exit 2; }
  TEMIZLE+=("$OZET")

  bilgi "hedef: $HEDEF · süre: $SURE ($SURE_SN sn) · VU: $VU · sınıf: $SINIF"
  baslik "k6 koşuyor"
  k6 run \
    --vus "$VU" --duration "$SURE" \
    --summary-export "$OZET" \
    --summary-trend-stats "min,med,avg,p(95),p(99),max" \
    -e "YT_HEDEF=$HEDEF" -e "YT_VU=$VU" -e "YT_SURE=$SURE" \
    "$SENARYO"
  K6_KOD=$?

  if [[ ! -s "$OZET" ]]; then
    printf '\n%sHATA%s   [ARAC-08] k6 özet dosyası üretmedi (k6 çıkış kodu %s).\n' "$RED" "$NC" "$K6_KOD"
    printf '         --summary-export bazı k6 sürümlerinde kaldırıldı. Senaryona\n'
    printf '         handleSummary() ekleyip özeti kendin yaz, sonra:\n'
    printf '           bash arac/yuk-testi.sh --ozet <ozet.json> --sinif %s\n' "$SINIF"
    exit 2
  fi
fi

# ---------------------------------------------------------------------------
# 2 · Metrikleri çıkar
# ---------------------------------------------------------------------------
P50="$(metrik "$OZET" http_req_duration 'med')"
P95="$(metrik "$OZET" http_req_duration 'p(95)')"
P99="$(metrik "$OZET" http_req_duration 'p(99)')"
ORT="$(metrik "$OZET" http_req_duration 'avg')"
MIN="$(metrik "$OZET" http_req_duration 'min')"
MAX="$(metrik "$OZET" http_req_duration 'max')"
ISTEK="$(metrik "$OZET" http_reqs 'count')"
HIZ="$(metrik "$OZET" http_reqs 'rate')"
HATA_ORANI="$(metrik "$OZET" http_req_failed 'value')"
HATA_SAYI="$(metrik "$OZET" http_req_failed 'passes')"

if [[ -z "$P95" || -z "$ISTEK" ]]; then
  printf '\n%sHATA%s   [ARAC-08] özet JSON çözümlenemedi: %s\n' "$RED" "$NC" "$OZET"
  printf '         Beklenen yapı: metrics.http_req_duration.{min,med,avg,p(95),p(99),max}\n'
  printf '         ve metrics.http_reqs.count · metrics.http_req_failed.value\n'
  printf '         k6, --summary-trend-stats "min,med,avg,p(95),p(99),max" ile koşulmuş olmalı.\n'
  exit 2
fi
[[ -z "$HATA_ORANI" ]] && HATA_ORANI=0

# Dış özet verildiyse test süresi bilinmiyor; istek sayısı / istek hızından türet.
if [[ -z "$SURE_SN" ]]; then
  SURE_SN="$(awk -v c="${ISTEK:-0}" -v r="${HIZ:-0}" 'BEGIN{ if(r>0) printf "%.0f", c/r; else print "" }')"
fi

baslik "Ölçüm"
printf '  istek           : %s\n' "$(nb "$ISTEK" 0)"
printf '  süre (sn)       : %s\n' "${SURE_SN:-—}"
printf '  hata oranı      : %%%s  (%s başarısız istek)\n' \
  "$(awk -v v="$HATA_ORANI" 'BEGIN{printf "%.3f", v*100}')" "$(nb "${HATA_SAYI:-}" 0)"
printf '  min / p50       : %s ms / %s ms\n' "$(nb "$MIN")" "$(nb "$P50")"
printf '  p95 / p99 / max : %s ms / %s ms / %s ms\n' "$(nb "$P95")" "$(nb "$P99")" "$(nb "$MAX")"
printf '  ortalama        : %s ms %s(karar bu sayıya göre VERİLMEZ — [PERF-02])%s\n' \
  "$(nb "$ORT")" "$DIM" "$NC"

# ---------------------------------------------------------------------------
# 3 · [PERF-34] Ölçüm geçerlilik kapısı
#
#      Bir ölçümün "geçti" demesi, ancak ölçümün kendisi geçerliyse anlamlıdır.
#      Geçersiz ölçümden karar üretmek, hiç ölçmemekten daha tehlikelidir:
#      hiç ölçmeyen bilmediğini bilir, geçersiz ölçen yanlış bildiğini bilmez.
# ---------------------------------------------------------------------------
baslik "Ölçüm geçerlilik kapısı [PERF-34]"
GECERSIZ=0
kapi() {  # kapi <ne-oldu> <neden-yorumlanamaz> <ne-yapmali>
  printf '%sGEÇERSİZ%s [PERF-34] %s\n' "$RED" "$NC" "$1"
  printf '         neden : %s\n' "$2"
  printf '         yap   : %s\n' "$3"
  GECERSIZ=$((GECERSIZ+1))
}

# 3.1 örneklem yetersiz
if kiyas "$ISTEK" "<" 100; then
  kapi "toplam istek $(nb "$ISTEK" 0) — 100'den az" \
       "p95, örneklemin en yavaş %5'idir. 100 isteğin altında bu dilime 5'ten az yanıt düşer; tek bir yavaş istek p95'i tek başına belirler. Çıkan sayı istatistik değil, gürültüdür." \
       "--sure ve/veya --vu artır; en az 100, tercihen 1000+ istek topla."
fi

# 3.2 ısınma baskın
if [[ -n "$SURE_SN" ]] && kiyas "$SURE_SN" "<" 10; then
  kapi "süre $SURE_SN sn — 10 saniyeden kısa" \
       "İlk saniyeler ısınmadır: bağlantı havuzu boş, DNS çözülmemiş, cache soğuk, GC/allocator ısınmamış. Kısa testte ölçülen şey servisin rejim hâli değil, ısınma maliyetidir." \
       "--sure en az 30s ver. Isınma ağırsa senaryoya ayrı bir warm-up aşaması ekleyip onu ölçümün dışında tut."
fi

# 3.3 ölçülen şey hata yolu
if kiyas "$HATA_ORANI" ">" 0.50; then
  kapi "hata oranı %$(awk -v v="$HATA_ORANI" 'BEGIN{printf "%.1f", v*100}') — %50'den yüksek" \
       "İsteklerin yarısından fazlası başarısız. Ölçülen süre iş yolunun değil HATA yolunun süresidir; hata yolu genelde çok daha kısadır ve p95'i yapay olarak İYİ gösterir." \
       "Önce hatayı çöz (yanlış URL/port, kapalı servis, eksik auth, rate limit, TLS). Yük testi çalışan servise yapılır."
fi

# 3.4 kuyruk gövdeden kopuk
if [[ -n "$P50" ]] && kiyas "$P50" ">" 0; then
  ORAN="$(awk -v a="$P95" -v b="$P50" 'BEGIN{printf "%.1f", a/b}')"
  if kiyas "$ORAN" ">" 10; then
    kapi "p95/p50 = ${ORAN}× — 10'dan büyük" \
         "Kuyruk gövdeden 10 kat uzun. Bu ya ortam gürültüsüdür (paylaşımlı CPU, yanda koşan build, VPN, dizüstü termal kısma) ya da kuyruk doygunluğudur (bağlantı havuzu/worker tükendi, istekler bekliyor). İki durumda da p95 servisin gecikmesini değil, beklemeyi ölçer." \
         "Ölçümü sessiz bir makinede tekrarla. Tekrar çıkıyorsa doygunluk gerçektir: VU'yu kademeli düşürüp doygunluk eğrisini çıkar ve [PERF-18] profil sırasını uygula."
  fi
fi

# 3.5 dağılım yok — şüpheli
if [[ -n "$MIN" && -n "$MAX" ]] && kiyas "$ISTEK" ">" 1; then
  FARK="$(awk -v a="$MAX" -v b="$MIN" 'BEGIN{printf "%.6f", a-b}')"
  if kiyas "$FARK" "<" 0.5; then
    kapi "tüm yanıtlar aynı süreyi verdi (min $(nb "$MIN" 3) ms ≈ max $(nb "$MAX" 3) ms)" \
         "Gerçek bir servis; ağ, planlayıcı ve GC nedeniyle asla tek tip süre üretmez. Bu dağılım ya tam cache isabetini, ya sabit bir mock/stub yanıtı, ya da isteğin servise hiç ulaşmadığını (gateway/proxy kısa devre, 304, statik dosya) gösterir." \
         "Yanıt gövdesini ve durum kodunu doğrula; cache'i devre dışı bırak veya cache-busting parametresi ekle. Ölçtüğün şeyin ölçmek istediğin şey olduğunu kanıtla."
  fi
fi

# 3.6 istemci kendi ölçümünü bozuyor
if [[ -n "$HEDEF" ]] \
   && [[ "$HEDEF" == *localhost* || "$HEDEF" == *127.0.0.1* || "$HEDEF" == *"::1"* ]] \
   && [[ "$VU" =~ ^[0-9]+$ ]] && [[ "$VU" -gt 50 ]]; then
  kapi "hedef localhost ve VU=$VU — 50'den fazla" \
       "Yük üreteci ile servis aynı makinede aynı CPU için yarışıyor. Bu VU seviyesinde ölçülen gecikmenin bir bölümü k6'nın kendi doygunluğudur: fatura servise kesilir, suçlu istemcidir." \
       "Yük üretecini ayrı bir makineye taşı; localhost'ta kalacaksan VU'yu 50 ve altında tut."
fi

if [[ $GECERSIZ -eq 0 ]]; then
  printf '%sGEÇTİ%s  altı kapı da temiz — ölçüm yorumlanabilir\n' "$GRN" "$NC"
fi

# ---------------------------------------------------------------------------
# 4 · Karşılaştırma — aynı ortamda önceki koşum
# ---------------------------------------------------------------------------
if [[ -n "$KARSILASTIR" ]]; then
  baslik "Önceki koşumla fark"
  if [[ ! -f "$KARSILASTIR" ]]; then
    ihlal UYARI ARAC-08 "$KARSILASTIR" "karşılaştırma dosyası yok — fark hesaplanamadı"
  else
    O_P95="$(metrik "$KARSILASTIR" http_req_duration 'p(95)')"
    O_P99="$(metrik "$KARSILASTIR" http_req_duration 'p(99)')"
    O_HATA="$(metrik "$KARSILASTIR" http_req_failed 'value')"
    O_ISTEK="$(metrik "$KARSILASTIR" http_reqs 'count')"
    if [[ -z "$O_P95" ]]; then
      ihlal UYARI ARAC-08 "$KARSILASTIR" "önceki özet çözümlenemedi — k6 summary-export biçimi bekleniyor"
    else
      fark() {  # fark <yeni> <eski> <ad> <birim>
        awk -v y="${1:-}" -v e="${2:-}" -v ad="$3" -v br="$4" 'BEGIN{
          if(e==""||y==""){ printf "  %-10s: —\n", ad; exit }
          d=y-e; p=(e!=0)? d/e*100 : 0;
          printf "  %-10s: %.2f%s -> %.2f%s   (%+.2f%s, %%%+.1f)\n", ad, e, br, y, br, d, br, p
        }'
      }
      fark "$P95" "$O_P95" "p95" " ms"
      fark "$P99" "$O_P99" "p99" " ms"
      fark "$(awk -v v="$HATA_ORANI" 'BEGIN{printf "%.4f", v*100}')" \
           "$(awk -v v="${O_HATA:-0}" 'BEGIN{printf "%.4f", v*100}')" "hata" " %"
      fark "$ISTEK" "$O_ISTEK" "istek" ""
      bilgi "  Fark yalnızca AYNI ortam, AYNI veri hacmi ve AYNI senaryo için anlamlıdır."
    fi
  fi
fi

# ---------------------------------------------------------------------------
# 5 · Karar
# ---------------------------------------------------------------------------
baslik "Karar — [PERF-01] hedefleri"
[[ $SINIF_VARSAYILAN -eq 1 ]] && bilgi "  --sinif verilmedi; varsayılan 'liste' kullanıldı."
printf '  sınıf: %s · hedef p95 < %s ms · hedef 5xx oranı < %%0,1\n' "$SINIF_AD" "$HEDEF_P95"

SONUC="belirsiz"
if [[ $GECERSIZ -gt 0 ]]; then
  printf '\n%sBU ÖLÇÜM YORUMLANAMAZ%s — %d geçerlilik kapısı düştü.\n' "$RED" "$NC" "$GECERSIZ"
  printf '[PERF-34] Geçersiz ölçümden geçti/kaldı kararı ÜRETİLMEZ. Yukarıdaki "yap"\n'
  printf 'maddelerini uygulayıp testi tekrarla. Bu koşum ölçüm yapılmamış sayılır;\n'
  printf '[PERF-21] gereği bu sonuca dayanarak kapasite iddiasında bulunma.\n'
  SONUC="yorumlanamaz"
else
  if kiyas "$P95" ">" "$HEDEF_P95"; then
    ihlal ZORUNLU PERF-33 "${HEDEF:-$OZET}" \
      "p95 $(nb "$P95") ms — '$SINIF_AD' hedefi $HEDEF_P95 ms; $(awk -v a="$P95" -v b="$HEDEF_P95" 'BEGIN{printf "%.0f ms aşıldı (%.1f kat)", a-b, a/b}') ([PERF-01])"
  fi
  if [[ -n "$P99" ]] && kiyas "$P99" ">" "$(awk -v h="$HEDEF_P95" 'BEGIN{print h*2}')"; then
    ihlal UYARI PERF-33 "${HEDEF:-$OZET}" \
      "p99 $(nb "$P99") ms — p95 hedefinin iki katından fazla; kuyruk uzun, [PERF-02] gereği p99 da izlenir"
  fi
  if kiyas "$HATA_ORANI" ">" "$HEDEF_HATA_ORANI"; then
    ihlal ZORUNLU PERF-33 "${HEDEF:-$OZET}" \
      "hata oranı %$(awk -v v="$HATA_ORANI" 'BEGIN{printf "%.3f", v*100}') — hedef %0,1 ([PERF-01])"
  fi
  if [[ $HATA -eq 0 ]]; then
    printf '\n%sHEDEFLER KARŞILANDI%s — p95 %s ms < %s ms · hata oranı %%%s < %%0,1\n' \
      "$GRN" "$NC" "$(nb "$P95")" "$HEDEF_P95" \
      "$(awk -v v="$HATA_ORANI" 'BEGIN{printf "%.3f", v*100}')"
    SONUC="gecti"
  else
    SONUC="kaldi"
  fi
fi

# ---------------------------------------------------------------------------
# 6 · Arşivle — karşılaştırma ancak arşiv varsa mümkündür
# ---------------------------------------------------------------------------
if [[ -z "$KAYDET" ]]; then
  bilgi "arşiv yazılmadı (varsayılan). Sonraki koşumla karşılaştırmak için:"
  printf '         --kaydet <yol>/yuk-testi-son.json   sonra: --karsilastir <yol>/yuk-testi-son.json
'
elif [[ "$OZET" != "$KAYDET" ]]; then
  if cp -f "$OZET" "$KAYDET" 2>/dev/null; then
    bilgi "özet kaydedildi: $KAYDET   → sonraki koşumda: --karsilastir $KAYDET"
  else
    ihlal UYARI ARAC-08 "$KAYDET" "özet kaydedilemedi — dizin var ve yazılabilir mi?"
  fi
fi

printf '\n%s\n' "─────────────────────────────────────────────"
printf '%sNot: bu sayılar ORTAMA aittir, koda değil. Aynı kod başka makinede başka sonuç\n' "$DIM"
printf 'verir. Mutlak sayıyı değil, aynı ortamdaki FARKI kovala (--karsilastir).\n'
printf 'Araç yalnızca [PERF-01] p95 ve hata oranı hedeflerini görür; doygunluk eğrisi,\n'
printf 'CPU/bellek kullanımı ve DB tarafı için [PERF-18] profil sırasını uygula.%s\n' "$NC"

if [[ $JSON_CIKTI -eq 1 ]]; then
  printf '{"kural":"PERF-33","arac":"ARAC-08","sonuc":"%s","sinif":"%s","hedef_p95_ms":%s,' \
    "$SONUC" "$SINIF" "$HEDEF_P95"
  printf '"p50_ms":%s,"p95_ms":%s,"p99_ms":%s,"min_ms":%s,"max_ms":%s,' \
    "${P50:-null}" "${P95:-null}" "${P99:-null}" "${MIN:-null}" "${MAX:-null}"
  printf '"istek":%s,"sure_sn":%s,"hata_orani":%s,"gecersiz_kapi":%d,"hata":%d,"uyari":%d}\n' \
    "${ISTEK:-null}" "${SURE_SN:-null}" "${HATA_ORANI:-null}" "$GECERSIZ" "$HATA" "$UYARI"
fi

[[ $GECERSIZ -gt 0 ]] && exit 2
[[ $HATA -gt 0 ]] && exit 1
exit 0
