#!/usr/bin/env bash
# =============================================================================
#  sir-tarama.sh — depoda sır sızıntısı taraması  [ARAC-05]
#
#  Kullanım:  bash arac/sir-tarama.sh [kök-dizin]
#  Çıkış:     0 = temiz | 1 = en az bir KRİTİK bulgu
#
#  Bu script SADECE TESPİT eder ve UYARIR. Hiçbir şeyi DÜZELTMEZ:
#  git rm yapmaz, geçmiş temizlemez, rotasyon tetiklemez, dosya taşımaz.
#  Sır sızıntısı bir olay müdahalesidir; kararı insan verir. Script salt okunur.
#
#  Tasarım notu: heuristiktir, kanıt değildir ([ARAC-01]). Yanlış pozitif çıkarsa
#  eleme listesini genişlet; kontrolü sessizce kapatma ([ARAC-02]).
#
#  MASKELEME KURALI — [SEC-25]: bir denetim raporu, bulduğu sırrı yayınlamaz.
#  Ekrana yalnızca dosya yolu, satır numarası, bulgu türü ve DEĞİŞKEN ADI basılır.
#  Değerin kendisi asla basılmaz; ayırt edilebilsin diye en fazla ilk 4 karakter +
#  uzunluk gösterilir. Gerekçe: AWS/JWT gibi desenlerde ilk 4 karakter zaten
#  bulgunun türünü söyleyen sabit önektir, tek başına sırrı kullanılabilir kılmaz;
#  6 karakter ve altındaki değerlerde önek de gösterilmez.
# =============================================================================
set -uo pipefail

ROOT="${1:-.}"
KRITIK=0
UYARI=0

RED=$'\033[0;31m'; YEL=$'\033[0;33m'; GRN=$'\033[0;32m'; DIM=$'\033[2m'; NC=$'\033[0m'
[[ -t 1 ]] || { RED=""; YEL=""; GRN=""; DIM=""; NC=""; }

# ihlal <seviye> <kural-id> <konum> <mesaj>
ihlal() {
  local sev="$1" id="$2" loc="$3" msg="$4"
  if [[ "$sev" == "KRITIK" ]]; then
    printf '%sKRITIK%s [%s] %s\n         %s\n' "$RED" "$NC" "$id" "$loc" "$msg"
    KRITIK=$((KRITIK+1))
  else
    printf '%sUYARI%s  [%s] %s\n         %s\n' "$YEL" "$NC" "$id" "$loc" "$msg"
    UYARI=$((UYARI+1))
  fi
}

baslik() { printf '\n%s── %s %s\n' "$DIM" "$1" "$NC"; }

# maskele <deger> → "abcd... (32 karakter)"
# Değerin tamamı ASLA döndürülmez.
maskele() {
  local v="$1" n=${#1}
  if (( n <= 6 )); then printf '**** (%d karakter)' "$n"
  else printf '%s... (%d karakter)' "${v:0:4}" "$n"; fi
}

# -----------------------------------------------------------------------------
# YANLIŞ POZİTİF ELEME LİSTESİ — açıkça görünür olsun diye burada duruyor.
# Değerin küçük harfe indirilmiş hali bu desenlerden birini içeriyorsa bulgu
# sayılmaz: placeholder, örnek dosya değeri, env referansı, şablon ve format
# belirteçleri. Liste genişletilebilir; kontrolü kapatmak yerine burayı genişlet.
# -----------------------------------------------------------------------------
ELEME='example|sample|dummy|test|change[-_ ]?me|xxx|your-|your_|yourname|redacted|placeholder|<|\$\{|\$\(|%s|%v|todo|fixme|foobar|\(|getenv|process\.env|os\.environ|viper\.|config\.|settings\.|null|none|empty|\.\.\.'

# Sırra benzeyen ATAMA deseni: anahtar adı + ayıraç + 8+ karakterlik sabit değer.
# TRQ = tek ve çift tırnak karakterleri. Aşağıdaki tr/sed/grep ifadelerinde
# okunaklılık için ANSI-C alıntılama ($'...') kullanılıyor.
TRQ=$'\'"'
ATAMA_PAT=$'(password|passwd|parola|sifre|secret|token|api_key|apikey|private_key|connection_string|conn_string)[\'"]?[[:space:]]*[:=][[:space:]]*[\'"]?[^\'"[:space:],;)}]{8,}'

# Yorum satırlarını eler (//, #, --). Yorumdaki örnek sır ihlal sayılmamalı.
# (standart-kontrol.sh scan() ile aynı yaklaşım)
yorumsuz() { grep -vE ':[0-9]+:[[:space:]]*(//|#|--)' || true; }

# grep hit satırını (dosya:satır:içerik) parçala.
# Windows yollarında sürücü harfi ("C:\...") kendi başına iki nokta içerir;
# bu yüzden basit ${h%%:*} kesmesi yerine sürücü öneki açıkça tanınıyor.
hit_loc() { printf '%s' "$1" | sed -E 's/^(([A-Za-z]:)?[^:]*:[0-9]+):.*$/\1/'; }
hit_txt() { printf '%s' "$1" | sed -E 's/^([A-Za-z]:)?[^:]*:[0-9]+://'; }

kucuk() { printf '%s' "$1" | tr 'A-Z' 'a-z'; }

# sir_gibi <deger> → 0 ise sırra benziyor.
# İkinci eleme katmanı: ELEME listesi bilinen placeholder'ları eler, bu fonksiyon
# DOĞAL DİL metnini eler. Gerçek bir sır ya harf+rakam karışımıdır ya da uzundur;
# i18n çeviri dosyalarındaki "Password" / "Şifreniz hatalı" gibi arayüz metinleri
# ikisini de sağlamaz. (Kabul edilen yanlış negatif: "postgres" gibi tamamen
# harften oluşan zayıf parolalar burada kaçar — compose kontrolü onları yakalar.)
sir_gibi() {
  local v="$1"
  (( ${#v} >= 20 )) && return 0
  printf '%s' "$v" | grep -q '[0-9]' && printf '%s' "$v" | grep -q '[A-Za-z]' && return 0
  return 1
}

# -----------------------------------------------------------------------------
# Taranacak kaynak dosyalar. vendor/, node_modules/, .git/, testdata/ atlanır.
# 2 MB üstü dosyalar atlanır: veri/lock dosyaları taramayı boğar. Bilinçli sınır.
# -----------------------------------------------------------------------------
srcfiles() {
  find "$ROOT" \
    \( -path '*/vendor/*' -o -path '*/node_modules/*' -o -path '*/.git/*' \
       -o -path '*/testdata/*' -o -path '*/dist/*' -o -path '*/build/*' \) -prune -o \
    -type f -size -2048k \
    \( -name '*.go' -o -name '*.yml' -o -name '*.yaml' -o -name '*.json' \
       -o -name '*.sql' -o -name 'Dockerfile*' \) -print 2>/dev/null
}

mapfile -t SRC_FILES < <(srcfiles)

printf '%s\n' "sır taraması — SADECE TESPİT, hiçbir düzeltme yapılmaz  [ARAC-05]"
printf '%s\n' "kök: $ROOT · ${#SRC_FILES[@]} kaynak dosya taranacak"

# =============================================================================
baslik "A · Git tarafından İZLENEN sır dosyaları  [SEC-18][SEC-20][SEC-22]"
# =============================================================================
# En kritik bulgu budur: dosya commit edildiyse sır zaten sızmıştır.

if git -C "$ROOT" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  IZLENEN_SIR='(^|/)\.env($|\.)|\.(pem|key|p12|pfx|jks)$|(^|/)id_rsa$|(^|/)credentials\.json$|(^|/)serviceaccount[^/]*\.json$'
  # .env.example / .env.sample / .env.template git'e GİRMELİ [SEC-21] — elenir.
  bulundu=0
  while IFS= read -r f; do
    [[ -z "$f" ]] && continue
    bulundu=1
    tur="sır dosyası"
    case "$f" in
      *.pem|*.key|*.p12|*.pfx|*.jks|*id_rsa)        tur="özel anahtar / sertifika" ;;
      *credentials.json|*serviceaccount*.json)      tur="servis hesabı kimlik dosyası" ;;
      *.env|*.env.*)                                tur="ortam değişkeni dosyası" ;;
    esac
    ihlal KRITIK SEC-18 "$f" "git tarafından İZLENİYOR ($tur) — commit edilmiş; geçmişte ve tüm klonlarda duruyor. [SEC-22] rotasyon gerekir."
  done < <(git -C "$ROOT" ls-files 2>/dev/null \
             | grep -E "$IZLENEN_SIR" \
             | grep -vE '(^|/)\.env\.(example|sample|template)$' || true)
  (( bulundu == 0 )) && printf '%s   izlenen sır dosyası yok.%s\n' "$DIM" "$NC"
else
  printf '%s   git deposu değil — izlenen dosya kontrolü ATLANDI.%s\n' "$DIM" "$NC"
  printf '%s   (bu kontrol sızıntının en kesin kanıtıdır; git dışı kopyada yapılamaz)%s\n' "$DIM" "$NC"
fi

# =============================================================================
baslik "B · .gitignore eksikleri  [SEC-20]"
# =============================================================================

GI="$ROOT/.gitignore"
if [[ ! -f "$GI" ]]; then
  ihlal KRITIK SEC-20 "$GI" ".gitignore yok — sır dosyaları hiçbir korumaya sahip değil; ilk iş bunu oluşturmak"
else
  grep -qE '(^|/)\.env' "$GI" 2>/dev/null || \
    ihlal UYARI SEC-20 "$GI" "'.env' deseni yok — ortam dosyası yanlışlıkla commit edilebilir"
  grep -qE '\*\.pem' "$GI" 2>/dev/null || \
    ihlal UYARI SEC-20 "$GI" "'*.pem' deseni yok — sertifika/özel anahtar commit edilebilir"
  grep -qE '\*\.key' "$GI" 2>/dev/null || \
    ihlal UYARI SEC-20 "$GI" "'*.key' deseni yok — özel anahtar commit edilebilir"
fi

# =============================================================================
baslik "C · Kaynak kodda gömülü sır  [SEC-18]"
# =============================================================================

if (( ${#SRC_FILES[@]} > 0 )); then

  # C1 — sabit değerli sır ataması (password=, secret=, token=, api_key= ...)
  while IFS= read -r hit; do
    [[ -z "$hit" ]] && continue
    loc=$(hit_loc "$hit"); txt=$(hit_txt "$hit")
    m=$(printf '%s' "$txt" | grep -oiE "$ATAMA_PAT" | head -1)
    [[ -z "$m" ]] && continue
    key=$(printf '%s' "$m" | sed -E 's/[:=].*$//' | tr -d "$TRQ ")
    val=$(printf '%s' "$m" | sed -E $'s/^[^:=]*[:=][[:space:]]*[\'"]?//' | sed -E $'s/[\'",;].*$//')
    (( ${#val} < 8 )) && continue
    kucuk "$val" | grep -qE "$ELEME" && continue
    sir_gibi "$val" || continue
    ihlal KRITIK SEC-18 "$loc" "gömülü sır: '$key' alanına sabit değer atanmış → $(maskele "$val")"
    # compose dosyaları D bölümünde ayrıca ve daha isabetli taranır; çift
    # raporlamayı önlemek için burada dışarıda bırakılıyorlar.
  done < <(grep -nHiE "$ATAMA_PAT" "${SRC_FILES[@]}" 2>/dev/null \
             | grep -vE '(docker-)?compose[^:]*\.(yml|yaml):' | yorumsuz)

  # C2 — AWS erişim anahtarı deseni
  while IFS= read -r hit; do
    [[ -z "$hit" ]] && continue
    v=$(hit_txt "$hit" | grep -oE 'AKIA[0-9A-Z]{16}' | head -1)
    [[ -z "$v" ]] && continue
    ihlal KRITIK SEC-18 "$(hit_loc "$hit")" "AWS erişim anahtarı deseni → $(maskele "$v")"
  done < <(grep -nHE 'AKIA[0-9A-Z]{16}' "${SRC_FILES[@]}" 2>/dev/null | yorumsuz)

  # C3 — JWT deseni (başlık.payload)
  while IFS= read -r hit; do
    [[ -z "$hit" ]] && continue
    v=$(hit_txt "$hit" | grep -oE 'eyJ[A-Za-z0-9_-]{10,}\.eyJ[A-Za-z0-9_-]{4,}' | head -1)
    [[ -z "$v" ]] && continue
    ihlal KRITIK SEC-18 "$(hit_loc "$hit")" "JWT gömülü → $(maskele "$v")  — token asla koda sabitlenmez [SEC-25]"
  done < <(grep -nHE 'eyJ[A-Za-z0-9_-]{10,}\.eyJ' "${SRC_FILES[@]}" 2>/dev/null | yorumsuz)

  # C4 — parola içeren bağlantı dizesi (postgres://user:parola@host)
  # Değerin hiçbir parçası ham basılmaz; parola maskelenir.
  while IFS= read -r hit; do
    [[ -z "$hit" ]] && continue
    dsn=$(hit_txt "$hit" | grep -oiE $'(postgres(ql)?|mysql|mongodb(\\+srv)?|redis|amqps?)://[^:@[:space:]\'"]+:[^@[:space:]\'"]{4,}@' | head -1)
    [[ -z "$dsn" ]] && continue
    parola=$(printf '%s' "$dsn" | sed -E 's|^[^:]*://[^:]*:||; s/@$//')
    kucuk "$parola" | grep -qE "$ELEME" && continue
    sir_gibi "$parola" || continue
    ihlal KRITIK SEC-18 "$(hit_loc "$hit")" "bağlantı dizesinde (DSN) gömülü parola → $(maskele "$parola")"
  done < <(grep -nHiE '(postgres(ql)?|mysql|mongodb(\+srv)?|redis|amqps?)://[^:@[:space:]]+:[^@[:space:]]{4,}@' "${SRC_FILES[@]}" 2>/dev/null | yorumsuz)

  # C5 — sağlayıcı token önekleri (Slack, GitHub)
  while IFS= read -r hit; do
    [[ -z "$hit" ]] && continue
    v=$(hit_txt "$hit" | grep -oE '(xox[baprs]-[A-Za-z0-9-]{10,}|ghp_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{20,})' | head -1)
    [[ -z "$v" ]] && continue
    ihlal KRITIK SEC-18 "$(hit_loc "$hit")" "sağlayıcı token öneki (Slack/GitHub) → $(maskele "$v")"
  done < <(grep -nHE '(xox[baprs]-[A-Za-z0-9-]{10,}|ghp_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{20,})' "${SRC_FILES[@]}" 2>/dev/null | yorumsuz)

  # C6 — özel anahtar bloğu başlığı (içerik hiç okunmaz, hiç basılmaz)
  while IFS= read -r hit; do
    [[ -z "$hit" ]] && continue
    ihlal KRITIK SEC-18 "$(hit_loc "$hit")" "özel anahtar bloğu koda gömülü (BEGIN … PRIVATE KEY) — içerik okunmadı"
  done < <(grep -nHE 'BEGIN (RSA |EC |DSA |OPENSSH |PGP )?PRIVATE KEY' "${SRC_FILES[@]}" 2>/dev/null | yorumsuz)
fi

# Özel anahtar dosyaları ayrıca dosya olarak da aranır (kaynak uzantısı taşımazlar).
while IFS= read -r f; do
  [[ -z "$f" ]] && continue
  ihlal KRITIK SEC-18 "$f" "diskte özel anahtar dosyası — git'te olmasa bile imaja/artefakta sızabilir [SEC-20]"
done < <(grep -rlE 'BEGIN (RSA |EC |DSA |OPENSSH |PGP )?PRIVATE KEY' "$ROOT" \
           --exclude-dir=vendor --exclude-dir=node_modules --exclude-dir=.git \
           --exclude-dir=testdata --include='*.pem' --include='*.key' --include='id_rsa' 2>/dev/null || true)

# =============================================================================
baslik "D · docker-compose içinde gömülü sır  [SEC-18]"
# =============================================================================
# ${DEGISKEN} referansı sorun değil; SABİT değer sorundur.

while IFS= read -r f; do
  [[ -z "$f" ]] && continue
  while IFS= read -r hit; do
    [[ -z "$hit" ]] && continue
    loc=$(hit_loc "$hit"); txt=$(hit_txt "$hit")
    key=$(printf '%s' "$txt" | sed -E 's/^[[:space:]]*-?[[:space:]]*//; s/[:=].*$//' | tr -d "$TRQ ")
    val=$(printf '%s' "$txt" | sed -E 's/^[^:=]*[:=][[:space:]]*//; s/[[:space:]]*(#.*)?$//' | tr -d "$TRQ")
    [[ -z "$val" ]] && continue
    kucuk "$val" | grep -qE "$ELEME" && continue
    ihlal KRITIK SEC-18 "$loc" "compose'a sır GÖMÜLMÜŞ: '$key' → $(maskele "$val")  — \${$key} referansı kullan"
  done < <(grep -nHiE '^[[:space:]]*-?[[:space:]]*[A-Z_]*(PASSWORD|PASSWD|SECRET|API_KEY|APIKEY|TOKEN|PRIVATE_KEY)[A-Z_]*[:=][[:space:]]*[^$[:space:]]' "$f" 2>/dev/null | yorumsuz)
done < <(find "$ROOT" \( -path '*/vendor/*' -o -path '*/node_modules/*' -o -path '*/.git/*' \) -prune -o \
           -type f \( -name 'docker-compose*.yml' -o -name 'docker-compose*.yaml' -o -name 'compose*.yml' \) -print 2>/dev/null)

# =============================================================================
baslik "E · Log satırında sır  [SEC-25][SEC-26]"
# =============================================================================

mapfile -t GO_FILES < <(find "$ROOT" \( -path '*/vendor/*' -o -path '*/.git/*' -o -path '*/testdata/*' \) -prune -o \
                          -type f -name '*.go' -print 2>/dev/null)

if (( ${#GO_FILES[@]} > 0 )); then
  while IFS= read -r hit; do
    [[ -z "$hit" ]] && continue
    alan=$(hit_txt "$hit" | grep -oiE '(password|passwd|parola|sifre|şifre|token|secret|api_key|apikey)' | head -1)
    ihlal KRITIK SEC-25 "$(hit_loc "$hit")" "log çağrısında sır alan ADI geçiyor: '$alan' — loglama, maskele"
    # Sır adının TIRNAK İÇİNDE geçmesi aranıyor: slog alan adları ve format
    # dizeleri böyledir. Daraltmanın sebebi, MQTT'nin token.Error() gibi
    # identifier erişimlerinin sır sanılmasıydı ([ARAC-02] kuralı daralt).
  done < <(grep -nHE $'(log|Log|logger|slog)\\.[A-Za-z]+\\(.*[\'"][^\'"]{0,24}(password|passwd|parola|sifre|şifre|token|secret|api_key|apikey)[^\'"]{0,24}[\'"]' "${GO_FILES[@]}" 2>/dev/null | yorumsuz)

  while IFS= read -r hit; do
    [[ -z "$hit" ]] && continue
    ihlal UYARI SEC-26 "$(hit_loc "$hit")" "log satırında %+v / %#v — struct içindeki sır da basılır"
  done < <(grep -nHE '(log|Log|logger|slog)\.[A-Za-z]+\(.*%[+#]v' "${GO_FILES[@]}" 2>/dev/null | yorumsuz)
fi

# =============================================================================
printf '\n%s\n' "─────────────────────────────────────────────"
if (( KRITIK == 0 && UYARI == 0 )); then
  printf '%sTEMİZ%s — taranan desenlerde sır sızıntısı bulunmadı\n' "$GRN" "$NC"
elif (( KRITIK == 0 )); then
  printf '%s%d uyarı%s, kritik bulgu yok\n' "$YEL" "$UYARI" "$NC"
else
  printf '%s%d KRİTİK%s, %d uyarı\n' "$RED" "$KRITIK" "$NC" "$UYARI"
fi

if (( KRITIK > 0 )); then
  printf '\n%s' "$RED"
  printf '%s\n' "════════════════════════════════════════════════════════════════════════"
  printf '%s\n' " KRİTİK — SIR SIZINTISI. BU SCRIPT HİÇBİR ŞEY DÜZELTMEDİ."
  printf '%s\n' "════════════════════════════════════════════════════════════════════════"
  printf '%s' "$NC"
  printf '%s\n' "
Script salt okunur çalıştı: git rm yapmadı, geçmiş temizlemedi, dosya taşımadı,
hiçbir sırrı rotasyona sokmadı. Aşağıdakiler SENİN kararın:

 1. ÖNCE ROTASYON — [SEC-22]. Sır git'e girdiyse commit'i geri almak YETMEZ;
    geçmişte, klonlarda, CI cache'inde ve imaj katmanlarında durmaya devam eder.
    Değeri değiştir: parola, API anahtarı, sertifika, servis hesabı anahtarı.
    Rotasyon yapılmadan atılan her adım kozmetiktir.

 2. Dosyayı takipten çıkar ve .gitignore'a ekle — [SEC-20].
    Değerler dışarı, .env.example içeri: değişken adları var, değerler
    placeholder — [SEC-21].

 3. Geçmiş temizleme (git filter-repo / BFG) AYRI VE AĞIR BİR KARARDIR:
    tüm commit hash'leri değişir, açık PR'lar ve mevcut klonlar bozulur, ekip
    koordinasyonu ister. Rotasyonun yerine geçmez, tamamlayıcısıdır.
    Bu scriptin işi değildir — önerir, uygulamaz.

 4. Sızıntının kapsamını çıkar: sır ne zamandan beri commit'te, repo public mi,
    fork/klon var mı, değer log'lara bastı mı — [SEC-25], [SEC-26].

 5. Bu tarama CI'da zorunlu koşar; kritik bulguda pipeline kırılır —
    [SEC-38], [CI-26]."
fi

printf '\n%sSınırlar [ARAC-01]: bu tarama heuristiktir, kanıt değildir. Desen tabanlıdır —\n' "$DIM"
printf 'entropi hesaplamaz; isimsiz ya da base64 gömülü sırrı kaçırır. 2 MB üstü dosyalar,\n'
printf 'vendor/, node_modules/, testdata/ ve GİT GEÇMİŞİ taranmaz; yalnızca çalışma ağacı\n'
printf 've izlenen dosya listesi görülür. Temiz sonuç "sır yok" demek değildir.%s\n' "$NC"

(( KRITIK > 0 )) && exit 1
exit 0
