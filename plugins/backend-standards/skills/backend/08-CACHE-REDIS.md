# 08 — Cache (Valkey / Redis protokolü)

> **Motor: Valkey** ([ADR-0009](adr/0009-cache-motoru.md)) — BSD-3 lisanslı, Redis ile
> wire-compatible. İstemci `go-redis`; kod ve komutlar aynıdır. Aşağıda "Redis" geçen
> yerler **Redis protokolünü** kasteder, ürünü değil.
>
> Cache bir **optimizasyondur, doğruluk kaynağı değildir.** Cache'i kapattığında sistem
> yavaşlamalı ama **çalışmaya devam etmelidir**. Bu cümleye uymayan her kullanım hatalıdır.

---

## 1. Ne zaman cache eklenir

**[CACHE-01] ZORUNLU:** Cache **ölçülmeden** eklenmez. Önce yavaş olduğunu göster
(`EXPLAIN`, p95 metriği), sonra index/sorgu düzeltmeyi dene, o da yetmiyorsa cache ekle.
> **Neden:** Cache, doğruluk problemi satın alarak hız satın almaktır. Eksik index yüzünden
> yavaş olan bir sorguyu cache'lemek, sorunu gizler ve bayat veri problemi ekler.

**[CACHE-02] ÖNERİLEN — Cache'e uygun veri:**

| Uygun | Uygun değil |
|---|---|
| Nadiren değişen referans verisi (il/ilçe, kategori, yetki listesi) | Para, stok, rezervasyon gibi tutarlılık kritik veri |
| Hesabı pahalı, sonucu küçük (agregasyon, rapor) | Kullanıcıya özel, tek seferlik veri |
| Yüksek okuma / düşük yazma oranı | Her istekte değişen veri |
| Bayatlığı tolere edilebilir | Bayatlığı yasal/mali sonuç doğuran veri |

**[CACHE-03] ZORUNLU:** Cache'lenen her veri için **kabul edilen bayatlık süresi** yazılır.
"Bu veri en fazla 5 dakika eski olabilir" cevabı yoksa cache eklenmez.

---

## 2. Anahtar tasarımı

**[CACHE-04] ZORUNLU:** Anahtar formatı: `<servis>:<varlık>:<sürüm>:<kimlik>`

```
parking:item:v1:9f3c...          tek kayıt
parking:list:v1:page=1&limit=50  liste (parametreler sıralı ve normalize)
auth:perms:v1:user:9f3c...       kullanıcı yetkileri
```

**[CACHE-05] ZORUNLU:** Anahtara **sürüm** konur (`v1`). Cache'lenen yapının şeması
değiştiğinde sürüm artırılır — eski kayıtlar TTL ile kendiliğinden ölür.
> **Neden:** Sürüm yoksa deploy sonrası eski formatlı kayıtlar yeni kodla parse edilemez
> ve her istekte hata üretir. Alternatif olan "tüm cache'i sil", DB'ye anlık yük bindirir.

**[CACHE-06] ZORUNLU:** Liste anahtarlarında parametreler **normalize** edilir: alfabetik
sıra, varsayılanlar açıkça yazılır. `?limit=50&page=1` ile `?page=1&limit=50` aynı
anahtarı üretmelidir; üretmezse cache isabet oranı yarıya düşer.

**[CACHE-07] ZORUNLU:** Kullanıcıya özel veri anahtarında **kullanıcı kimliği** bulunur.
> **Neden:** Yetkiye göre filtrelenmiş bir listeyi kullanıcısız anahtarla cache'lemek,
> A kullanıcısının verisini B'ye göstermek demektir. Bu bir performans hatası değil,
> **veri sızıntısıdır**.

**[CACHE-08] ZORUNLU:** Her anahtarın TTL'i vardır. TTL'siz `SET` yasaktır.
> **Neden:** TTL'siz anahtar, invalidation'ı unutulduğunda **sonsuza kadar** bayat kalır
> ve Redis belleğini sızdırır. TTL, unutulan invalidation'a karşı son savunmadır.

**Varsayılan TTL'ler:**

| Veri | TTL |
|---|---|
| Referans/sabit liste | 1 saat |
| Kullanıcı yetkileri | 5 dakika |
| Liste/sayfa sonucu | 60 saniye |
| Ağır agregasyon/rapor | 5 dakika |
| Idempotency kaydı | 24 saat |
| Dağıtık kilit | işin süresi × 2, en fazla 30 saniye |

---

## 3. Okuma ve yazma deseni

**[CACHE-09] ZORUNLU — Cache-aside** varsayılan desendir:

```go
func (s *parkingService) GetByID(ctx context.Context, id string) (*dto.Parking, error) {
	key := "parking:item:v1:" + id

	if b, err := s.cache.Get(ctx, key).Bytes(); err == nil {
		var p dto.Parking
		if json.Unmarshal(b, &p) == nil {
			return &p, nil
		}
		// Bozuk kayıt: sil ve DB'den devam et. Cache hatası isteği DÜŞÜRMEZ.
		s.cache.Del(ctx, key)
	} else if !errors.Is(err, redis.Nil) {
		// Redis erişilemiyor: logla ve DB'ye git. Cache opsiyoneldir [CACHE-10].
		pkg.Log.Warn("cache okunamadı", "key", key, "err", err)
	}

	p, err := s.repo.GetByID(ctx, id)
	if err != nil {
		return nil, err
	}
	if b, err := json.Marshal(p); err == nil {
		// Yazma hatası yok sayılır: cache'e yazamamak isteği başarısız yapmaz.
		s.cache.Set(ctx, key, b, 5*time.Minute)
	}
	return p, nil
}
```

**[CACHE-10] ZORUNLU:** Redis hatası isteği **düşürmez**. Cache okunamıyorsa DB'ye gidilir,
yazılamıyorsa yok sayılır.
> **Tek istisna:** Rate limit sayacı ve dağıtık kilit. Bunlar cache değil, **doğruluk
> mekanizmasıdır**; Redis yoksa fail-open olmaz ([SEC-08]) — istek reddedilir.

**[CACHE-11] ZORUNLU:** Redis çağrılarında context timeout **500 ms**'dir ([RES-07]).
Cache, DB'den yavaş olduğu anda cache olmaktan çıkar.

**[CACHE-12] YASAK:** Yazma yolunda cache'e yazıp DB'ye yazmayı ertelemek (write-behind).
Süreç düşerse veri kaybolur ve bunu kimse fark etmez.

---

## 4. Invalidation

> "Bilgisayar bilimlerinde iki zor problem vardır: cache invalidation ve isimlendirme."
> Bu yüzden **kısa TTL, karmaşık invalidation'dan iyidir.**

**[CACHE-13] ZORUNLU:** Yazma işleminden sonra ilgili anahtarlar **silinir**, güncellenmez:

```go
func (s *parkingService) Update(ctx context.Context, id string, req *dto.ParkingUpdateRequest) (*dto.Parking, error) {
	p, err := s.repo.Update(ctx, id, req)
	if err != nil {
		return nil, err
	}
	// Güncelleme DEĞİL silme: cache'e yeni değeri yazarsak, aynı anda başka bir
	// güncelleme geçtiğinde hangisinin son yazdığı yarışa kalır ve cache DB'den sapar.
	s.cache.Del(ctx, "parking:item:v1:"+id)
	s.invalidateLists(ctx)
	return p, nil
}
```

**[CACHE-14] ZORUNLU:** Liste cache'leri, tek tek anahtar silinerek değil **sürüm sayacı**
ile geçersizleştirilir:

```go
// Liste anahtarı: parking:list:v1:<gen>:page=1&limit=50
// Yazma sonrası sadece sayacı artır — tüm liste anahtarları bir anda geçersizleşir
// ve TTL ile temizlenir. KEYS/SCAN ile desen silmeye gerek kalmaz.
gen, _ := s.cache.Incr(ctx, "parking:list:gen").Result()
```

**[CACHE-15] YASAK:** Üretimde `KEYS` komutu. Tüm anahtar uzayını tarar ve Redis'i
**tek thread** olduğu için bloklar. Gerekiyorsa `SCAN` kullan, tercihen hiç kullanma.

**[CACHE-16] YASAK:** `FLUSHALL` / `FLUSHDB` (üretimde). Rate limit sayaçlarını, kilitleri
ve idempotency kayıtlarını da siler.

---

## 5. Cache stampede (sürü etkisi)

Popüler bir anahtarın TTL'i dolduğu anda yüzlerce istek aynı anda DB'ye gider.

**[CACHE-17] ZORUNLU:** Pahalı hesapların cache'inde stampede koruması bulunur. En basit
ve yeterli çözüm **jitter'lı TTL**:

```go
// Aynı anda yazılan 1.000 anahtar aynı anda ölmesin: TTL'e %±20 rastgelelik ekle.
func ttlWithJitter(base time.Duration) time.Duration {
	j := time.Duration(rand.Int63n(int64(base / 5)))
	return base - base/10 + j
}
```

**[CACHE-18] ÖNERİLEN:** Çok pahalı hesaplarda (saniyeler süren rapor) **tek uçuş**
(single-flight) deseni kullan: aynı anahtar için aynı anda yalnızca bir hesap koşar,
diğerleri onun sonucunu bekler. `golang.org/x/sync/singleflight` bunun içindir.

---

## 6. Dağıtık kilit

**[CACHE-19] ZORUNLU:** Kilit `SET key value NX PX <ttl>` ile alınır ve **TTL zorunludur**:

```go
token := uuid.NewString()
ok, err := rdb.SetNX(ctx, "lock:import:daily", token, 30*time.Second).Result()
if err != nil || !ok {
	return ErrLocked   // kilit alınamadı: fail-open YOK, işi yapma
}
defer releaseLock(ctx, rdb, "lock:import:daily", token)
```

**[CACHE-20] ZORUNLU:** Kilit **sahibi tarafından** bırakılır. Basit `DEL` yetmez —
TTL dolup kilit başkasına geçtiyse, `DEL` başkasının kilidini siler:

```go
// Lua ile atomik: değer benimse sil, değilse dokunma.
var releaseScript = redis.NewScript(`
	if redis.call("get", KEYS[1]) == ARGV[1] then
		return redis.call("del", KEYS[1])
	end
	return 0`)
```

**[CACHE-21] ZORUNLU:** Kilit TTL'i, korunan işin **en kötü senaryodaki süresinden uzun**
olmalıdır; iş uzun sürüyorsa kilit periyodik olarak uzatılır (heartbeat).

**[CACHE-22] ÖNERİLEN:** Redis kilidi **best-effort**tur; para/stok gibi mutlak doğruluk
gereken yerde Postgres transaction'ı ve `SELECT ... FOR UPDATE` kullan.

---

## 7. Redis kurulumu ve operasyon

**[CACHE-23] ZORUNLU:** Valkey'e `maxmemory` ve `maxmemory-policy` verilir:
```
maxmemory 512mb
maxmemory-policy allkeys-lru
```
> **Neden:** Politika belirtilmezse (`noeviction`) bellek dolduğunda sunucu **yazmayı
> reddeder** ve cache katmanı ansızın hata kaynağına dönüşür. `allkeys-lru` en eski
> kullanılanı atar.
> **Dikkat:** Aynı örnek hem cache hem kilit/rate-limit için kullanılıyorsa
> `allkeys-lru` kilitleri de atabilir — **ayrı DB indeksi ya da ayrı örnek** kullan.

**[CACHE-24] ZORUNLU:** Cache verisi için kalıcılık (RDB/AOF) **gerekmez** ve kapatılabilir;
kilit/idempotency verisi tutuluyorsa AOF açık olmalıdır.

**[CACHE-25] ZORUNLU:** Cache'e konan değer **küçüktür**. 1 MB'ı aşan değer cache'lenmez —
ağ üzerinden çekmesi DB sorgusundan pahalı olabilir.

**[CACHE-26] ÖNERİLEN:** Serileştirme `encoding/json` ile yapılır. Sıcak yolda darboğaz
olduğu **ölçülmüşse** daha hızlı bir format değerlendirilir; peşin optimizasyon yapılmaz.

**[CACHE-27] ZORUNLU:** İzlenecek metrikler ([10-GOZLEMLENEBILIRLIK.md](10-GOZLEMLENEBILIRLIK.md)):
isabet oranı (hit rate), eviction sayısı, bellek kullanımı, komut gecikmesi.
> İsabet oranı **%80'in altındaysa** cache muhtemelen yanlış yerde: ya anahtar çok
> parçalı ya TTL çok kısa. Ölçmeden "cache var, hızlıdır" denmez.

**[CACHE-28] ZORUNLU:** Bağlantı havuzu ayarlanır (`PoolSize`, varsayılan `10 × GOMAXPROCS`
çoğu servis için fazladır) ve `DialTimeout` / `ReadTimeout` / `WriteTimeout` verilir.

---

## 8. ASLA YAPMA — cache

- ❌ TTL'siz anahtar yazmak
- ❌ Cache'i doğruluk kaynağı gibi kullanmak (yalnızca cache'te olan veri)
- ❌ Cache hatasında isteği düşürmek (rate limit ve kilit hariç)
- ❌ Kullanıcıya özel veriyi kullanıcısız anahtarla cache'lemek
- ❌ Üretimde `KEYS` / `FLUSHALL`
- ❌ `maxmemory-policy` belirtmeden cache sunucusu çalıştırmak
- ❌ Aynı örnekte `allkeys-lru` ile kilit tutmak
- ❌ Cache'i güncellemek (silmek yerine)
- ❌ TTL'siz ya da sahibi doğrulanmadan bırakılan dağıtık kilit
- ❌ Ölçmeden cache eklemek
- ❌ Anahtara sürüm koymamak
