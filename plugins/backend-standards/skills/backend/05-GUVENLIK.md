# 05 — Güvenlik

> Temel ilke: **her katman kendi savunmasını yapar.** "Gateway zaten kontrol ediyor" bir
> güvenlik gerekçesi değildir; gateway'i atlayan tek bir yol bulunduğunda tüm sistem açılır.

---

## 1. Güvenlik sınırları

```
  Tarayıcı / mobil
        │  HTTPS, JWT
  ┌─────▼──────────────────────────────────────────┐
  │  API GATEWAY  (tek dış kapı)                   │
  │  · TLS sonlandırma      · JWT doğrulama        │
  │  · Rate limit           · CORS                 │
  │  · X-User-* header'larını SIFIRLAR ve kendisi  │
  │    doğrulanmış değerlerle YENİDEN yazar        │
  └─────┬──────────────────────────────────────────┘
        │  iç ağ · X-Gateway-Source + X-API-Key + X-User-Permissions
  ┌─────▼──────────┐  ┌────────────────┐  ┌────────────────┐
  │  service A     │  │  service B     │  │  service C     │
  │  kendi kontrol │  │  kendi kontrol │  │  kendi kontrol │
  └────────────────┘  └────────────────┘  └────────────────┘
```

**[SEC-01] ZORUNLU:** Servisler dış dünyaya port açmaz. Compose'da `ports:` değil `expose:`
kullanılır; tek `ports:` açan bileşen gateway'dir.

**[SEC-02] ZORUNLU:** TLS gateway'de (ya da önündeki reverse proxy'de) sonlanır. İç ağ
trafiği düz HTTP olabilir; ancak iç ağ **güvenilir sayılmaz** ([SEC-04]).

**[SEC-03] ZORUNLU:** JWT'yi **yalnızca gateway** parse ve doğrular. Servisler JWT
kütüphanesi bile import etmez.
> **Neden:** JWT doğrulaması 30 yerde tekrarlanırsa, biri `alg=none` kontrolünü ya da
> expiry kontrolünü atlar. Tek yerde, iyi test edilmiş şekilde durur.

---

## 2. Servis tarafı kimlik ve yetki

**[SEC-04] ZORUNLU:** Servis, gateway'i varsayar ama gateway'e **güvenmez**. Her istekte
kendi kontrolünü yapar:

```go
func GatewayAuth(cfg *config.Config) gin.HandlerFunc {
	return func(c *gin.Context) {
		if c.GetHeader("X-Gateway-Source") != "api-gateway" {
			// AbortWithStatusJSON: zincir DURMALI. Düz c.JSON yazarsan handler yine çalışır.
			c.AbortWithStatusJSON(http.StatusForbidden,
				pkg.ErrorBody("erişim reddedildi: istekler yalnızca gateway üzerinden kabul edilir"))
			return
		}
		// Sır boşsa kontrolü ATLAMA — üretimde boş sır "kapı açık" demektir.
		if cfg.APISecurityKey == "" {
			pkg.Log.Error("API_SECURITY_KEY tanımsız, istek reddedildi")
			c.AbortWithStatusJSON(http.StatusUnauthorized,
				pkg.ErrorBody("servis yapılandırması eksik"))
			return
		}
		// Sabit zamanlı karşılaştırma: uzunluk/erken çıkış zamanlaması sızdırmasın.
		if subtle.ConstantTimeCompare(
			[]byte(c.GetHeader("X-API-Key")), []byte(cfg.APISecurityKey)) != 1 {
			c.AbortWithStatusJSON(http.StatusUnauthorized,
				pkg.ErrorBody("erişim reddedildi: geçersiz API anahtarı"))
			return
		}
		c.Next()
	}
}
```

> **Dikkat — sık yapılan hata:** `if cfg.APISecurityKey != "" && c.Get(...) != key`.
> Bu yazım, env unutulduğunda kontrolü **tamamen kapatır** ve hiçbir uyarı vermez.
> Kontrol atlanacaksa bu bilinçli ve loglanmış olmalı.

**[SEC-05] ZORUNLU:** Yetki kontrolü `X-User-Permissions` header'ından yapılır ve her
endpoint bir yetki ister ([GEN-10]):

```go
p.POST("", middleware.RequirePermission("parking.create"), h.Create)
```

**[SEC-06] ZORUNLU:** Yetki anahtarı formatı `<modul>.<eylem>`, snake_case, **tekil**
modül adı: `parking.view`, `market_stall.create`. Servisteki string ile yetki tanımındaki
string **birebir** aynıdır.

**[SEC-07] ZORUNLU:** Wildcard desteği: `*` = her şey (superadmin), `modul.*` = o modülün
tümü. Wildcard **modül sınırını aşmaz** — `a_modul.*` ile `b_modul` uçlarına erişilemez.
Bu, testle doğrulanır ([TEST-04]).

**[SEC-08] YASAK:** Fail-open. Yetki kaynağı (Redis, yetki servisi, DB) düştüğünde erişim
**daralır**:
```go
// YANLIŞ — bağımlılık düşünce herkes admin olur
perms, err := fetchPermissions(ctx, userID)
if err != nil { return c.Next() }

// DOĞRU — bilinmiyorsa reddet
perms, err := fetchPermissions(ctx, userID)
if err != nil {
	pkg.Log.Error("yetki alınamadı, istek reddedildi", "err", err)
	c.AbortWithStatusJSON(http.StatusServiceUnavailable, pkg.ErrorBody("yetki doğrulanamadı"))
	return
}
```

**[SEC-09] ZORUNLU:** Her yetki reddi yapısal loglanır: `reason`, `required`, `user_id`,
`path`, `method`, `request_id`. Reddedilen istek sayısı bir metriktir ([OBS-13]) —
ani artış ya saldırıdır ya da bozuk bir deploy.

**[SEC-10] ZORUNLU:** Gateway, istemciden gelen `X-User-*` ve `X-Gateway-*` header'larını
**siler** ve kendi doğrulanmış değerleriyle yeniden yazar.
> **Neden:** Aksi hâlde istemci `X-User-Permissions: *` göndererek superadmin olur.
> Bu, bu mimarideki en kritik tek noktadır; gateway'de testi zorunludur.

**[SEC-11] ÖNERİLEN:** Kayıt sahipliği (ownership) kontrolü yetkiden **ayrıdır**.
`parking.update` yetkisi olan kullanıcı **başkasının** kaydını güncelleyememelidir;
sorgu `WHERE id = $1 AND owner_id = $2` ile daraltılır.
> **Neden:** Rol tabanlı yetki "bu tür kaydı güncelleyebilir" der, "bu kaydı" demez.
> IDOR açıklarının çoğu tam bu boşluktan çıkar.

---

## 3. Girdi doğrulama

**[SEC-12] ZORUNLU:** Doğrulama handler'da, ortak yardımcılarla elle yapılır
(`pkg/validator.go`). Validation kütüphanesi kullanılmaz ([VER-05]).

**Her yazma ucunda doğrulanacak minimum liste:**

| Kontrol | Neden |
|---|---|
| Zorunlu string boş/whitespace mi | `"   "` boş sayılmazsa DB'ye anlamsız kayıt girer |
| UUID parametresi geçerli mi | Uydurma id doğrudan Postgres'e giderse **500** üretir; oysa istemci hatası |
| Sayısal alan negatif mi | Negatif kapasite/tutar iş kuralını sessizce bozar |
| Metin `VARCHAR(n)` sınırını aşıyor mu | Aşarsa sürücü hatası → **500**; oysa **400** olmalı |
| Enum/sort alanı beyaz listede mi | Aksi hâlde injection ve beklenmeyen dallanma |
| Query parametresi geçerli UTF-8 mi | Latin-5 gönderen istemci Postgres'i 500'e düşürür |
| Mantıksal tutarlılık | `occupied > total`, `end_date < start_date` gibi |
| Koordinat sınırda mı, `(0,0)` değil mi | Bkz. [EK-GIS-POSTGIS.md](EK-GIS-POSTGIS.md) |

```go
// Şemadaki VARCHAR sınırları — migration dosyasıyla AYNI tutulmalıdır.
const (
	maxNameLen         = 255
	maxNeighborhoodLen = 100
)

func maxLen(c *gin.Context, field string, value *string, limit int) (handled bool) {
	// []rune: "ğüşiöç" içeren metinde byte uzunluğu yanıltır ve geçerli girdi reddedilir.
	if value != nil && len([]rune(*value)) > limit {
		badRequest(c, field+" en fazla "+strconv.Itoa(limit)+" karakter olabilir")
		return true
	}
	return false
}
```

**[SEC-12b] YASAK:** Doğrulama için `binding:"required,max=255"` gibi struct tag'leri
kullanmak.
> **Neden:** `go-playground/validator` Gin ile birlikte zaten gelir, yani mesele fazladan
> bağımlılık değil. Mesele şu: `required`, **değer tipinde sıfır değeri "eksik" sayar** —
> yani `latitude: 0` ile "latitude gönderilmedi" aynı muameleyi görür. Bu, standardın
> pointer/üç-durum tasarımının ([API-06], [API-07], [API-11]) tam tersidir. Ayrıntı:
> [adr/0007-girdi-dogrulama.md](adr/0007-girdi-dogrulama.md).

**[SEC-13] ZORUNLU:** Uzunluk sınırı **iki katmanda** durur: handler'da açık kontrol
(1. katman) ve şemada `VARCHAR(n)` + sürücü hata çevirimi (2. katman). Biri kaçarsa
diğeri yakalar.

**[SEC-14] ZORUNLU:** Doğrulama **reddedilen isteğin service katmanına ulaşmadığını**
garanti eder. Testte stub'a `reached bool` konur ve bu doğrulanır ([TEST-06]).

---

## 4. SQL ve enjeksiyon

**[SEC-15] ZORUNLU:** Değer **her zaman** parametre olarak geçer.

```go
// DOĞRU — sadece $1/$2 NUMARASI hesaplanıyor, değer parametre
query := fmt.Sprintf(`SELECT %s FROM parkings %s ORDER BY name, id LIMIT $%d OFFSET $%d`,
	parkingColumns, where, len(args)+1, len(args)+2)
rows, err := r.pool.Query(ctx, query, append(args, limit, offset)...)

// YASAK — asla
query := fmt.Sprintf(`SELECT * FROM parkings WHERE name = '%s'`, userInput)
```

**[SEC-16] ZORUNLU:** Dinamik kolon/tablo adı **beyaz listeden** gelir, istemciden değil
([API-26]). Parametre yalnızca değer yerine geçer; kolon adı parametreleştirilemez.

**[SEC-17] YASAK:** Ham sürücü hatasını istemciye döndürmek — tablo, kolon ve constraint
adları sızar ve saldırgana şema haritası verir. Çevirim tablosu:
[07-VERITABANI.md](07-VERITABANI.md).

---

## 5. Sır yönetimi

**[SEC-18] YASAK:** Sır koda, Dockerfile'a, `docker-compose.yml`'a ya da git'e girer.
Compose yalnızca **değişken adını** bilir:
```yaml
environment:
  DB_PASSWORD: ${DB_PASSWORD}     # değer yok, referans var
```

**[SEC-19] YASAK:** `getEnv("DB_PASSWORD", "Secret123")` — varsayılan asla gerçek sır olmaz.
Sır alanlarının varsayılanı boş string'tir.

**[SEC-20] ZORUNLU:** `.gitignore` içinde `.env`, `.env.local`, `.env.prod`, `*.pem`,
`*.key` bulunur. Repoda `.gitignore` yoksa **ilk iş** onu oluşturmaktır.

**[SEC-21] ZORUNLU:** `.env.example` git'e girer: değişken adları var, değerler placeholder.
Yeni geliştirici hangi env'lerin gerektiğini buradan öğrenir.

**[SEC-22] ZORUNLU:** Sır git'e girdiyse **rotasyona** git. Commit'i geri almak yetmez —
git geçmişinde ve muhtemelen birkaç klonda durmaya devam eder. Sırrı değiştir.

**[SEC-23] ÖNERİLEN:** Üretimde sır yönetimi için Docker secrets / Vault / cloud secret
manager kullan. Env değişkeni `docker inspect` ve process listesinde görünebilir.

**[SEC-24] ZORUNLU:** Servisler arası paylaşılan `API_SECURITY_KEY` en az 32 rastgele
bayttır ve ortamlar arası **farklıdır** (dev ≠ staging ≠ prod).

---

## 6. Loglama ve veri sızıntısı

**[SEC-25] YASAK:** Şifre, token, API anahtarı, JWT, kredi kartı, TC kimlik no, tam
e-posta/telefon loglamak.

**[SEC-26] YASAK:** Config veya request struct'ını `%+v` / `%#v` ile loglamak — içindeki
sırrı da basar.

**[SEC-27] ZORUNLU:** Kişisel veri loglanacaksa maskele: `user_id` (UUID) logla, e-posta
loglama. Zorunluysa `a***@example.com` biçiminde.

**[SEC-28] ZORUNLU:** Hata logu **tam**, hata yanıtı **maskeli** olur. İkisini karıştırma:
```go
pkg.Log.Error("sorgu başarısız", "table", "parkings", "err", err)   // log: tam
return c.Status(500).JSON(pkg.ErrorBody("işlem tamamlanamadı"))     // yanıt: maskeli
```

---

## 7. HTTP güvenlik başlıkları

**[SEC-29] ZORUNLU:** Gateway şu başlıkları ekler:

| Başlık | Değer | Ne için |
|---|---|---|
| `Strict-Transport-Security` | `max-age=31536000; includeSubDomains` | HTTP'ye düşürme saldırısı |
| `X-Content-Type-Options` | `nosniff` | MIME sniffing |
| `X-Frame-Options` | `DENY` | Clickjacking |
| `Referrer-Policy` | `strict-origin-when-cross-origin` | URL sızıntısı |
| `Content-Security-Policy` | API için `default-src 'none'` | JSON yanıtta script çalışmasın |

**[SEC-30] YASAK:** Sunucu/framework sürümünü açığa vuran başlıklar. Go'nun `net/http`'i
`Server` başlığı üretmez; elle **ekleme**. Gateway'de upstream'den gelen `Server` ve
`X-Powered-By` başlıkları silinir.

---

## 8. CORS — kime ait?

CORS bir **tarayıcı** mekanizmasıdır: yalnızca tarayıcının **doğrudan** konuştuğu adreste
anlamlıdır. Soru "servis CORS yapmalı mı" değil, **"bu servisi tarayıcı doğrudan mı
çağırıyor"**dur.

| | Gateway arkasındaki servis (varsayılan) | Doğrudan erişilen servis (istisna) |
|---|---|---|
| Örnek | Tüm iş servisleri | Tile/statik servisleri, CDN benzeri uçlar |
| Tarayıcı doğrudan çağırır mı? | **Hayır** | **Evet** |
| **CORS** | **YOK** — gateway yapar | **VAR** — origin'i kendi belirler |
| **GatewayAuth** | **VAR** | **YOK** — istek gateway'den gelmiyor ki |

**[SEC-31] YASAK:** Gateway arkasındaki servise CORS middleware'i koymak.
> **Neden:** Tarayıcı servisin adresini hiç görmez; ürettiği `access-control-*` başlıkları
> tarayıcıya ulaşmaz. Ölü kod üretir ve "burada bir güvenlik kontrolü var" yanılsaması yaratır.
> Middleware, env değişkeni ve config alanı **tek bir kararın parçasıdır** — yarısını
> bırakmak da ölü koddur.

**[SEC-32] YASAK:** Doğrudan erişilen servise `GatewayAuth` koymak — hiçbir istek geçmez,
çünkü istek gerçekten gateway'den gelmiyordur. Bu servisler ağ düzeyinde (IP kısıtı,
reverse proxy) veya kendi token'ıyla korunur.

**[SEC-33] YASAK:** `AllowOrigins: "*"` ile `AllowCredentials: true` birlikte. Bu kombinasyon
zaten geçersizdir; açık origin listesi kullan (`gin-contrib/cors` → `AllowOrigins []string`).

---

## 9. Bağımlılık ve tedarik zinciri güvenliği

**[SEC-34] ZORUNLU:** CI'da `govulncheck ./...` koşar; bilinen açık varsa build kırmızıdır
([CI-15]).

**[SEC-35] ZORUNLU:** `go.sum` commit'lenir ve `-mod=readonly` ile build edilir.

**[SEC-36] ZORUNLU:** Docker imajları pinlenir ([VER-09]); `latest` kullanılmaz. Base imaj
düzenli güncellenir — çoğu konteyner açığı base imajın eski paketlerinden gelir.

**[SEC-37] ÖNERİLEN:** İmaj taraması (Trivy/Grype) CI'da koşar; HIGH/CRITICAL bulgular
merge'ü engeller.

---

## 10. ASLA YAPMA — güvenlik

- ❌ Yetki kontrolü olmadan endpoint açmak
- ❌ Fail-open yetki mantığı
- ❌ İstemciden gelen `X-User-*` header'ına güvenmek
- ❌ `fmt.Sprintf` ile SQL değeri birleştirmek
- ❌ Ham sürücü hatasını istemciye döndürmek
- ❌ Hata mesajında iç servis URL'i, port, stack trace
- ❌ Sırrı koda / Dockerfile'a / compose'a / git'e koymak
- ❌ Şifre, token, kişisel veri loglamak
- ❌ Gateway arkasındaki servise CORS, tile servisine GatewayAuth koymak
- ❌ `AllowOrigins: "*"` + `AllowCredentials: true`
- ❌ Ardışık int PK (IDOR)
- ❌ Sır boşken kontrolü sessizce atlamak
- ❌ Sahiplik kontrolünü rol yetkisiyle karıştırmak
