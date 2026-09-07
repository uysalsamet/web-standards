# 06 — Rate Limit ve Dayanıklılık

> Bu dosyadaki sayılar **varsayılandır ve bağlayıcıdır.** Değiştiriyorsan ölçüme dayandır
> ve gerekçeyi kod yorumuna/PR'a yaz. Sayısız "rate limit olmalı" cümlesi denetlenemez;
> sayı denetlenebilir.

---

## 1. Rate limit katmanları

Limit **gateway'de** uygulanır. Servisler kendi başlarına genel rate limit yapmaz.

**[RES-01] ZORUNLU — Varsayılan limitler (gateway):**

| Kime | Limit | Pencere | Gerekçe |
|---|---|---|---|
| Anonim (IP başına) | **100 istek** | 1 dk | Basit tarama/scraping'i durdurur, normal kullanıcıyı etkilemez |
| Kimlikli kullanıcı | **1.000 istek** | 1 dk | Ağır bir dashboard bile açılışta ~50–100 istek atar; 10 katı pay var |
| Login / şifre sıfırlama | **5 istek** | 15 dk | Brute force. IP **ve** hesap bazında ayrı sayılır |
| Yazma uçları (POST/PUT/DELETE) | **60 istek** | 1 dk | Yanlışlıkla döngüye giren istemciyi frenler |
| Ağır uçlar (export, rapor, toplu sorgu) | **10 istek** | 1 dk | Tek istek saniyeler sürebilir; korunmazsa DB'yi tüketir |
| Servisler arası (iç ağ) | limit **yok** | — | İç trafik güvenilir; limit koymak kaskad hatayı büyütür |

**[RES-02] ZORUNLU:** 429 yanıtı `Retry-After` header'ı ile döner. İstemci ne zaman
tekrar deneyeceğini bilmezse hemen tekrar dener ve durumu kötüleştirir.

**[RES-03] ZORUNLU:** Kimlikli kullanıcı için limit anahtarı **kullanıcı id'sidir**, IP
değil. NAT arkasındaki 200 kişilik ofis tek IP'den gelir; IP bazlı limit hepsini birden keser.

**[RES-04] ZORUNLU:** Çok örnekli (replica) kurulumda limit sayacı **Redis'te** tutulur.
Bellek içi sayaç, 3 replika ile limiti sessizce 3 katına çıkarır.

```go
// Gin'in yerleşik rate limiter'ı yoktur ve bakımlı bir topluluk paketi de yok
// (ulule/limiter en son 2023'te güncellendi). Redis destekli sabit pencere ~40 satır:
func RateLimit(rdb *redis.Client, max int64, window time.Duration) gin.HandlerFunc {
	return func(c *gin.Context) {
		// Kimlikli kullanıcıyı kendi anahtarıyla say; NAT arkasındaki 200 kişilik ofis
		// tek IP'den geldiği için IP bazlı sayım hepsini birden keser [RES-03].
		key := "rl:ip:" + c.ClientIP()
		if uid := c.GetHeader("X-User-ID"); uid != "" {
			key = "rl:u:" + uid
		}

		ctx, cancel := context.WithTimeout(c.Request.Context(), 500*time.Millisecond)
		defer cancel()

		n, err := rdb.Incr(ctx, key).Result()
		if err != nil {
			// Rate limit bir DOĞRULUK mekanizmasıdır, cache değil: Redis yoksa
			// fail-open yapılmaz [CACHE-10]. Sayamıyorsak isteği kabul etmeyiz.
			pkg.Log.Error("rate limit sayacı okunamadı", "err", err)
			c.AbortWithStatusJSON(http.StatusServiceUnavailable,
				pkg.ErrorBody("servis geçici olarak kullanılamıyor"))
			return
		}
		if n == 1 {
			// TTL yalnızca ilk artışta konur; her istekte konursa pencere hiç dolmaz.
			rdb.Expire(ctx, key, window)
		}
		if n > max {
			c.Header("Retry-After", strconv.Itoa(int(window.Seconds())))
			c.AbortWithStatusJSON(http.StatusTooManyRequests,
				pkg.ErrorBody("çok fazla istek gönderildi, lütfen bekleyin"))
			return
		}
		c.Next()
	}
}
```

> **Not:** Bu sabit pencere (fixed window) uygulamasıdır ve pencere sınırında en kötü
> ihtimalle 2× limite izin verir. Bizim amacımız için (kötüye kullanımı frenlemek) yeterli;
> kesin doğruluk gerekiyorsa sliding window log'a geç.

**[RES-05] ZORUNLU — Gövde boyutu limiti: 4 MB.** Gin'in yapılandırma alanı yoktur;
stdlib ile global middleware olarak konur:
```go
func BodyLimit(max int64) gin.HandlerFunc {
	return func(c *gin.Context) {
		// MaxBytesReader sınırı aşan gövdede okumayı hata ile keser; sınırsız gövde
		// okumak tek istekle belleği tüketmenin en kolay yoludur.
		c.Request.Body = http.MaxBytesReader(c.Writer, c.Request.Body, max)
		c.Next()
	}
}
// r.Use(middleware.BodyLimit(4 << 20))
```
Dosya yükleme ucu varsa o uçta ayrıca ve **açıkça** yükseltilir, genel limit yükseltilmez.

**[RES-06] ZORUNLU:** İstemcinin belirlediği her boyut sınırlıdır: sayfa `limit` ≤ 200
([API-18]), toplu işlem gövdesi ≤ 1.000 kayıt, arama sorgusu ≤ 256 karakter.
> **Neden:** Sınırsız her parametre bir DoS vektörüdür ve saldırgan olmadan da,
> yanlış yazılmış tek bir istemci ile tetiklenir.

---

## 2. Timeout matrisi

**[RES-07] ZORUNLU:** Her ağ çağrısının timeout'u vardır. Varsayılanlar:

| Nerede | Ayar | Değer | Gerekçe |
|---|---|---|---|
| HTTP sunucu | `ReadHeaderTimeout` | **5 sn** | Slowloris'e karşı ilk savunma |
| HTTP sunucu | `ReadTimeout` | **15 sn** | Gövde dâhil tüm isteğin okunma süresi |
| HTTP sunucu | `WriteTimeout` | **30 sn** | En uzun normal yanıttan belirgin fazla |
| HTTP sunucu | `IdleTimeout` | **60 sn** | Keep-alive bağlantısı sonsuz durmasın |
| HTTP istemci (upstream) | `Timeout` | **5 sn** | Kullanıcı bekliyor; 5 sn'den fazlası zaten başarısızdır |
| DB sorgu (okuma) | context | **3 sn** | Bundan uzunsa sorgu ya da index yanlıştır |
| DB sorgu (yazma) | context | **5 sn** | |
| DB bağlantı kurma | context | **5 sn** | |
| Redis | context | **500 ms** | Cache yavaşsa cache olmaktan çıkar; atla, DB'ye git |
| Graceful shutdown | — | **20 sn** | Açık isteklerin bitmesine yeter, deploy'u kilitlemez |

> Sunucu timeout'ları Gin'de değil, `http.Server` struct'ında verilir ([03](03-PROJE-YAPISI.md) §4).
> Gin sadece `Handler`'dır; bu iyi bir şeydir — ayarlar stdlib'in bilinen yerinde durur.

**[RES-08] YASAK:** Timeout'suz `http.Client{}`. Varsayılanı **sonsuzdur** ve upstream
takıldığında tüm goroutine havuzunu sessizce tüketir.

```go
// ZORUNLU: paylaşılan, timeout'lu, havuzlu istemci. Her istekte yeni client YARATMA —
// her biri kendi bağlantı havuzunu açar ve TIME_WAIT birikir.
var httpClient = &http.Client{
	Timeout: 5 * time.Second,
	Transport: &http.Transport{
		MaxIdleConns:        100,
		MaxIdleConnsPerHost: 10,
		IdleConnTimeout:     90 * time.Second,
	},
}
```

**[RES-09] ZORUNLU:** Timeout'lar **aşağı doğru azalır**. Gateway 10 sn bekliyorsa servis
5 sn, DB sorgusu 3 sn beklemeli. Alt katman üstten uzun beklerse üst katman zaten vazgeçmiş
olur ama iş boşuna devam eder.

**[RES-10] ZORUNLU:** `context` uçtan uca taşınır ([GEN-17]). Gin'de kaynak
`c.Request.Context()`'tir ([YAP-10]):
```go
ctx, cancel := context.WithTimeout(c.Request.Context(), 3*time.Second)
defer cancel()
rows, err := r.pool.Query(ctx, sql, args...)
```
> `r.ContextWithFallback = true` ayarlanmışsa `c` de `context.Context` gibi davranır
> ([YAP-14]); yine de alt katmana `c.Request.Context()` geçirilir, `c` değil.

---

## 3. Retry ve backoff

**[RES-11] ZORUNLU:** Yalnızca **geçici** hatalar retry edilir: bağlantı hatası, timeout,
502/503/504, `429` (Retry-After'a uyarak). `400`, `401`, `403`, `404`, `409` **retry edilmez** —
tekrar denemek aynı cevabı verir, sadece yük üretir.

**[RES-12] ZORUNLU:** Retry **yalnızca idempotent** işlemlerde yapılır. `POST` retry
edilecekse `Idempotency-Key` ile korunmuş olmalıdır ([API-25]).

**[RES-13] ZORUNLU:** Retry sayısı **en fazla 3**, üstel backoff + jitter ile:

```go
// Jitter ZORUNLU: sabit backoff'ta tüm istemciler aynı anda uyanır ve upstream'i
// tam toparlanırken tekrar yıkar (thundering herd).
func retryDelay(attempt int) time.Duration {
	base := time.Duration(1<<attempt) * 100 * time.Millisecond // 100ms, 200ms, 400ms
	jitter := time.Duration(rand.Int63n(int64(base / 2)))
	return base + jitter
}
```

**[RES-14] YASAK:** Katmanlı retry. Gateway 3, servis 3, istemci 3 kez denerse upstream'e
**27 istek** gider. Retry **tek katmanda** yapılır — tercihen çağrı zincirinin en dışında.

---

## 4. Circuit breaker

**[RES-15] ÖNERİLEN:** Bir upstream'e yapılan çağrılar sürekli başarısızsa devre açılır ve
bir süre hiç denenmez.

```
kapalı  →  ardışık N hata (varsayılan 5)  →  açık
açık    →  hiç deneme yok, hemen 503      →  30 sn sonra  →  yarı açık
yarı açık → tek deneme başarılı ise kapalı, değilse tekrar açık
```

**[RES-16] ZORUNLU:** Devre açıkken **503** dönülür ve `Retry-After` verilir; istek
kuyruğa alınıp bekletilmez.
> **Neden:** Cevap vermeyen upstream'i beklemek, çağıran serviste goroutine ve bağlantı
> biriktirir. Onun arızası birkaç saniye içinde senin arızan olur (kaskad hata). Hızlı
> başarısız olmak, yavaş başarısız olmaktan iyidir.

**[RES-17] ZORUNLU:** Bir bağımlılık düştüğünde servis **tamamen** düşmez; o bağımlılığa
ihtiyaç duymayan uçlar çalışmaya devam eder. Örnek: Redis düştüyse cache atlanır, DB'ye
gidilir — ama bu **yalnızca cache** için geçerlidir; yetki için değil ([SEC-08]).

---

## 5. Panic, shutdown, sağlık

**[RES-18] ZORUNLU:** `recover` middleware'i her serviste ilk sıradadır:

```go
// gin.New() kullanıldığı için Recovery'yi AÇIKÇA ekliyoruz [YAP-13].
r.Use(gin.CustomRecoveryWithWriter(nil, func(c *gin.Context, recovered any) {
	// Stack trace log'a gider, istemciye ASLA [SEC-28].
	pkg.Log.Error("panic yakalandı",
		"panic", recovered, "path", c.FullPath(), "stack", string(debug.Stack()))
	c.AbortWithStatusJSON(http.StatusInternalServerError,
		pkg.ErrorBody("işlem tamamlanamadı"))
}))
```
> Sade `gin.Recovery()` de kabul edilir; ancak o, panik metnini stdout'a düz metin basar —
> yapısal log standardımızla ([OBS-01]) uyuşmaz.

**[RES-19] ZORUNLU:** Graceful shutdown ([03](03-PROJE-YAPISI.md) §4 örneğindeki gibi): SIGTERM alınınca
yeni istek kabul edilmez, açık istekler 20 sn'ye kadar bitirilir, sonra bağımlılıklar
kapatılır.
> **Neden:** Deploy sırasında konteyner sertçe öldürülürse yarım kalan istek istemciye
> 502 döner ve yazma işlemi yarıda kalmış olabilir.

**[RES-20] ZORUNLU:** Kapanış sırası: **önce** yeni istek almayı kes → **sonra** açık
istekleri bitir → **en son** DB/Redis/Kafka bağlantılarını kapat. Pratikte: `srv.Shutdown(ctx)`
döndükten **sonra** `pool.Close()`. Ters sıra, hâlâ çalışan isteklerin "connection closed"
hatası almasına yol açar.

**[RES-21] ZORUNLU:** Goroutine sızıntısı yok. Başlattığın her goroutine'in bitiş koşulu
olmalı: ya `ctx.Done()` dinler ya `WaitGroup` ile beklenir. Sonsuz `for {}` döngüsü
`select { case <-ctx.Done(): return ... }` içerir.

**[RES-22] ZORUNLU:** Sınırsız goroutine üretmek yasaktır. İstek başına goroutine açan
fan-out'lar `errgroup.SetLimit` ya da worker pool ile sınırlanır.

---

## 6. Backpressure ve aşırı yük

**[RES-23] ZORUNLU:** DB bağlantı havuzu sınırlıdır ([DB-01], [DB-03]). Havuz dolduğunda istek
**kuyrukta context timeout'a kadar** bekler; sonsuz beklemez.

**[RES-24] ZORUNLU:** Kuyruk/worker sistemlerinde tüketici hızı üretici hızından yavaşsa
kuyruk büyür. Kuyruk derinliği bir metriktir ([OBS-12]) ve eşik aşılınca alarm üretir.

**[RES-25] ÖNERİLEN:** Aşırı yükte **yükü at** (load shedding): eşiği aşınca ucuz bir
`503` dön. Herkesi yavaşça yanıltmaktansa bir kısmını hızlıca reddetmek daha iyidir.

**[RES-26] ZORUNLU:** Bir istek zaten iptal edilmişse (`ctx.Err() != nil`) işe devam etme.
Uzun döngülerin başında kontrol et:
```go
for _, item := range items {
	if err := ctx.Err(); err != nil {
		return err   // istemci gitti, boşuna çalışma
	}
	...
}
```

---

## 7. Sağlık uçları

**[RES-27] ZORUNLU:** İki ayrı uç bulunur ve **ikisi de auth'suzdur**:

| Uç | Ne der | Bağımlılık kontrol eder mi |
|---|---|---|
| `/health` (liveness) | "Süreç ayakta" | **Hayır** |
| `/ready` (readiness) | "İstek alabilirim" | **Evet** — DB ping vb. |

```go
func Health(c *gin.Context) {
	// Bağımlılık kontrol ETMEZ: DB düştüğünde orkestratör konteyneri yeniden
	// başlatmamalı — yeniden başlatmak DB'yi düzeltmez, sadece durumu kötüleştirir.
	c.JSON(http.StatusOK, gin.H{"status": "healthy", "service": serviceName})
}

func Ready(pool *pgxpool.Pool) gin.HandlerFunc {
	return func(c *gin.Context) {
		ctx, cancel := context.WithTimeout(c.Request.Context(), 2*time.Second)
		defer cancel()
		if err := pool.Ping(ctx); err != nil {
			c.JSON(http.StatusServiceUnavailable,
				gin.H{"status": "unready", "reason": "database"})
			return
		}
		c.JSON(http.StatusOK, gin.H{"status": "ready"})
	}
}
```

**[RES-28] ZORUNLU:** `/health` yanıt formatı tüm servislerde aynıdır:
`{"status": "healthy", "service": "<servis-adi>"}`. `ok`, `up`, `alive` değil — **`healthy`**.

**[RES-29] YASAK:** `/health` içinde bağımlılık kontrolü yapmak.
> **Neden:** DB kısa süre yanıt vermediğinde liveness başarısız olur, orkestratör tüm
> replikaları yeniden başlatır, cache'ler boşalır ve DB'ye anlık yük biner — kendi
> kendini büyüten arıza.

---

## 8. ASLA YAPMA — dayanıklılık

- ❌ Timeout'suz `http.Server{}` veya `http.Client{}`
- ❌ `context` geçirmeyen çağrı zinciri
- ❌ `recover` middleware'siz servis
- ❌ Graceful shutdown'suz `ListenAndServe`
- ❌ Katmanlı retry (3×3×3 = 27 istek)
- ❌ Jitter'sız sabit backoff
- ❌ Idempotent olmayan işlemi retry etmek
- ❌ `400`/`404` gibi kalıcı hataları retry etmek
- ❌ Bellek içi rate limit sayacını çok replikalı kurulumda kullanmak
- ❌ Sınırsız goroutine / bitiş koşulu olmayan goroutine
- ❌ `/health` içinde DB kontrolü
- ❌ İstemcinin belirlediği sınırsız `limit`, gövde, batch boyutu
- ❌ Hata yutmak (`if err != nil { }`)
