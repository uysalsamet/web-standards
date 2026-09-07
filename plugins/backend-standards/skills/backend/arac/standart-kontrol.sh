#!/usr/bin/env bash
# =============================================================================
#  standart-kontrol.sh — backend-standartlari otomatik denetimi
#
#  Kullanım:  ./arac/standart-kontrol.sh [kök-dizin]
#  Çıkış:     0 = temiz | 1 = ZORUNLU/YASAK ihlali var
#
#  Bu script, standardın MAKİNE İLE KONTROL EDİLEBİLİR kurallarını denetler.
#  Kapsamadığı kurallar insan/AI incelemesine kalır — kapsam §sonda listelidir.
#
#  Tasarım notu: heuristik'tir, kanıt değildir. Yanlış pozitif çıkarsa kuralı
#  daralt; sessizce devre dışı BIRAKMA (bkz. [CI-21] gerekçesiz //nolint yasağı).
# =============================================================================
set -uo pipefail

ROOT="${1:-.}"
HATA=0
UYARI=0

RED=$'\033[0;31m'; YEL=$'\033[0;33m'; GRN=$'\033[0;32m'; DIM=$'\033[2m'; NC=$'\033[0m'
[[ -t 1 ]] || { RED=""; YEL=""; GRN=""; DIM=""; NC=""; }

# ihlal <seviye> <kural-id> <konum> <mesaj>
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

# Go dosyalarında yorum satırlarını eleyen tarayıcı.
# Yorum içindeki örnek kod ihlal sayılmamalı.
scan() {
  local pat="$1"; shift
  grep -nHE "$pat" "$@" 2>/dev/null | grep -vE ':[0-9]+:[[:space:]]*//' || true
}

gofiles()  { find "$ROOT" -name '*.go' -not -name '*_test.go' -not -path '*/vendor/*' 2>/dev/null; }
sqlfiles() { find "$ROOT" -name '*.sql' -not -path '*/vendor/*' 2>/dev/null; }

mapfile -t GO_FILES < <(gofiles)
mapfile -t SQL_FILES < <(sqlfiles)

printf '%s\n' "backend-standartlari — otomatik denetim"
printf '%s\n' "kök: $ROOT · $(( ${#GO_FILES[@]} )) go · $(( ${#SQL_FILES[@]} )) sql"

# =============================================================================
baslik "A · Bağımlılık ve sürüm"
# =============================================================================

while IFS= read -r f; do
  ver=$(grep -E '^go [0-9]' "$f" | head -1 | awk '{print $2}')
  [[ -n "$ver" && "$ver" != "1.25.12" ]] && \
    ihlal ZORUNLU VER-01 "$f" "go direktifi '$ver' — standart 1.25.12 ([02] §1)"
done < <(find "$ROOT" -name 'go.mod' -not -path '*/vendor/*' 2>/dev/null)

YASAK_DEP='gofiber/fiber|labstack/echo|go-chi/chi|lib/pq|jinzhu/gorm|gorm\.io/gorm|go-pg/pg|entgo\.io/ent|spf13/viper|knadh/koanf|kelseyhightower/envconfig|uber-go/zap|go\.uber\.org/zap|rs/zerolog|sirupsen/logrus|stretchr/testify|gofrs/uuid'
while IFS= read -r hit; do
  dep=$(echo "$hit" | sed -E 's/.*[[:space:]]([a-z0-9./-]*(fiber|echo|chi|pq|gorm|pg|ent|viper|koanf|envconfig|zap|zerolog|logrus|testify|uuid)[a-z0-9./-]*).*/\1/')
  ihlal ZORUNLU VER-05 "${hit%%:*}:$(echo "$hit" | cut -d: -f2)" "yasaklı bağımlılık: $dep — elenme gerekçesi adr/ altında"
done < <(grep -nHE "$YASAK_DEP" $(find "$ROOT" -name 'go.mod' 2>/dev/null) 2>/dev/null || true)

if [[ ${#GO_FILES[@]} -gt 0 ]]; then
  while IFS= read -r hit; do
    ihlal ZORUNLU VER-05 "${hit%:*}" "yasaklı paket import edilmiş"
  done < <(scan "\"(github\.com/(gofiber|labstack/echo|go-chi/chi|lib/pq|jinzhu/gorm|sirupsen/logrus|rs/zerolog|stretchr/testify)|gorm\.io|go\.uber\.org/zap)" "${GO_FILES[@]}" | cut -d: -f1,2)
  done_marker=1
fi

# =============================================================================
baslik "B · Para ve hassas veri"
# =============================================================================

PARA_ALAN='(Amount|Tutar|Price|Fiyat|Debt|Borc|Borç|Balance|Bakiye|Ucret|Ücret|Fee|Total|Toplam|Paid|Odenen|Ödenen|Salary|Maas|Maaş|Cost|Maliyet)'
if [[ ${#GO_FILES[@]} -gt 0 ]]; then
  while IFS= read -r hit; do
    loc=$(echo "$hit" | cut -d: -f1,2)
    ihlal ZORUNLU PARA-01 "$loc" "para alanı float ile tanımlanmış — Money (int64 kuruş) kullan"
  done < <(scan "^[[:space:]]*[A-Z][A-Za-z]*${PARA_ALAN}[A-Za-z]*[[:space:]]+\*?float(32|64)" "${GO_FILES[@]}")

  while IFS= read -r hit; do
    ihlal ZORUNLU AUTH-05 "$(echo "$hit" | cut -d: -f1,2)" "md5/sha1 import edilmiş — parola için argon2id kullan"
  done < <(scan '"crypto/(md5|sha1)"' "${GO_FILES[@]}")

  while IFS= read -r hit; do
    ihlal ZORUNLU SEC-25 "$(echo "$hit" | cut -d: -f1,2)" "log satırında parola/token/sır geçiyor olabilir"
  done < <(scan '(log|Log|logger|slog)\.[A-Za-z]+\(.*(password|passwd|parola|sifre|şifre|token|secret|api_key|apikey)' "${GO_FILES[@]}")
fi

while IFS= read -r hit; do
  ihlal ZORUNLU PARA-02 "$(echo "$hit" | cut -d: -f1,2)" "para kolonu float tipinde — NUMERIC(n,2) kullan"
done < <([[ ${#SQL_FILES[@]} -gt 0 ]] && grep -nHiE "${PARA_ALAN}[a-z_]*[[:space:]]+(REAL|DOUBLE PRECISION|FLOAT|MONEY)" "${SQL_FILES[@]}" 2>/dev/null || true)

# =============================================================================
baslik "C · Veritabanı"
# =============================================================================

if [[ ${#SQL_FILES[@]} -gt 0 ]]; then
  while IFS= read -r hit; do
    ihlal ZORUNLU DB-05 "$(echo "$hit" | cut -d: -f1,2)" "SERIAL/BIGSERIAL primary key — UUID DEFAULT gen_random_uuid() kullan (IDOR)"
  done < <(grep -nHiE '(BIG)?SERIAL[[:space:]]+PRIMARY[[:space:]]+KEY' "${SQL_FILES[@]}" 2>/dev/null || true)

  while IFS= read -r hit; do
    ihlal ZORUNLU DB-06 "$(echo "$hit" | cut -d: -f1,2)" "TIMESTAMP (tz'siz) — TIMESTAMPTZ kullan"
  done < <(grep -nHiE '[[:space:]]TIMESTAMP([[:space:]]|,|$)' "${SQL_FILES[@]}" 2>/dev/null | grep -viE 'TIMESTAMPTZ|WITH TIME ZONE' || true)

  for f in "${SQL_FILES[@]}"; do
    if grep -qiE '^\s*--\s*\+goose Up' "$f" && ! grep -qiE '^\s*--\s*\+goose Down' "$f"; then
      ihlal ZORUNLU DB-12 "$f" "goose Down bloğu yok — migration geri alınamaz"
    fi
    if grep -qiE 'GEOMETRY[[:space:]]*\(' "$f" && ! grep -qiE 'USING[[:space:]]+GIST' "$f"; then
      ihlal ZORUNLU GIS-05 "$f" "GEOMETRY kolonu var ama GIST index yok — uzamsal sorgu tam tarama yapar"
    fi
  done
fi

if [[ ${#GO_FILES[@]} -gt 0 ]]; then
  while IFS= read -r hit; do
    ihlal ZORUNLU DB-18 "$(echo "$hit" | cut -d: -f1,2)" "SELECT * — kolonları açıkça yaz"
  done < <(scan 'SELECT[[:space:]]+\*' "${GO_FILES[@]}")

  while IFS= read -r hit; do
    ihlal ZORUNLU SEC-15 "$(echo "$hit" | cut -d: -f1,2)" "SQL'e Sprintf ile DEĞER gömülmüş — parametre kullan (SQL injection)"
  done < <(scan 'Sprintf\(.*(SELECT|INSERT|UPDATE|DELETE|WHERE).*%s' "${GO_FILES[@]}" | grep -viE '%s FROM|SELECT %s|%s WHERE|, where,' || true)

  while IFS= read -r hit; do
    ihlal ZORUNLU DB-19 "$(echo "$hit" | cut -d: -f1,2)" "ORDER BY + LIMIT ama tie-break yok — sayfalar arası kayıt tekrarı/atlaması"
  done < <(scan 'ORDER BY[^,)]*LIMIT' "${GO_FILES[@]}")
fi

# =============================================================================
baslik "D · HTTP katmanı ve Gin"
# =============================================================================

if [[ ${#GO_FILES[@]} -gt 0 ]]; then
  while IFS= read -r hit; do
    ihlal ZORUNLU YAP-13 "$(echo "$hit" | cut -d: -f1,2)" "gin.Default() — gin.New() kullan (Default kendi logger'ını ekler, çift log)"
  done < <(scan 'gin\.Default\(\)' "${GO_FILES[@]}")

  while IFS= read -r hit; do
    ihlal ZORUNLU API-12 "$(echo "$hit" | cut -d: -f1,2)" "c.Bind*/BindJSON — ShouldBindJSON kullan (Bind* kendi 400'ünü yazar)"
  done < <(scan '\bc\.(Bind|BindJSON|BindQuery|BindUri|MustBindWith)\(' "${GO_FILES[@]}")

  while IFS= read -r hit; do
    ihlal ZORUNLU YAP-19 "$(echo "$hit" | cut -d: -f1,2)" "hata yanıtında c.JSON — AbortWithStatusJSON kullan (zincir durmalı)"
  done < <(scan 'c\.JSON\([[:space:]]*http\.Status(BadRequest|Unauthorized|Forbidden|NotFound|Conflict|TooManyRequests|InternalServerError|ServiceUnavailable)' "${GO_FILES[@]}")

  while IFS= read -r hit; do
    ihlal ZORUNLU YAP-10 "$(echo "$hit" | cut -d: -f1,2)" "*gin.Context alt katmana geçirilmiş — c.Request.Context() geçir"
  done < <(scan '\.(svc|Svc|service|Service)\.[A-Z][A-Za-z]*\([[:space:]]*c[,)]' "${GO_FILES[@]}")

  for f in "${GO_FILES[@]}"; do
    if grep -q 'gin\.New()' "$f" && ! grep -q 'ContextWithFallback' "$f"; then
      ihlal ZORUNLU YAP-14 "$f" "gin.New() var ama ContextWithFallback ayarlanmamış — iptal sinyali kaybolur"
    fi
    if grep -qE '&http\.Server\{' "$f" && ! grep -q 'ReadTimeout' "$f"; then
      ihlal ZORUNLU RES-07 "$f" "http.Server timeout'suz — ReadHeaderTimeout/ReadTimeout/WriteTimeout/IdleTimeout ver"
    fi
    if grep -qE '(&)?http\.Client\{[[:space:]]*\}' "$f"; then
      ihlal ZORUNLU RES-08 "$f" "timeout'suz http.Client — varsayılanı SONSUZ"
    fi
  done
fi

# route yetki kontrolü
while IFS= read -r f; do
  while IFS= read -r hit; do
    line=$(echo "$hit" | cut -d: -f2-)
    echo "$line" | grep -qE '/(health|ready|metrics|version)' && continue
    echo "$line" | grep -q 'RequirePermission\|RequireAny\|RequireAll' && continue
    ihlal ZORUNLU GEN-10 "$(echo "$hit" | cut -d: -f1,2)" "endpoint yetkisiz tanımlanmış — RequirePermission ekle veya gerekçeyi yoruma yaz"
  done < <(scan '^[[:space:]]*[a-zA-Z_][a-zA-Z0-9_]*\.(GET|POST|PUT|DELETE|PATCH)\(' "$f")

  while IFS= read -r hit; do
    ihlal UYARI API-01b "$(echo "$hit" | cut -d: -f1,2)" "yol '/list' içeriyor — liste kaynağın kökünde olmalı (GET /kaynak)"
  done < <(scan '\.(GET|POST)\("/list"|"/[a-z-]+/list"' "$f")
done < <(find "$ROOT" -name 'routes*.go' -not -name '*_test.go' 2>/dev/null)

# =============================================================================
baslik "E · Loglama, hata yönetimi, Türkçe"
# =============================================================================

if [[ ${#GO_FILES[@]} -gt 0 ]]; then
  while IFS= read -r hit; do
    ihlal ZORUNLU OBS-01 "$(echo "$hit" | cut -d: -f1,2)" "yapısal olmayan log — log/slog kullan"
  done < <(scan '(fmt\.Print(ln|f)?\(|[^g]log\.(Print|Printf|Println|Fatal|Fatalf)\()' "${GO_FILES[@]}")

  # Boş hata bloğu: hem "if err != nil {" hem "if err := f(); err != nil {" biçimi.
  for f in "${GO_FILES[@]}"; do
    awk -v F="$f" '
      /if .*err != nil[[:space:]]*\{[[:space:]]*$/ { line=NR; pending=1; next }
      pending && /^[[:space:]]*\}[[:space:]]*$/ { print F":"line; pending=0; next }
      { pending=0 }
    ' "$f" 2>/dev/null | while IFS= read -r loc; do
      ihlal ZORUNLU GEN-19 "$loc" "hata yutulmuş (boş blok) — ele al ya da yukarı fırlat"
    done
  done

  # PUT DTO'sunda tüm alanlar pointer olmalı [API-06]
  for f in "${GO_FILES[@]}"; do
    awk -v F="$f" '
      /^type[[:space:]]+[A-Za-z]*UpdateRequest[[:space:]]+struct[[:space:]]*\{/ { inb=1; next }
      inb && /^\}/ { inb=0; next }
      inb && /^[[:space:]]*\/\// { next }
      inb && /^[[:space:]]+[A-Z][A-Za-z0-9_]*[[:space:]]+[^*[:space:]]/ {
        if ($0 !~ /Version/) print F":"NR
      }
    ' "$f" 2>/dev/null | while IFS= read -r loc; do
      ihlal ZORUNLU API-06 "$loc" "PUT DTO alanı pointer değil — tek alan güncellemesi diğerlerini sıfırlar"
    done
  done

  while IFS= read -r hit; do
    ihlal UYARI TRK-05 "$(echo "$hit" | cut -d: -f1,2)" "strings.ToLower/ToUpper — Türkçe metinse cases.Lower(language.Turkish) kullan"
  done < <(scan 'strings\.(ToLower|ToUpper|EqualFold)\(' "${GO_FILES[@]}")

  for f in "${GO_FILES[@]}"; do
    n=$(wc -l < "$f")
    base=$(basename "$f")
    if [[ "$base" == "main.go" && $n -gt 150 ]]; then
      ihlal UYARI YAP-11 "$f" "main.go $n satır — 150'yi geçmemeli (sadece wiring)"
    elif [[ $n -gt 500 ]]; then
      ihlal UYARI YAP-05 "$f" "$n satır — 500'ü geçmemeli, modülü böl"
    fi
  done
fi

# =============================================================================
baslik "F · Docker ve compose"
# =============================================================================

while IFS= read -r f; do
  grep -qE '^FROM .*:latest' "$f" && ihlal ZORUNLU OPS-02 "$f" "base imaj :latest — sürüm pinle"
  grep -qE '^\s*USER ' "$f" || ihlal ZORUNLU OPS-03 "$f" "USER yok — konteyner root çalışıyor"
  grep -qiE '^\s*HEALTHCHECK' "$f" || ihlal ZORUNLU OPS-04 "$f" "HEALTHCHECK yok"
done < <(find "$ROOT" -name 'Dockerfile*' -not -path '*/vendor/*' 2>/dev/null)

while IFS= read -r f; do
  while IFS= read -r hit; do
    ihlal ZORUNLU VER-02 "$(echo "$hit" | cut -d: -f1,2)" "imaj :latest — sürüm pinle"
  done < <(grep -nHE '^\s*image:[[:space:]]*[^[:space:]]+:latest' "$f" 2>/dev/null || true)

  while IFS= read -r hit; do
    ihlal ZORUNLU SEC-18 "$(echo "$hit" | cut -d: -f1,2)" "compose'a sır GÖMÜLMÜŞ — \${DEGISKEN} referansı kullan"
  done < <(grep -nHiE '^\s*[A-Z_]*(PASSWORD|SECRET|API_KEY|APIKEY|TOKEN|PRIVATE_KEY)[A-Z_]*:[[:space:]]*[^$[:space:]]' "$f" 2>/dev/null || true)

  while IFS= read -r hit; do
    ihlal UYARI SEC-01 "$(echo "$hit" | cut -d: -f1,2)" "'ports:' dışarı açıyor — gateway dışındaki servis 'expose:' kullanmalı"
  done < <(grep -nHE '^\s*ports:' "$f" 2>/dev/null || true)

  grep -q 'memory:' "$f" || ihlal UYARI PERF-05 "$f" "bellek limiti tanımsız — sızıntıda tüm host etkilenir"
  grep -q 'max-size:' "$f" || ihlal UYARI OPS-12 "$f" "log rotasyonu tanımsız — json-file driver diski doldurur"
done < <(find "$ROOT" -name 'docker-compose*.yml' -o -name 'compose*.yml' 2>/dev/null)

# =============================================================================
baslik "G · Repo hijyeni"
# =============================================================================

if [[ -d "$ROOT/.git" || -f "$ROOT/.gitignore" ]]; then
  if [[ ! -f "$ROOT/.gitignore" ]] || ! grep -q '\.env' "$ROOT/.gitignore" 2>/dev/null; then
    ihlal ZORUNLU SEC-20 "$ROOT/.gitignore" ".env deseni .gitignore'da yok — sır git'e girebilir"
  fi
fi
while IFS= read -r d; do
  [[ -f "$d/.dockerignore" ]] || ihlal UYARI OPS-06 "$d/.dockerignore" ".dockerignore yok — .env imaja girebilir"
done < <(find "$ROOT" -name 'Dockerfile' -exec dirname {} \; 2>/dev/null | sed 's|/deployments$||' | sort -u)

# =============================================================================
printf '\n%s\n' "─────────────────────────────────────────────"
if [[ $HATA -eq 0 && $UYARI -eq 0 ]]; then
  printf '%sTEMİZ%s — otomatik kontrol edilebilen kurallarda ihlal yok\n' "$GRN" "$NC"
elif [[ $HATA -eq 0 ]]; then
  printf '%s%d uyarı%s, hata yok\n' "$YEL" "$UYARI" "$NC"
else
  printf '%s%d HATA%s, %d uyarı\n' "$RED" "$HATA" "$NC" "$UYARI"
fi
printf '%sNot: bu script kuralların ~%%8''ini kontrol eder. Kalanı insan/AI incelemesine kalır —\n' "$DIM"
printf 'KURAL-HARITASI.md §1 sinyal tablosunu tara.%s\n' "$NC"

[[ $HATA -gt 0 ]] && exit 1
exit 0
