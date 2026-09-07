# 04 — API Sözleşmesi

> Tüm servisler aynı sözleşmeyi konuşur. Frontend her serviste ayrı biçim, ayrı hata
> gövdesi, ayrı sayfalama öğrenmez. Bu dosya bir tercih listesi değil, **kontrat**tır.

---

## 1. Yol adlandırma

```
GET    /<kaynak>?page=&limit=        → sayfalı liste + meta
GET    /<kaynak>/:id                 → tek kayıt
POST   /<kaynak>                     → oluştur (201)
PUT    /<kaynak>/:id                 → kısmi güncelle (200)
DELETE /<kaynak>/:id                 → sil (200)
GET    /health                       → sağlık (auth'suz)
GET    /ready                        → hazır mı (auth'suz)
```

**[API-01] ZORUNLU:** Kaynak adı **çoğul ve tireli**, küçük harf: `district-parkings`,
`market-places`, `stall-debts`. `MarketPlaces`, `market_places`, `marketPlace` olmaz.

**[API-01b] ZORUNLU:** Liste ucu kaynağın **kökündedir** — `GET /parkings`, `/parkings/list`
değil. Filtre ve sayfalama query parametresiyle verilir.
> **Neden:** İki sebep. (1) REST açısından doğrusu bu: koleksiyonun kendisi zaten listedir.
> (2) `/list` gibi sabit bir yolu `/:id` ile kardeş yapmak, router'da belirsizlik alanı
> açar — Gin bunu v1.7'den beri destekliyor ama trailing-slash yönlendirmesinde köşe
> durumları olan, tarihsel olarak panik üretmiş bir alandır. Belirsizliği hiç yaratmamak
> en sağlamı ([YAP-21]).

**[API-02] ZORUNLU:** `:id` her zaman **UUID**'dir. `original_id` gibi kaynak numaraları
yol parametresi olmaz.
> **Neden:** Ardışık int id, yetki kontrolü zayıflarsa doğrudan IDOR'a dönüşür ve saldırgan
> tüm kayıtları sayarak gezebilir. Ayrıca kayıt sayınızı dışarıya bildirir.

**[API-03] ZORUNLU:** Servis yolunda `api/v1` prefix'i **yok**. Platform/versiyon prefix'ini
(`/api/web/v1`) gateway yönetir.
> **Neden:** Prefix'i her servise yaymak, versiyon değiştiğinde 30 servisi birden
> değiştirmek demektir. Tek yerde durur.

**[API-04] ZORUNLU:** Fiil yol adına girmez. `POST /parkings` doğrudur; `POST /createParking`
değildir. İstisna: gerçekten CRUD olmayan işlemler alt kaynak olarak yazılır —
`POST /parkings/:id/reservations`.

**[API-05] ÖNERİLEN:** İç içe kaynak iki seviyeyi geçmez. `/a/:id/b/:id/c/:id` yerine
`/c?b_id=...` kullan.

---

## 2. DTO kuralları — üç tip

Her modül için **üç** DTO tanımlanır:

| Tip | Ne zaman | Alan biçimi |
|---|---|---|
| `X` | GET yanıtı | Değer tipleri; bilinmeyebilen alanlar **pointer** |
| `XRequest` | POST gövdesi | Eksikliği fark edilmesi gereken her alan **pointer** |
| `XUpdateRequest` | PUT gövdesi | **Tüm alanlar pointer** |

```go
// Yanıt
type Parking struct {
	ID   string `json:"id"`
	Name string `json:"name"`
	// NULL = bilinmiyor. Gerçek 0 ile karıştırma: kaynakta hakiki 0 değerleri de var.
	FloorCount *int `json:"floor_count"`
	// DB'de GENERATED. Salt okunur; Request DTO'sunda KARŞILIĞI YOK.
	EmptyCapacity int       `json:"empty_capacity"`
	CreatedAt     time.Time `json:"created_at"`
	UpdatedAt     time.Time `json:"updated_at"`
}

// POST
type ParkingRequest struct {
	Name string `json:"name"`
	// POST'ta ZORUNLU ama yine de pointer: eksik gönderim sessizce 0'a düşmesin.
	Latitude  *float64 `json:"latitude"`
	Longitude *float64 `json:"longitude"`
	FloorCount *int    `json:"floor_count"`
}

// PUT — istisnasız hepsi pointer
type ParkingUpdateRequest struct {
	Name       *string  `json:"name"`
	Latitude   *float64 `json:"latitude"`
	Longitude  *float64 `json:"longitude"`
	FloorCount *int     `json:"floor_count"`
}
```

**[API-06] ZORUNLU:** PUT DTO'sunda **tüm alanlar pointer**.
> `nil` = "gönderilmedi, mevcut değeri koru" · `&""` = "boşalt".
> Değer tipi kullanırsan tek alan güncellemesi diğer tüm alanları sıfırlar — ve bu
> hiçbir hata vermeden olur.

**[API-07] ZORUNLU:** Eksikliği fark edilmesi gereken alan, **zorunlu olsa bile** pointer olur.
> **Vaka:** `Latitude float64` yüzünden `{"name":"X","latitude":41.19}` (longitude yok)
> kabul ediliyor, `longitude` sessizce `0` oluyor ve nokta Gana açıklarına düşüyordu.

**[API-08] YASAK:** DB'de `GENERATED` olan ya da sunucuda türetilen alanı Request DTO'suna
koymak. İstemci hesaplanmış değeri yazamamalı — yazarsa hesapla çelişir ve hangisinin
doğru olduğu belirsizleşir.

**[API-09] ZORUNLU:** JSON alan adları `snake_case`. Go alanı `FloorCount`, JSON'da
`floor_count`. Tutarsız isimlendirme frontend'de her seferinde yeniden öğrenilir.

**[API-10] ZORUNLU:** Tarih alanları **takvim tarihi** ise `"2006-01-02"` **metin** olarak
taşınır, `time.Time` değil.
> **Neden:** `time.Time` JSON'a saat dilimi ekler (`"2023-01-09T00:00:00Z"`) ve tarih
> istemcinin diliminde bir gün kayar. Zaman damgası (`created_at`) ise `time.Time` doğrudur.

### Kısmi güncellemede tarih: üç durum

`*string` bu üç durumu ayıramaz:

```
alan gövdede yok                  -> dokunma
"suspension_date": null           -> NULL yap (işlem geri alındı)
"suspension_date": "2024-01-05"   -> güncelle
```

**[API-11] ZORUNLU:** Üç durum gereken alanlarda `Set` bayrağı taşıyan tip kullanılır ve
**değer tipi** olarak gömülür, pointer değil:

```go
type NullableDate struct {
	Value string // "2006-01-02", doğrulanmış
	Null  bool   // istemci açıkça null gönderdi
	Set   bool   // alan gövdede VARDI
}
```

> **Tuzak:** `encoding/json`, *pointer* bir alana `null` gelince pointer'ı `nil` yapar ve
> `UnmarshalJSON`'u **hiç çağırmaz** — üç durum yine ikiye iner ve kullanıcı yanlış girilmiş
> bir tarihi asla temizleyemez. Değer tipinde `null` için de `UnmarshalJSON` çağrılır.
> Bunu ancak test yakalar, mutlaka yaz:
> ```go
> var b struct{ D NullableDate `json:"d"` }
> _ = json.Unmarshal([]byte(`{"d":null}`), &b)
> if !b.D.Set { t.Fatal("açık null için UnmarshalJSON çağrılmadı") }
> ```

---

## 3. Gin ile gövde bağlama

```go
func (h *ParkingHandler) Create(c *gin.Context) {
	var req dto.ParkingRequest
	// ShouldBindJSON — Bind/BindJSON DEĞİL: Bind* ailesi hata durumunda kendi 400'ünü
	// yazar ve bizim hata gövdemizi ([API-13]) kullanamayız.
	if err := c.ShouldBindJSON(&req); err != nil {
		badRequest(c, "istek gövdesi okunamadı")
		return
	}
	if strings.TrimSpace(req.Name) == "" {
		badRequest(c, "name zorunludur")
		return
	}
	if req.Latitude == nil || req.Longitude == nil {
		badRequest(c, "latitude ve longitude zorunludur")
		return
	}
	if err := pkg.ValidateCoordinates(*req.Latitude, *req.Longitude); err != nil {
		badRequest(c, err.Error())
		return
	}
	// gin.Context DEĞİL, isteğin gerçek context'i geçirilir [YAP-10].
	result, err := h.svc.Create(c.Request.Context(), &req)
	if err != nil {
		writeError(c, err)
		return
	}
	c.JSON(http.StatusCreated, result)
}
```

**[API-12] ZORUNLU:** Bağlama `c.ShouldBindJSON(&req)` ile yapılır.
> **Neden `Bind`/`BindJSON` değil:** `Bind*` ailesi hatada isteği kendisi `400` ile
> sonlandırır ve `Content-Type` başlığını da ezer; standart hata gövdemiz
> (`{"error":true,"message":...}`) yerine Gin'in kendi biçimi döner. `Should*` ailesi
> hatayı sana verir, yanıtı sen yazarsın.

**[API-12b] ZORUNLU:** Gin handler'ı `error` döndürmez; hatayı **yazıp `return`** eder.
`return` unutulursa akış devam eder ve ikinci bir yanıt yazılmaya çalışılır — bu, Gin'e
geçişte en sık yapılan hatadır.

---

## 4. Yanıt biçimleri

### 4.1 Hata gövdesi (istisnasız)

```json
{ "error": true, "message": "Erişim reddedildi: gerekli yetki yok" }
```

**[API-13] ZORUNLU:** Tüm servislerde tüm hatalar bu gövdeyle döner. `{"err": "..."}`,
`{"detail": ...}`, düz string — hiçbiri kabul edilmez.

**[API-14] ÖNERİLEN:** İstemcinin dallanması gereken hatalarda makine-okunur kod ekle:
```json
{ "error": true, "code": "DUPLICATE_ORIGINAL_ID", "message": "Bu kayıt zaten var" }
```
`message` insan içindir ve değişebilir; `code` sözleşmedir ve değişmez.

**[API-15] ZORUNLU:** `message` **istemciye gösterilebilir** olmalıdır. İç hata detayı,
tablo/constraint adı, SQL, stack trace, iç servis URL'i asla girmez ([GEN-15]).

### 4.2 Liste yanıtı

```json
{
  "data": [ ... ],
  "meta": { "page": 1, "limit": 50, "total_items": 81, "total_pages": 2 }
}
```

**[API-16] YASAK:** Yanıtı çift sarmalamak (`data.data`). Liste `data` + `meta`,
tek kayıt doğrudan objedir.

**[API-17] ZORUNLU:** `total_items` **filtre uygulanmış** toplamdır — tablodaki toplam
satır sayısı değil.

**[API-18] ZORUNLU:** `limit` sınırları **1..200**, varsayılan **50**. Sınırı aşan değer
**kırpılır**, varsayılana düşmez ([YAP-18]).

**[API-19] YASAK:** Sayfalamasız liste ucu. "Şimdilik 40 kayıt var" bir gerekçe değildir —
kayıt sayısı artar, endpoint bir gün 200 MB döner.

### 4.3 Tek kayıt

```json
{ "id": "…", "name": "…", "floor_count": null, "created_at": "…" }
```
Sarmalanmaz.

---

## 5. Status kodları

| Durum | Kod |
|---|---|
| Başarılı okuma / güncelleme / silme | **200** |
| Oluşturma | **201** |
| Kabul edildi, asenkron işlenecek | **202** |
| Girdi hatası / iş kuralı ihlali | **400** |
| Kimlik yok veya geçersiz (gateway'siz erişim, hatalı API key) | **401** |
| Kimlik var ama yetki yok | **403** |
| Kayıt yok | **404** |
| Benzersizlik çakışması | **409** |
| Doğru biçim, işlenemeyen içerik (nadir; tercihen 400) | **422** |
| Rate limit aşıldı | **429** |
| İç hata (maskelenmiş) | **500** |
| Upstream bağımlılık cevap vermiyor | **503** |
| Upstream zaman aşımı | **504** |

**[API-20] ZORUNLU:** 401 ile 403 karıştırılmaz. 401 = "kim olduğunu bilmiyorum",
403 = "kim olduğunu biliyorum ama yetkin yok".

**[API-21] ZORUNLU:** İstemci hatası 5xx dönmez. Bunun en sık kaynağı, doğrulanmadan
DB'ye giden girdinin sürücü hatası üretmesidir — bkz. [07-VERITABANI.md](07-VERITABANI.md)
hata çevirim tablosu.

### Hata mesajı sözleşmesi (katmanlar arası)

Repository sentinel hata döndürür, handler bunu status koda çevirir:

```go
var (
	ErrNotFound     = errors.New("not found")     // -> 404
	ErrConflict     = errors.New("conflict")      // -> 409
	ErrInvalidInput = errors.New("invalid input") // -> 400
	ErrInternal     = errors.New("internal")      // -> 500, maskelenir
)

func writeError(c *gin.Context, err error) {
	switch {
	case errors.Is(err, postgres.ErrNotFound):
		c.AbortWithStatusJSON(http.StatusNotFound, pkg.ErrorBody("kayıt bulunamadı"))
	case errors.Is(err, postgres.ErrConflict):
		c.AbortWithStatusJSON(http.StatusConflict, pkg.ErrorBody(err.Error()))
	case errors.Is(err, postgres.ErrInvalidInput):
		c.AbortWithStatusJSON(http.StatusBadRequest, pkg.ErrorBody(err.Error()))
	default:
		// İç hata: istemciye maskelenir, log'a TAM hâliyle yazılır.
		pkg.Log.Error("beklenmeyen hata",
			"path", c.FullPath(), "request_id", requestid.Get(c), "err", err)
		c.AbortWithStatusJSON(http.StatusInternalServerError,
			pkg.ErrorBody("işlem tamamlanamadı"))
	}
}
```

**[API-22] ZORUNLU:** Hata sınıflandırması `errors.Is` ile yapılır, hata **mesajı**
karşılaştırılarak değil. Mesaj metnine bağlı sınıflandırma ilk çeviri değişikliğinde bozulur.

---

## 6. Idempotency ve yan etki

**[API-23] ZORUNLU:** `GET`, `PUT`, `DELETE` idempotenttir. Aynı isteği iki kez göndermek
sistemi farklı duruma taşımaz.

**[API-24] ZORUNLU:** `GET` **hiçbir durumu değiştirmez.** Sayaç artırmak, "son görüntülenme"
yazmak dâhil. Gerekiyorsa asenkron event üret ([11](11-ASENKRON-KAFKA-TEMPORAL.md)).

**[API-25] ÖNERİLEN:** Para/stok gibi tekrarlanamaz `POST` işlemlerinde `Idempotency-Key`
header'ı destekle: anahtar + sonuç Redis'te TTL ile saklanır, aynı anahtarla gelen ikinci
istek **yeni işlem yapmadan** ilk sonucu döner.
> **Neden:** Ağ hatası sonrası istemci retry eder. Retry'ı korumazsan çift tahsilat yaparsın
> ve bunu ancak müşteri fark eder.

---

## 7. Filtreleme, sıralama, alan seçimi

**[API-26] ZORUNLU:** Filtreler query parametresidir ve **beyaz listeyle** doğrulanır:
```go
var allowedSort = map[string]string{
	"name":       "name",
	"created_at": "created_at",
}
col, ok := allowedSort[c.Query("sort", "created_at")]
if !ok {
	return badRequest(c, "geçersiz sort alanı")
}
```
> Beyaz liste olmadan `sort` parametresi doğrudan SQL'e giderse injection kapısıdır.

**[API-27] ZORUNLU:** Sıralama **benzersiz bir tie-break** içerir: `ORDER BY created_at DESC, id ASC`.
> **Vaka:** 1.244 borç kaydının `created_at` değeri seed sırasında aynıydı; sıra kararsız
> olduğu için sayfalar arasında kayıt hem tekrarlanıyor hem atlanıyordu. Tüm sayfaları
> gezen istemci toplamı 4.800 TL eksik hesaplıyordu.

**[API-28] ÖNERİLEN:** Çok büyük ve sürekli değişen listelerde `LIMIT/OFFSET` yerine
**cursor** kullan: `?after=<son_id>&limit=50`. OFFSET derin sayfalarda hem yavaştır hem
araya giren kayıtlarla kayar.

---

## 8. Versiyonlama

**[API-29] ZORUNLU:** Kırıcı değişiklik yapılmaz; yeni alan **eklenir**, eski alan
**silinmez**. Silinmesi gerekiyorsa:
1. Yeni alanı ekle, ikisini birlikte döndür.
2. Eski alanı `deprecated` olarak dokümana yaz ve tarih ver.
3. İstemcilerin geçtiğini **ölç** (log/metrik), sonra sil.

**[API-30] ZORUNLU:** Gerçekten kırıcı bir değişiklik gerekiyorsa gateway'de yeni versiyon
prefix'i açılır (`/api/web/v2`), servis içinde versiyon dallanması yapılmaz.
> **Neden:** Servis içinde `if version == 2` dallanması, iki sözleşmeyi tek kod tabanında
> tutar ve ikisi de yarım test edilir.

---

## 9. Dokümantasyon

**[API-31] ZORUNLU:** Her servis şunları taşır:
- `docs/README.md` — servis ne yapar, endpoint listesi, yetki listesi
- `docs/ui-integration.md` — frontend'in tipik akışları nasıl kuracağı, örnek istek/yanıt
- `docs/<Isim>.postman_collection.json` — çalışır koleksiyon

**[API-32] ZORUNLU:** Endpoint değiştiyse aynı PR'da dokümanı da değiştir. "Sonra
güncellerim" denen doküman güncellenmez ve yanlış doküman, dokümansızlıktan kötüdür.
