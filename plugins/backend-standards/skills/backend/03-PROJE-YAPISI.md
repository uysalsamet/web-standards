# 03 — Proje ve Servis Yapısı

> Clean Architecture. Amaç: iş kurallarını altyapı detaylarından ayırmak, DB'siz test
> yazabilmek, bir dosyayı açan kişinin ne bulacağını bilmesi.
> Kod örnekleri **Gin v1.12** içindir (`*gin.Context`, `http.Server` ile açık timeout'lar).

---

## 1. Repo yapısı

```
<proje>/
├── deployments/
│   ├── docker-compose.yml            # tüm ekosistem
│   ├── database-compose.yml          # ağır bağımlılıklar ayrı dosyada
│   ├── .env.example                  # değişken ADLARI, değer YOK — git'e girer
│   ├── .env.local / .env.prod        # gerçek değerler — git'e GİRMEZ
│   └── .env                          # yalnızca COMPOSE_PROJECT_NAME
├── docs/
│   ├── README.md                     # sistemin ne yaptığı, servis haritası, port listesi
│   └── <proje>.postman_collection.json
├── services/
│   ├── api-gateway/
│   └── <isim>-service/
├── backend-standartlari/             # bu doküman seti
├── go.work
└── go.work.sum
```

**[YAP-01] ZORUNLU:** Servis adı `<isim>-service` biçimindedir — küçük harf, tire ile.
Go modül adı da aynıdır. `isim` **tekil ve alan adıdır**: `parking-service`, değil
`parkings-service` ya da `ParkingSvc`.

**[YAP-02] ZORUNLU:** Her servis kendi `go.mod`'una sahiptir ve `go.work`'e eklenir.
Eklenmeyen servis IDE'de ve `go build ./...`'te görünmez — sessizce derlenmez.

---

## 2. Servis iç yapısı

```
services/<isim>-service/
├── cmd/
│   └── main.go                       # SADECE wiring
├── deployments/
│   └── Dockerfile
├── docs/
│   ├── README.md                     # servisin ne yaptığı + endpoint listesi
│   ├── ui-integration.md             # frontend nasıl kullanacak
│   └── <Isim>Service.postman_collection.json
├── internal/
│   ├── config/
│   │   └── config.go                 # env okuma. BAŞKA HİÇBİR ŞEY.
│   ├── dto/
│   │   ├── common.go                 # PaginationMeta, ortak tipler
│   │   └── <modul>.go                # modül başına: Response + Request + UpdateRequest
│   ├── handler/
│   │   ├── common.go                 # Health, Ready, recordID, badRequest, writeError, clampPagination
│   │   └── <modul>_handler.go
│   ├── middleware/
│   │   ├── gateway.go                # SetupGlobal + GatewayAuth
│   │   ├── permission.go             # RequirePermission / RequireAny / RequireAll
│   │   └── rbac_log.go               # yetki reddi loglama
│   ├── repository/
│   │   └── postgres/
│   │       ├── pool.go               # pgxpool kurulumu + ayarlar
│   │       ├── errors.go             # PgError kodu → istemci hatası
│   │       ├── <modul>_repository.go # interface + implementasyon
│   │       └── migrations/           # goose: 00001_x.sql, 00002_y.sql
│   ├── routes/
│   │   ├── routes.go                 # tek Setup fonksiyonu
│   │   └── routes_test.go            # routing + RBAC + validation testleri
│   └── service/
│       └── <modul>_service.go        # interface + implementasyon
├── pkg/
│   ├── logger.go                     # slog kurulumu
│   ├── response.go                   # hata/başarı gövdesi
│   └── validator.go                  # ValidateUUID, required, maxLen, nonNegative
├── go.mod
└── go.sum
```

**[YAP-03] ZORUNLU:** İş mantığı `internal/` altındadır. `pkg/` yalnızca gerçekten genel,
alan bilgisi taşımayan yardımcılar içindir.
> **Neden:** `internal/` Go tarafından zorlanır — başka modül import edemez. `pkg/`'ye
> konan iş kuralı, farkında olmadan diğer servislerin bağımlılığı hâline gelir.

**[YAP-04] ZORUNLU:** Bir modül = bir tablo = bir dto + bir repository + bir service +
bir handler dosyası.

**[YAP-05] ZORUNLU:** Tek dosya **500 satırı** geçmez. Geçiyorsa modül bölünür.
> **Neden:** 500 satırlık dosyada değişiklik yapan kişi (ve AI) dosyanın tamamını
> bağlamında tutamaz; ilgisiz yeri bozar. Bu bir stil tercihi değil, hata oranı meselesidir.

**[YAP-06] ZORUNLU:** `repository/postgres/` alt dizini kullanılır, dosyalar `repository/`
altında düz durmaz. İleride Redis/Mongo eklenirse yan yana durur.

---

## 3. Katman sözleşmesi

```
        HTTP isteği
             │
    ┌────────▼────────┐
    │    handler      │  HTTP bilir. Girdi doğrular, status/JSON üretir.
    │                 │  İŞ KURALI YOK. SQL YOK.
    └────────┬────────┘
             │  DTO + context.Context
    ┌────────▼────────┐
    │    service      │  İş kuralını uygular, dönüştürür, sayfalama meta'sını hesaplar.
    │   (interface)   │  gin.Context BİLMEZ. SQL BİLMEZ.
    └────────┬────────┘
             │  DTO / domain tipi
    ┌────────▼────────┐
    │   repository    │  Veri erişimi. Parametreli SQL, scan, hata çevirimi.
    │   (interface)   │  HTTP BİLMEZ. İŞ KURALI BİLMEZ.
    └────────┬────────┘
             │
        Postgres / Redis
```

**[YAP-07] ZORUNLU:** Bağımlılık tek yöne akar. Ters import derleme hatası vermez ama
mimariyi bitirir — code review'da yakalanır.

**[YAP-08] ZORUNLU:** `service` ve `repository` **interface** olarak tanımlanır,
implementasyon unexported olur:

```go
type ParkingService interface {
	List(ctx context.Context, p Page) (*dto.ParkingList, error)
	GetByID(ctx context.Context, id string) (*dto.Parking, error)
	Create(ctx context.Context, req *dto.ParkingRequest) (*dto.Parking, error)
	Update(ctx context.Context, id string, req *dto.ParkingUpdateRequest) (*dto.Parking, error)
	Delete(ctx context.Context, id string) error
}

type parkingService struct{ repo postgres.ParkingRepository }

func NewParkingService(repo postgres.ParkingRepository) ParkingService {
	return &parkingService{repo: repo}
}
```

> **Neden interface:** DB'siz test yazmanın tek yolu. Concrete struct döndüren constructor,
> her testi Postgres'e bağımlı hâle getirir ve test süitini dakikalara çıkarır.

**[YAP-09] ZORUNLU:** Her katman fonksiyonunun **ilk parametresi `context.Context`**'tir.
Tek istisna: hiçbir IO yapmayan saf dönüşüm fonksiyonları.

**[YAP-10] ZORUNLU:** Handler, `*gin.Context`'i alt katmana **geçirmez**; ondan
`c.Request.Context()` çıkarıp onu geçirir.
```go
// DOĞRU — service HTTP'yi bilmez, gerçek istek context'ini alır
result, err := h.svc.Create(c.Request.Context(), &req)

// YASAK — gin.Context'i service'e geçirmek katman ihlalidir
result, err := h.svc.Create(c, &req)
```
> **Neden:** `*gin.Context` bir HTTP taşıma nesnesidir; iptal/timeout bilgisi asıl
> `c.Request.Context()` içindedir. Ayrıca service katmanına geçirilirse service Gin'e
> bağlanır ve DB'siz test edilemez hâle gelir.

---

## 4. `cmd/main.go` — sadece wiring

**Olacak:** logger → config → DB → migration → repo/service/handler kurulumu → router →
routes → listen → graceful shutdown.
**Olmayacak:** SQL, iş kuralı, handler gövdesi, middleware tanımı.

```go
package main

import (
	"context"
	"errors"
	"net/http"
	"os"
	"os/signal"
	"syscall"
	"time"

	"github.com/gin-gonic/gin"

	"<isim>-service/internal/config"
	"<isim>-service/internal/handler"
	"<isim>-service/internal/repository/postgres"
	"<isim>-service/internal/routes"
	"<isim>-service/internal/service"
	"<isim>-service/pkg"
)

// Build sırasında -ldflags ile doldurulur [OPS-01].
var (
	version = "dev"
	commit  = "unknown"
)

func main() {
	log := pkg.InitLogger(os.Getenv("LOG_LEVEL"), "<isim>-service", version)
	cfg := config.Load()

	// Başlangıç işleri için ayrı context: 30 sn'de bağlanamıyorsa ayağa kalkmasın.
	bootCtx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()

	pool, err := postgres.NewPool(bootCtx, cfg)
	if err != nil {
		log.Error("veritabanına bağlanılamadı", "err", err)
		os.Exit(1)
	}
	defer pool.Close()

	// Migration başarısızlığı FATAL: şema yoksa servis zaten çalışamaz [DB-15].
	if err := postgres.Migrate(bootCtx, cfg.DSN()); err != nil {
		log.Error("migration başarısız", "err", err)
		os.Exit(1)
	}

	parkingRepo := postgres.NewParkingRepository(pool)
	parkingSvc := service.NewParkingService(parkingRepo)
	parkingH := handler.NewParkingHandler(parkingSvc)

	// ReleaseMode: debug logları ve renkli çıktı üretimde kapalı.
	gin.SetMode(gin.ReleaseMode)
	// gin.New() — gin.Default() DEĞİL: Default kendi Logger'ını ekler, biz slog kullanıyoruz.
	r := gin.New()
	// c.Done()/c.Err()/c.Value() çağrıları Request.Context()'e devredilsin.
	// Kapalıyken c.Done() nil döner ve iptal sinyali sessizce kaybolur.
	r.ContextWithFallback = true

	routes.Setup(r, cfg, parkingH)

	// Timeout'lar http.Server'da: Gin'in kendi listener yapılandırması yoktur,
	// bu stdlib'in işidir ve iyi ki öyle — ayarlar tek ve bilinen yerde [RES-07].
	srv := &http.Server{
		Addr:              ":" + cfg.ServerPort,
		Handler:           r,
		ReadHeaderTimeout: 5 * time.Second,  // slowloris'e karşı ilk savunma
		ReadTimeout:       15 * time.Second,
		WriteTimeout:      30 * time.Second,
		IdleTimeout:       60 * time.Second,
		MaxHeaderBytes:    1 << 20, // 1 MB
	}

	go func() {
		log.Info("servis dinlemede", "port", cfg.ServerPort, "version", version, "commit", commit)
		// ErrServerClosed normal kapanıştır, hata değildir.
		if err := srv.ListenAndServe(); err != nil && !errors.Is(err, http.ErrServerClosed) {
			log.Error("dinleme başarısız", "err", err)
			os.Exit(1)
		}
	}()

	quit := make(chan os.Signal, 1)
	signal.Notify(quit, os.Interrupt, syscall.SIGTERM)
	<-quit

	log.Info("kapatılıyor, açık istekler bekleniyor")
	// Sıra önemli [RES-20]: önce yeni istek alma kesilir ve açık istekler biter...
	shutdownCtx, shutdownCancel := context.WithTimeout(context.Background(), cfg.ShutdownGrace)
	defer shutdownCancel()
	if err := srv.Shutdown(shutdownCtx); err != nil {
		log.Error("graceful shutdown tamamlanamadı", "err", err)
	}
	// ...ancak ondan SONRA bağımlılıklar kapatılır (defer pool.Close() burada işler).
	log.Info("kapandı")
}
```

**[YAP-11] ZORUNLU:** `main.go` 150 satırı geçmez. Geçiyorsa wiring dışında bir şey yapıyordur.

**[YAP-12] ZORUNLU:** Başlangıç hatalarında `os.Exit(1)`. `panic` ile çıkma — stack trace
gürültüsü teşhisi zorlaştırır, anlamlı mesaj yeterlidir.

**[YAP-13] ZORUNLU:** `gin.New()` kullanılır, `gin.Default()` **kullanılmaz**.
> **Neden:** `gin.Default()` kendi `Logger()` middleware'ini ekler; bizim yapısal slog
> logumuzla ikili log üretir ([OBS-08]). Recovery'yi biz açıkça ekleriz ([RES-18]).

**[YAP-14] ZORUNLU:** `r.ContextWithFallback = true` ayarlanır.
> **Neden:** Kapalıyken `c.Done()` `nil` döner; `select { case <-c.Done(): }` hiçbir zaman
> tetiklenmez ve istemci bağlantıyı kapattığında iş sessizce devam eder ([GEN-17]).

---

## 5. `internal/config/config.go` — sadece env okur

```go
package config

import (
	"fmt"
	"os"
	"strconv"
	"time"
)

type Config struct {
	ServiceName    string
	ServerPort     string
	DBHost         string
	DBPort         string
	DBUser         string
	DBPassword     string
	DBName         string
	DBSSLMode      string
	DBMaxConns     int32
	APISecurityKey string        // gateway ile paylaşılan sır
	LogLevel       string
	ShutdownGrace  time.Duration
}

func Load() *Config {
	return &Config{
		ServiceName:    getEnv("SERVICE_NAME", "<isim>-service"),
		ServerPort:     getEnv("<ISIM>_SERVICE_PORT", "3300"),
		DBHost:         getEnv("DB_HOST", "localhost"),
		DBPort:         getEnv("DB_PORT", "5432"),
		DBUser:         getEnv("DB_USER", "postgres"),
		DBPassword:     getEnv("DB_PASSWORD", ""),   // varsayılan ASLA gerçek sır olmaz
		DBName:         getEnv("DB_NAME", "app_db"),
		DBSSLMode:      getEnv("DB_SSLMODE", "disable"),
		DBMaxConns:     int32(getEnvInt("DB_MAX_CONNS", 10)),
		APISecurityKey: getEnv("API_SECURITY_KEY", ""),
		LogLevel:       getEnv("LOG_LEVEL", "info"),
		ShutdownGrace:  time.Duration(getEnvInt("SHUTDOWN_GRACE_SEC", 20)) * time.Second,
	}
}

// DSN tek kaynaktır. Başka yerde elle DSN kurma: yoksa DB_SSLMODE gibi env'ler
// sessizce etkisiz kalır ve "ayarladım ama olmuyor" saatlerce aranır.
func (c *Config) DSN() string {
	return fmt.Sprintf("postgres://%s:%s@%s:%s/%s?sslmode=%s",
		c.DBUser, c.DBPassword, c.DBHost, c.DBPort, c.DBName, c.DBSSLMode)
}

func getEnv(key, def string) string {
	if v, ok := os.LookupEnv(key); ok {
		return v
	}
	return def
}

func getEnvInt(key string, def int) int {
	if v, ok := os.LookupEnv(key); ok {
		if n, err := strconv.Atoi(v); err == nil {
			return n
		}
		// Bozuk değeri sessizce yutma: yanlış yazılmış env, varsayılana düşerek
		// "ayar geçerli" yanılsaması yaratır.
		panic(fmt.Sprintf("config: %s sayı olmalı, gelen: %q", key, v))
	}
	return def
}
```

**[YAP-15] ZORUNLU:** `config` paketinden DB'ye bağlanılmaz, log yazılmaz, doğrulama
yapılmaz. Sadece env okur.

**[YAP-16] ZORUNLU:** Kod içi varsayılanlar **yalnızca yerel geliştirme** içindir. Sır
alanlarının varsayılanı boş string'tir ve boşsa servis üretimde ayağa kalkmaz:

```go
// Üretimde eksik sır sessizce "kontrol kapalı" demek olmasın.
if cfg.APISecurityKey == "" && os.Getenv("APP_ENV") == "production" {
	log.Error("API_SECURITY_KEY zorunlu"); os.Exit(1)
}
```

**[YAP-17] YASAK:** Config struct'ını `%+v` ile loglamak — şifreyi log'a basar.

---

## 6. `internal/handler/common.go` — ortak yardımcılar

```go
package handler

import (
	"net/http"
	"strconv"

	"github.com/gin-gonic/gin"

	"<isim>-service/pkg"
)

// recordID — :id gerçekten UUID mi? Değilse 400 yazar ve handled=true döner.
// Uydurulmuş bir id doğrudan Postgres'e gidip 500 üretmemeli: bu istemci hatasıdır.
func recordID(c *gin.Context, param string) (id string, handled bool) {
	id, err := pkg.ValidateUUID(c.Param(param))
	if err != nil {
		badRequest(c, "geçersiz kayıt ID'si")
		return "", true
	}
	return id, false
}

// AbortWithStatusJSON: sonraki handler'lar ÇALIŞMASIN. Düz c.JSON yazarsan
// zincir devam eder ve ikinci bir yanıt yazılmaya çalışılır.
func badRequest(c *gin.Context, msg string) {
	c.AbortWithStatusJSON(http.StatusBadRequest, pkg.ErrorBody(msg))
}

// clampPagination — sayfalama kuralının TEK kaynağı. Repository de meta da bunu kullanır.
// Sınır dışı limit KIRPILIR, varsayılana düşmez: düşerse meta ile dönen kayıt sayısı
// ayrışır ve tüm sayfaları gezen istemci eksik veri toplar.
func clampPagination(c *gin.Context) (page, limit, offset int) {
	page, _ = strconv.Atoi(c.DefaultQuery("page", "1"))
	limit, _ = strconv.Atoi(c.DefaultQuery("limit", "50"))
	if page < 1 {
		page = 1
	}
	if limit < 1 {
		limit = 50
	}
	if limit > 200 {
		limit = 200
	}
	return page, limit, (page - 1) * limit
}
```

**[YAP-18] ZORUNLU:** Sayfalama kuralı **tek fonksiyonda** yaşar. Repository ve meta
hesabı aynı fonksiyonu çağırır.
> **Vaka:** Repository "sınır dışıysa varsayılana düş", DTO "sınır dışıysa kırp" diyordu.
> `?limit=500` isteğinde sorgu 50 kayıt döndürüyor ama meta `limit=200, total_pages=7`
> bildiriyordu. `meta`'ya güvenip tüm sayfaları toplayan istemci 1.246 kaydın **dörtte
> birini** görüyor, KPI toplamları o oranda yanlış çıkıyordu.

**[YAP-19] ZORUNLU:** Hata yazarken `c.AbortWithStatusJSON` kullanılır, `c.JSON` değil.
> **Neden:** Gin'de `c.JSON` zinciri durdurmaz; sonraki middleware/handler çalışmaya devam
> eder ve "headers already written" uyarısıyla ikinci yanıt yazılmaya çalışılır.

---

## 7. `internal/routes/routes.go`

```go
func Setup(r *gin.Engine, cfg *config.Config, parkingH *handler.ParkingHandler) {
	middleware.SetupGlobal(r, cfg)   // recover + requestid + slog + metrics + body limit

	// /health ve /ready auth'suz: gateway ve container healthcheck çağırır.
	r.GET("/health", handler.Health)
	r.GET("/ready", handler.Ready)

	// api/v1 prefix'i YOK — platform/versiyon prefix'ini gateway yönetir [API-03].
	// Grup middleware'ini AÇIKÇA alır.
	p := r.Group("/parkings", middleware.GatewayAuth(cfg))
	{
		// Liste ayrı bir yolda DEĞİL, kaynağın kökünde: /parkings?page=&limit= [API-01].
		p.GET("", middleware.RequirePermission("parking.view"), parkingH.List)
		p.GET("/:id", middleware.RequirePermission("parking.view"), parkingH.GetByID)
		p.POST("", middleware.RequirePermission("parking.create"), parkingH.Create)
		p.PUT("/:id", middleware.RequirePermission("parking.update"), parkingH.Update)
		p.DELETE("/:id", middleware.RequirePermission("parking.delete"), parkingH.Delete)
	}
}
```

**[YAP-20] ZORUNLU:** Tek `Setup` fonksiyonu. Route tanımı handler dosyalarına dağıtılmaz —
"bu endpoint'in yetkisi var mı" sorusu tek dosyaya bakarak cevaplanabilmelidir.

**[YAP-21] ZORUNLU:** Liste ucu kaynağın kökündedir (`GET /parkings`), `/parkings/list`
değil. Sabit yol gerekiyorsa (`/export`, `/map`) `/:id` ile **kardeş** olarak tanımlanır ve
statik olan **önce** yazılır.
> **Neden:** Gin'in radix router'ı statik + parametre kardeşliğini v1.7'den beri destekler,
> yani `/parkings/export` ile `/parkings/:id` birlikte çalışır. Ama bu tarihsel olarak
> panik üreten bir alandı ve hâlâ trailing-slash yönlendirmesinde köşe durumları var.
> En sağlam yol, kaynağın kökünü liste için kullanıp belirsizliği hiç yaratmamaktır.
> Ek yarar: `GET /parkings` zaten daha doğru REST'tir.

**[YAP-22] ZORUNLU:** Her grup middleware'ini kendi tanımında açıkça alır. Sıraya duyarlı,
"yukarıda `Use` etmiştim" varsayan kurulumlar yapılmaz — araya route ekleyen bir sonraki
kişi sessizce korumasız bir uç açar.

---

## 8. Yorum yazma kuralı

**[YAP-23] ZORUNLU:** Yorum **"ne yaptığını" değil "neden öyle yaptığını"** anlatır.
Kodun ne yaptığı okununca anlaşılmıyorsa çözüm yorum değil, isim düzeltmektir.

İyi:
```go
// floor_count bilinçli olarak COALESCE'lanmaz: NULL "bilinmiyor" demek, kaynakta
// gerçek 0 değerleri de var ve ikisi karışmamalı.

// (0,0) reddedilir: Null Island Gine Körfezi'ndedir, bizim veri setimizde asla
// geçerli değildir. Kabul edilirse kayıt sessizce haritanın dışına taşınır.
```

Kötü:
```go
// id'yi doğrular
func validateID(id string) error
```

**[YAP-24] ÖNERİLEN:** Bir alternatifi bilinçli olarak seçmediysen bunu yaz. Altı ay sonra
o alternatifi "iyileştirme" diye uygulayacak kişiyi durduran tek şey bu yorumdur.
Büyük kararlarda yorum yerine `adr/` altına karar kaydı yaz.
