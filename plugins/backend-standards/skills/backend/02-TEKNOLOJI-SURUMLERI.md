# 02 — Teknoloji ve Sürüm Standardı

> **Bu dosya bağlayıcıdır.** Bir sürüm seçmen gerektiğinde buraya bakılır, "en son ne varsa"
> denmez. Tabloda olmayan bir bağımlılık eklemek onay gerektirir ([GEN-03]).
>
> **Sürümler bu tarihte doğrulandı: 2026-08-12.**
> **Bir sonraki gözden geçirme: 2026-11-12** (üç aylık).
> Gözden geçirme yapılmadıysa bunu bilmek, yanlış sürüm kullanmaktan iyidir — tarihi güncelle.
>
> Her seçimin **neden** yapıldığı ve hangi alternatifin neden elendiği
> [adr/](adr/) klasöründeki karar kayıtlarındadır. Bir seçimi tartışmadan önce
> ilgili ADR'yi oku — muhtemelen zaten tartışılmıştır.

---

## 1. Çekirdek stack (değişmez)

| Katman | Seçim | Pinlenen sürüm | Neden bu | ADR |
|---|---|---|---|---|
| Dil | Go | **1.25.12** | Desteklenen hat (son iki major). Gin v1.12 `go 1.25.0` istiyor. | [0002](adr/0002-go-surumu.md) |
| HTTP framework | `github.com/gin-gonic/gin` | **v1.12.0** | `net/http` tabanlı → tüm ekosistem uyumlu, HTTP/2 hazır, API yıllardır stabil. | [0001](adr/0001-http-framework.md) |
| Postgres sürücü | `github.com/jackc/pgx/v5` | **v5.10.0** | `lib/pq` bakım modunda. Native pool (`pgxpool`), context, batch, `CopyFrom`. | [0003](adr/0003-postgres-surucu.md) |
| Cache istemci | `github.com/redis/go-redis/v9` | **v9.22.0** | Valkey ile wire-compatible; istemci tarafında değişiklik yok. | [0009](adr/0009-cache-motoru.md) |
| Kafka istemci | `github.com/twmb/franz-go` | **v1.21.6** | Aktif, KRaft + transaction tam destekli, cgo yok. | [0008](adr/0008-mesajlasma-altyapisi.md) |
| Workflow | `go.temporal.io/sdk` | **v1.47.0** | Uzun süreli/çok adımlı işler. | [0010](adr/0010-workflow-motoru.md) |
| Log | `log/slog` | **stdlib** | Yapısal log için ek bağımlılık gereksiz. | [0005](adr/0005-loglama.md) |
| Metrik | `github.com/prometheus/client_golang` | **v1.24.1** | | [0012](adr/0012-metrik-ve-trace.md) |
| Trace | `go.opentelemetry.io/otel` | **v1.45.0** | | [0012](adr/0012-metrik-ve-trace.md) |
| JWT | `github.com/golang-jwt/jwt/v5` | **v5.3.1** | Yalnızca **gateway**'de. Servisler JWT parse etmez. | — |
| UUID | `github.com/google/uuid` | **v1.6.0** | | — |
| Migration | `github.com/pressly/goose/v3` | **v3.27.3** | Versiyonlanmış, `Down` bloklu, Go'dan gömülebilir. | [0004](adr/0004-migration-araci.md) |
| Test container | `github.com/testcontainers/testcontainers-go` | **v0.44.0** | Yalnızca entegrasyon testinde. | [0011](adr/0011-test-yaklasimi.md) |
| Lint | `golangci-lint` | **v2.12.2** | CI'da zorunlu ([CI-15]). | — |

### Gin yardımcı paketleri (ihtiyaca göre)

| Paket | Sürüm | Nerede |
|---|---|---|
| `github.com/gin-contrib/requestid` | **v1.0.6** | Her serviste ([OBS-04]) |
| `github.com/gin-contrib/cors` | **v1.7.7** | **Yalnızca** doğrudan erişilen servislerde ([SEC-31]) |
| `github.com/gin-contrib/gzip` | **v1.2.6** | **Yalnızca** gateway'de ([PERF-10]) |
| `go.opentelemetry.io/contrib/.../otelgin` | **v1.45.0 hattı** | Trace kuruluysa ([OBS-14]) |

> **Rate limit için paket yok.** `ulule/limiter` en son 2023'te güncellendi — terk edilmiş
> sayılır. Redis destekli sliding window ~40 satırdır ve `go-redis` ile yazılır
> ([RES-04], [VER-07]).

### Kurallar

**[VER-01] ZORUNLU:** `go.mod` içindeki `go` direktifi **1.25.12**'dir. Monorepo ise
`go.work` sürümü, modüllerin en yükseğinden düşük olamaz ve asla düşürülmez.

**[VER-02] ZORUNLU:** Tablodaki sürümler **tam** yazılır (`v1.12.0`), `latest` ya da açık
uçlu aralık kullanılmaz — ne `go.mod`'da ne Docker imajında.
> **Neden:** `latest` bugün çalışan build'i yarın sessizce bozar ve hangi sürümle test
> ettiğini kimse bilemez. Reprodüksiyon imkânsızlaşır.

**[VER-03] ZORUNLU:** Sürüm yükseltmesi **tüm servisler için birlikte** yapılır, tek serviste
denenmez. Yükseltme kendi PR'ıdır; içine özellik değişikliği karıştırılmaz.

**[VER-04] ZORUNLU:** `go.sum` commit'lenir. `GOFLAGS=-mod=readonly` ile build edilir ki
CI sessizce bağımlılık çekmesin.

**[VER-05] YASAK:** Aynı işi yapan ikinci kütüphane. Elenen alternatifler ve gerekçeleri
[adr/](adr/) klasöründedir:
> - HTTP: Fiber / Echo / chi — **yok**, Gin var → [ADR-0001](adr/0001-http-framework.md)
> - Postgres: `lib/pq` / GORM / ent / sqlx — **yok**, pgx var → [ADR-0003](adr/0003-postgres-surucu.md)
> - Log: zap / zerolog / logrus — **yok**, `log/slog` var → [ADR-0005](adr/0005-loglama.md)
> - Config: viper / koanf / envconfig — **yok**, `os.LookupEnv` var → [ADR-0006](adr/0006-konfigurasyon.md)
> - UUID: `gofrs/uuid` — **yok**, `google/uuid` var
> - Test: testify — **yok**, stdlib `testing` var → [ADR-0011](adr/0011-test-yaklasimi.md)

**[VER-06] YASAK:** ORM. Sorgu elle yazılır → [ADR-0003](adr/0003-postgres-surucu.md).

**[VER-07] ÖNERİLEN:** Standart kütüphaneyle ~50 satırda çözülen şey için paket çekme.
Bir bağımlılığın maliyeti: güvenlik yüzeyi + lisans + yükseltme borcu + build süresi.
Bakımı durmuş paket (son sürüm > 12 ay) **hiç** çekilmez.

**[VER-08] ZORUNLU:** Config okuma `os.LookupEnv` ile elle yapılır → [ADR-0006](adr/0006-konfigurasyon.md).

**[VER-09] ZORUNLU:** Girdi doğrulama handler'da elle yapılır; `binding:"..."` tag'leri
kullanılmaz → [ADR-0007](adr/0007-girdi-dogrulama.md).
> **Not:** `go-playground/validator`, Gin'in **transitif bağımlılığıdır** — yani zaten
> bağımlılık ağacındadır. Onu kullanmama kararı "fazladan paket" gerekçesine değil,
> pointer/üç-durum tasarımıyla çeliştiği gerekçesine dayanır ([API-06], [API-11]).

---

## 2. Docker imajları

**[VER-10] ZORUNLU:** İmajlar aşağıdaki tag'lerle pinlenir. `latest` **yasaktır**.

| Amaç | İmaj | Not |
|---|---|---|
| Go builder | `golang:1.25-alpine` | Multi-stage build'in ilk aşaması |
| Runtime | `alpine:3.24` | Non-root çalışır ([OPS-03]) |
| Postgres (düz) | `postgres:18.4-alpine` | |
| Postgres (GIS) | `postgis/postgis:18-3.6` | Yalnızca geometri verisi varsa |
| Cache (Valkey) | `valkey/valkey:9.1.1-alpine` | Redis protokolü; `go-redis` aynen çalışır. BSD-3 lisans — bkz. [ADR-0009](adr/0009-cache-motoru.md) |
| Kafka | `apache/kafka:4.3.1` | KRaft modu; ZooKeeper **yok** |
| Temporal | `temporalio/server:1.31.2` | |
| Prometheus | `prom/prometheus:v3.13.2` | |
| Grafana | `grafana/grafana:13.1.3` | |

> **Not:** `postgres:18.4` Mayıs 2026 çıkışlıdır; Postgres minor sürümleri Şubat/Mayıs/
> Ağustos/Kasım'da çıkar. Üç aylık gözden geçirmede minor'ü yükselt — minor sürümler
> güvenlik yamasıdır, atlanmaz.

**[VER-11] ÖNERİLEN:** Kritik ortamlarda imajı digest ile pinle:
`postgres:18.4-alpine@sha256:...`. Tag yeniden yazılabilir, digest yazılamaz.

**[VER-12] ZORUNLU:** Bir altyapı bileşeni (Postgres, Valkey, Kafka) **tüm projede tek
sürümdedir**. Bir servis Valkey 8, diğeri Valkey 9 kullanamaz.

---

## 3. `go.mod` şablonu

```go
module <isim>-service

go 1.25.12

require (
	github.com/gin-contrib/requestid v1.0.6
	github.com/gin-gonic/gin v1.12.0
	github.com/google/uuid v1.6.0
	github.com/jackc/pgx/v5 v5.10.0
	github.com/pressly/goose/v3 v3.27.3
	github.com/prometheus/client_golang v1.24.1
)
```

İhtiyaca göre eklenenler (hepsi birden değil, **gerçekten kullanılan**):

```go
	github.com/redis/go-redis/v9 v9.22.0        // cache/kilit varsa (Valkey'e bağlanır)
	github.com/twmb/franz-go v1.21.6            // event üretiyor/tüketiyorsa
	go.temporal.io/sdk v1.47.0                  // workflow varsa
	go.opentelemetry.io/otel v1.45.0            // trace varsa
	github.com/gin-contrib/cors v1.7.7          // SADECE doğrudan erişilen serviste
```

**[VER-13] YASAK:** Kullanılmayan bağımlılığı `go.mod`'da bırakmak. `go mod tidy` her
PR'da koşar ([CI-15]).

---

## 4. Tabloda olmayan bir şey lazımsa

Sırayla:

1. **Gerçekten lazım mı?** Standart kütüphane çözüyor mu, mevcut bağımlılıklardan biri
   zaten yapıyor mu?
2. **Sürümünü doğrula.** Hafızandan yazma — resmî release sayfasından bugünkü stabil
   sürümü teyit et. Son sürüm 12 aydan eskiyse terk edilmiş kabul et ([VER-07]).
3. **Lisansını kontrol et.** MIT / BSD / Apache-2.0 serbest. GPL/AGPL **onay gerektirir**.
4. **Onay al.** Proje sahibine sor. Onaysız bağımlılık eklenmiş PR reddedilir.
5. **Karar kaydı yaz.** `adr/` altına yeni bir dosya aç: alternatifler, güçlü/zayıf
   yanlar, neden bu, kararı ne değiştirir. Sonra bu tabloya işle.

---

## 5. Yükseltme prosedürü

**[VER-14] ZORUNLU:** Yükseltme adımları:

```bash
# 1. Ne değişecek, önce gör
go list -m -u all

# 2. Tek bağımlılık, tek PR
go get github.com/gin-gonic/gin@v1.13.0
go mod tidy

# 3. Doğrula
go build ./...
go test -race ./...
golangci-lint run

# 4. Compose ile ayağa kaldır, /health ve bir CRUD akışını elle dene
```

**[VER-15] ZORUNLU:** Major sürüm atlaması (v1 → v2) onay gerektirir — önce konuşulur,
sonra yapılır. Kararı değiştiren şey varsa ilgili ADR güncellenir.

**[VER-16] ZORUNLU:** Güvenlik açığı bildirilen bir bağımlılık **beklemeden** yükseltilir.
CI'da `govulncheck` koşar ([CI-15]); bulgu varsa build kırmızıdır.

---

## 5b. Bağımlılık güncelliği — tavsiye, zorlama değil

**[VER-21] ÖNERİLEN:** `arac/surum-onerisi.sh` düzenli olarak (aylık, ya da bağımlılık
dokunulan her PR'da) koşar ve upstream'de yeni sürümü olan bağımlılıkları listeler. Araç
**hiçbir zaman FAIL vermez**; çıkış kodu her koşumda 0'dır.
> **Neden:** İki farklı soru vardır ve karıştırılırsa ikisi de işe yaramaz hâle gelir.
> [VER-01] "bu servis standardın tablosuna uyuyor mu" diye sorar ve uymuyorsa **build'i
> kırar**. Bu kural ise "upstream'de daha yenisi var mı" diye sorar; buna evet demek bir
> ihlal değildir, bir bilgidir. Yeni sürüm çıktı diye pipeline kırmak, ekibi aracı kapatmaya
> iter ve sonunda hiçbir şey güncellenmez.

**[VER-22] ZORUNLU:** Major sürüm atlamaları tek tek yapılır ve ilgili ADR'nin "Kararı ne
değiştirir" bölümü kontrol edilir ([VER-08] ile aynı çizgi). Araç, major atlamalarını ayrı
grupta gösterir.

**Ölçüm (2026-09-08, referans depo):** 47 servisin `go` direktifi şöyle dağılmış: **35**
servis `1.23.6`, **10** servis `1.24.0`, **2** servis `1.23.0`. Standart `1.25.12` diyor.
Yani tek bir servis bile uymuyor ve aralarında da üç farklı sürüm var. [VER-01] bunu
yakalar ve build'i kırar; [VER-21] ise yükseltmenin nereye kadar mümkün olduğunu söyler.
Sürüm sürüklenmesi kendi kendine olmaz, kimse bakmadığı için olur.

Aynı koşumda ikinci bir bulgu çıktı: 47 modülün **9'u sorgulanamadı**, sebebi
`missing go.sum entry for go.mod file`. Yani o servislerin `go.sum` dosyası eksik ve
[VER-04] ihlal ediliyor. Aracın bunu "düzeltmemesi" bilinçlidir: `-mod=mod` ile koşsaydı
eksik girdileri sessizce yazar, senin `go.mod`/`go.sum` dosyalarını bir rapor komutu
değiştirmiş olurdu. Araç `-mod=readonly` ile koşar ve eksikliği **bildirir**.
> **Kural olarak:** rapor üreten hiçbir araç, raporladığı deponun kaynak dosyalarını
> değiştirmez ([ARAC-01] ile aynı çizgi). Denetim ile düzeltme ayrı komutlardır.

---

## 6. Mevcut projelerle ilişki

**[VER-17] ZORUNLU — Bundan sonra yazılan HER servis Gin ile yazılır.** İstisna yok.
Yeni proje, yeni repo, ya da mevcut bir repoya eklenen yeni servis — hepsi Gin.
Fiber ile yeni servis açmak **yasaktır**.

**[VER-18] ZORUNLU — Mevcut çalışan servisler kendiliğinden taşınmaz.** Çalışan koda
"standarda uysun diye" dokunulmaz ([GEN-00d]). Eski Fiber servisleri yerinde kalır ve
çalışmaya devam eder; sadece **yeni kod** Gin ile gelir.

Bu, kasıtlı olarak geçiş dönemi kabul eden bir karardır: repo bir süre karışık kalır
(eski servisler Fiber, yeni servisler Gin). Kabul edilen maliyet ve karşı önlemler:

| Maliyet | Karşı önlem |
|---|---|
| İki framework'ün middleware'i farklı | Her servis kendi middleware'ini taşır; ortak `pkg/` **framework'ten bağımsız** tutulur (logger, response gövdesi, validator) |
| Kopyala-yapıştır yanlış servisten yapılabilir | Yeni servis **her zaman** [03](03-PROJE-YAPISI.md)'teki Gin iskeletinden başlar, komşu servisten değil |
| `go.work` iki framework'ü birden taşır | Sorun değil; modüller bağımsız |

**[VER-19] ÖNERİLEN — Mevcut servisleri fırsat buldukça taşı.** Bir Fiber servisinde
zaten kapsamlı bir değişiklik yapılıyorsa (yeni modül, büyük refactor), o servisi Gin'e
çevirmek için doğru an odur. Toplu migrasyon projesi **gerekmiyor**; servis servis,
dokunulduğu zaman.

**[VER-20] ZORUNLU:** Taşınmamış servislerde bu standardın **framework'ten bağımsız**
kuralları yine de geçerlidir: API sözleşmesi (04), güvenlik (05), veritabanı (07),
test (12), gözlemlenebilirlik (10). Sadece HTTP katmanı sözdizimi farklıdır.

> **Somut örnek — Arnavutköy mikroservis repo'su:** 34 servis Fiber v2.52.8 + `lib/pq`
> ile yazılmış durumda. Bu servisler yerinde kalır ama **oraya eklenecek 35. servis Gin
> ile yazılır.** Mevcut olanlar, üzerlerinde ciddi bir iş yapıldıkça tek tek taşınır.

---

## Kaynaklar (2026-08-12 itibarıyla doğrulandı)

- [Go Release History](https://go.dev/doc/devel/release) — 1.26.5 / 1.25.12, 7 Tem 2026
- [Gin releases](https://github.com/gin-gonic/gin/releases) — v1.12.0, 28 Şub 2026 · [go.mod](https://github.com/gin-gonic/gin/blob/master/go.mod) — `go 1.25.0`
- [gin-contrib/requestid](https://github.com/gin-contrib/requestid/releases) v1.0.6 · [cors](https://github.com/gin-contrib/cors/releases) v1.7.7 · [gzip](https://github.com/gin-contrib/gzip/releases) v1.2.6
- [pgx](https://github.com/jackc/pgx) — v5.10.0
- [go-redis](https://pkg.go.dev/github.com/redis/go-redis/v9) — v9.22.0, 3 Ağu 2026
- [franz-go](https://github.com/twmb/franz-go) — v1.21.6
- [Temporal Go SDK](https://github.com/temporalio/sdk-go/releases) — v1.47.0, 28 Tem 2026
- [Temporal Server](https://github.com/temporalio/temporal/releases) — v1.31.2, 8 Tem 2026
- [OpenTelemetry Go](https://github.com/open-telemetry/opentelemetry-go/releases) — v1.45.0, 3 Ağu 2026 · [contrib](https://github.com/open-telemetry/opentelemetry-go-contrib/releases) — v1.45.0, 4 Ağu 2026
- [prometheus/client_golang](https://github.com/prometheus/client_golang/releases) — v1.24.1
- [Prometheus](https://github.com/prometheus/prometheus/releases) — v3.13.2 · [Grafana](https://github.com/grafana/grafana/releases) — v13.1.3
- [goose](https://github.com/pressly/goose/releases) — v3.27.3 · [testcontainers-go](https://github.com/testcontainers/testcontainers-go/releases) — v0.44.0
- [golangci-lint](https://github.com/golangci/golangci-lint/releases) — v2.12.2 · [golang-jwt](https://github.com/golang-jwt/jwt/releases) — v5.3.1
- [Apache Kafka Downloads](https://kafka.apache.org/community/downloads/) — 4.3.1 · [Alpine](https://alpinelinux.org/releases/) — 3.24.1
- [PostgreSQL Versioning](https://www.postgresql.org/support/versioning/) · [postgis/postgis](https://hub.docker.com/r/postgis/postgis)
- [Valkey releases](https://github.com/valkey-io/valkey/releases) — 9.1.1, 21 Tem 2026 · [valkey/valkey imajı](https://hub.docker.com/r/valkey/valkey/)
