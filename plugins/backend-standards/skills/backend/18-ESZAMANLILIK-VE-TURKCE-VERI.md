# 18 — Eşzamanlılık, Türkçe Metin ve Zaman

> Bu dosyadaki üç konunun ortak özelliği: **hata mesajı üretmezler.** Kayıt kaydedilir,
> arama çalışır, tarih görünür — ama sonuç yanlıştır ve bunu ancak kullanıcı fark eder.

---

# 1. Eşzamanlı düzenleme (lost update)

## 1.1 Problem

```
10:00  Ayşe otopark kaydını açar    → kapasite: 100, kat: 3
10:01  Mehmet aynı kaydı açar       → kapasite: 100, kat: 3
10:02  Ayşe kapasiteyi 150 yapar    → kaydedildi
10:03  Mehmet kat sayısını 4 yapar  → kaydedildi
       Sonuç: kapasite tekrar 100.  Ayşe'nin değişikliği YOK OLDU.
```

Ayşe hata görmedi. Mehmet hata görmedi. Kayıt bozulmadı. Sadece bir değişiklik sessizce
kayboldu ve bunu kimse fark etmeyecek.

> **Not:** [API-06]'daki "PUT'ta tüm alanlar pointer" kuralı bu riski **azaltır**
> (Mehmet yalnızca `floor_count` gönderdiği için kapasiteye dokunmaz) ama **çözmez**:
> ikisi de aynı alanı düzenlerse yine son yazan kazanır ve ilki uyarılmaz.

## 1.2 Çözüm — iyimser kilitleme (optimistic locking)

**[CONC-01] ZORUNLU:** Birden fazla kullanıcının aynı anda düzenleyebileceği tablolarda
**sürüm kolonu** bulunur:

```sql
CREATE TABLE parkings (
    id      UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    ...
    -- Her güncellemede artar. İstemci hangi sürümü düzenlediğini bildirir;
    -- arada başkası yazdıysa sürüm tutmaz ve güncelleme reddedilir.
    version BIGINT NOT NULL DEFAULT 1
);
```

**[CONC-02] ZORUNLU:** Güncelleme sürümü `WHERE` içinde kontrol eder ve **etkilenen satır
sayısına bakar**:

```go
tag, err := r.pool.Exec(ctx, `
    UPDATE parkings SET
        name       = COALESCE($1, name),
        version    = version + 1,
        updated_at = now()
    WHERE id = $2 AND version = $3`,
    req.Name, id, req.Version)
if err != nil {
    return translate(err)
}
// 0 satır: ya kayıt yok ya da ARADA BAŞKASI GÜNCELLEDİ. İkisini ayırmak için
// kaydın hâlâ var olup olmadığına bakılır — istemciye doğru hatayı vermek için.
if tag.RowsAffected() == 0 {
    exists, _ := r.Exists(ctx, id)
    if !exists {
        return ErrNotFound
    }
    return fmt.Errorf("%w: kayıt siz görüntüledikten sonra başkası tarafından değiştirildi",
        ErrConflict)
}
```

**[CONC-03] ZORUNLU:** `version` alanı yanıt DTO'sunda döner ve güncelleme isteğinde
**zorunludur**:

```go
type Parking struct {
    ID      string `json:"id"`
    Version int64  `json:"version"`   // istemci bunu geri göndermek ZORUNDA
    ...
}

type ParkingUpdateRequest struct {
    // Diğer alanlar pointer [API-06] ama version DEĞİL: gönderilmesi zorunlu.
    Version int64   `json:"version"`
    Name    *string `json:"name"`
}
```

**[CONC-04] ZORUNLU:** Sürüm çakışması **409 Conflict** döner ([API-19] tablosu) ve mesaj
istemciye **ne yapacağını** söyler:
```json
{ "error": true, "code": "VERSION_CONFLICT",
  "message": "Kayıt siz görüntüledikten sonra değiştirildi. Lütfen sayfayı yenileyip tekrar deneyin." }
```
> `code` alanı ([API-14]) burada gerçekten gerekli: frontend bu durumda otomatik yenileme
> yapmak isteyebilir, genel bir 409'dan ayırt edebilmelidir.

**[CONC-05] ÖNERİLEN:** Alternatif olarak HTTP `ETag` + `If-Match` kullanılabilir. Kural
aynıdır; `version` gövdede taşımak daha basit ve daha az yanlış anlaşılır olduğu için
varsayılan odur.

**[CONC-06] ZORUNLU:** Sürüm kolonu **istemciden yazılamaz** — sunucu artırır ([API-08]).
`version = $n` şeklinde istemci değeri atanmaz; yalnızca `WHERE`'de karşılaştırılır.

## 1.3 Kötümser kilitleme ne zaman

**[CONC-07] ZORUNLU:** Para hareketleri ve stok gibi **mutlak doğruluk** gereken yerlerde
`SELECT ... FOR UPDATE` kullanılır ([CACHE-22]):

```sql
BEGIN;
SELECT paid_amount::text FROM stall_debts WHERE id = $1 FOR UPDATE;  -- satır kilitli
UPDATE stall_debts SET paid_amount = $2 WHERE id = $1;
COMMIT;
```
> Kilit transaction boyunca durur; bu yüzden transaction **kısa** olmalı ([DB-23]).

**[CONC-08] ZORUNLU:** Birden fazla satır kilitlenecekse **sabit bir sırada** kilitlenir
(örn. `ORDER BY id`) — aksi hâlde iki işlem birbirini bekler ve deadlock oluşur ([DB-25]).

## 1.4 Sayaç ve biriken değerler

**[CONC-09] YASAK — Oku-değiştir-yaz (read-modify-write) deseni:**

```go
// YANLIŞ: iki eşzamanlı istek arasında sayaç kaybolur
p, _ := repo.GetByID(ctx, id)
p.OccupiedCapacity++
repo.Update(ctx, p)

// DOĞRU: artırma veritabanında atomik yapılır
UPDATE parkings SET occupied_capacity = occupied_capacity + 1
 WHERE id = $1 AND occupied_capacity < total_capacity
RETURNING occupied_capacity;
```
> `WHERE` içindeki sınır kontrolü de kritik: uygulamada kontrol edip sonra yazmak,
> iki istek arasında kapasitenin aşılmasına izin verir. Şemadaki `CHECK` ([DB-08])
> son savunmadır.

**[CONC-10] ZORUNLU:** Aynı işlemin iki kez çalışması istenmiyorsa `Idempotency-Key`
([API-25]) kullanılır — eşzamanlılık koruması tekrar korumasının yerine geçmez.

## 1.5 Test

**[CONC-11] ZORUNLU:** İyimser kilitleme testi yazılır:
```
□ Aynı version ile iki ardışık güncelleme → ikincisi 409
□ Doğru version ile güncelleme            → 200 ve version artmış
□ version göndermeyen istek               → 400
□ Var olmayan kayıt                       → 404 (409 değil)
```

---

# 2. Türkçe metin

## 2.1 Problem: `i` ve `İ`

Türkçe, Unicode'un varsayılan büyük/küçük harf kurallarına **uymayan** birkaç dilden biridir:

| Türkçe doğrusu | Varsayılan (dilden bağımsız) davranış |
|---|---|
| `I` → `ı` | `I` → `i` ❌ |
| `i` → `İ` | `i` → `I` ❌ |
| `İ` → `i` | `İ` → `i` + birleşen nokta (**iki kod noktası**) ❌ |

Sonuçları, sessiz ve can sıkıcıdır:
- `LOWER('İSTANBUL')` beklediğin `istanbul` değildir → arama kayıt bulamaz
- `'ISPARTA'` küçültülünce `isparta` olur, `ısparta` değil → yanlış eşleşme
- `WHERE LOWER(name) = LOWER($1)` iki tarafta farklı sonuç üretebilir

**[TRK-01] ZORUNLU:** Postgres'in `lower()`/`upper()` davranışı veritabanı locale'ine ve
**işletim sistemine** bağlıdır. Geliştirme (Windows) ile üretim (Linux Alpine) farklı
sonuç üretebilir. Bu yüzden OS locale'ine **asla güvenilmez**.

## 2.2 Çözüm

**[TRK-02] ZORUNLU:** Türkçe metinde büyük/küçük harf dönüşümü **ICU collation** ile
açıkça yapılır:

```sql
SELECT lower(name COLLATE "tr-TR-x-icu") FROM districts;
ORDER BY name COLLATE "tr-TR-x-icu";   -- Ç, Ğ, İ, Ö, Ş, Ü doğru yerde sıralanır
```
> Sıralama ayrıca önemlidir: varsayılan collation'da `Şişli`, `Sarıyer`'den **önce**
> gelebilir. Kullanıcı listeyi "alfabetik değil" diye rapor eder ve sebebini kimse bulamaz.

**[TRK-03] ÖNERİLEN — Arama için normalize kolon.** En sağlam ve en taşınabilir yöntem,
aramaya özel bir kolon tutmaktır:

```sql
-- Aranabilir biçim: küçük harf (Türkçe kurallarıyla) + aksan sadeleştirme.
-- GENERATED olduğu için elle senkronlama derdi yok [DB-09].
search_name TEXT GENERATED ALWAYS AS (
    lower(unaccent(name) COLLATE "tr-TR-x-icu")
) STORED;

CREATE INDEX idx_districts_search ON districts (search_name text_pattern_ops);
```
```sql
-- Sorgu: girdi AYNI dönüşümden geçirilir. Tek yerde tanımlı olması şart.
WHERE search_name LIKE lower(unaccent($1) COLLATE "tr-TR-x-icu") || '%';
```
> **Neden index'li normalize kolon:** `LOWER(name) LIKE ...` yazarsan index kullanılmaz
> ve tablo taranır ([DB-26]). Normalize kolon hem doğru hem hızlıdır.
> `unaccent` uzantısı gerekir: `CREATE EXTENSION IF NOT EXISTS unaccent;`

**[TRK-04] ÖNERİLEN:** Küçük veri kümelerinde alternatif olarak **belirleyici olmayan
(nondeterministic) ICU collation** kullanılabilir:
```sql
CREATE COLLATION turkish_ci (
    provider = icu, deterministic = false, locale = 'tr-TR-u-ks-level2'
);
-- Kolon bu collation'da tanımlanırsa "İstanbul" = "istanbul" doğrudan eşleşir.
```
> **Dikkat:** Belirleyici olmayan collation'lı kolonlarda bazı index türleri ve
> `LIKE` desteklenmez. Bu yüzden varsayılan [TRK-03]'tür.

**[TRK-05] ZORUNLU — Go tarafında `strings.ToLower`/`ToUpper` Türkçe metin için
kullanılmaz.** Go, dilden bağımsız Unicode kurallarını uygular; yukarıdaki tüm hatalar
Go'da da geçerlidir.

```go
import (
    "golang.org/x/text/cases"
    "golang.org/x/text/language"
)

// Türkçe kurallarıyla küçültme. strings.ToLower("İSTANBUL") YANLIŞ sonuç verir.
var trLower = cases.Lower(language.Turkish)

normalized := trLower.String(input)
```
> `golang.org/x/text` Go ekibinin paketidir; [VER-07] anlamında "üçüncü parti" sayılmaz,
> ancak `go.mod`'a eklenmesi ve [02](02-TEKNOLOJI-SURUMLERI.md) tablosuna işlenmesi gerekir.

**[TRK-06] ZORUNLU:** Normalize etme mantığı **tek bir fonksiyonda** yaşar
(`pkg/textnorm.go`). Sorgu tarafı ve yazma tarafı aynı fonksiyonu çağırır — iki yerde
ayrı yazılırsa er ya da geç ayrışır ve arama sessizce kayıt bulamaz olur.

## 2.3 Karakter kodlama

**[TRK-07] ZORUNLU:** Veritabanı ve bağlantı kodlaması **UTF-8**'dir. `WIN1254`/`ISO-8859-9`
(Latin-5) kullanılmaz.

**[TRK-08] ZORUNLU:** Gelen girdinin geçerli UTF-8 olduğu doğrulanır ([SEC-12]):
```go
if !utf8.ValidString(q) {
    badRequest(c, "geçersiz karakter kodlaması")
    return
}
```
> **Neden:** Latin-5 ile kodlanmış bir sorgu parametresi doğrudan Postgres'e giderse
> `invalid byte sequence for encoding "UTF8"` hatasıyla **500** üretir — oysa bu bir
> istemci hatasıdır ([API-21]).

**[TRK-09] ZORUNLU:** Metin uzunluğu sınırları `[]rune` ile ölçülür, bayt ile değil
([SEC-13]) — `ğüşiöçİ` karakterleri UTF-8'de 2 bayttır ve geçerli girdi yanlışlıkla
reddedilir.

**[TRK-10] ZORUNLU:** Türkçe karakter testi yazılır:
```
□ "İSTANBUL" araması "istanbul" kaydını buluyor mu
□ "ISPARTA" araması "ısparta" kaydını buluyor mu
□ Sıralamada Ç/Ğ/İ/Ö/Ş/Ü doğru yerde mi
□ 255 karakterlik Türkçe metin kabul ediliyor mu (bayt sınırına takılmıyor mu)
□ Latin-5 kodlu query parametresi → 400 (500 değil)
```

---

# 3. Zaman

**[ZAM-01] ZORUNLU:** Tüm zaman damgaları `TIMESTAMPTZ` ([DB-06]) ve uygulama içinde
**UTC** ile çalışılır. Yerel saate çevirme yalnızca **gösterim** anında yapılır.

**[ZAM-02] ZORUNLU:** Sunucu ve konteynerler UTC'dedir; `TZ=Europe/Istanbul` gibi bir
env ile ayarlanmaz. Gösterim saat dilimi istemcinin ya da raporun sorunudur.

**[ZAM-03] ZORUNLU:** Takvim tarihi (doğum tarihi, borç vadesi) ile an (oluşturulma zamanı)
karıştırılmaz ([API-10]): tarih `DATE` + `"2006-01-02"` metin, an `TIMESTAMPTZ` + `time.Time`.

**[ZAM-04] ÖNERİLEN:** İş mantığında `time.Now()` doğrudan çağrılmaz; saat dışarıdan
verilir:
```go
type Clock interface{ Now() time.Time }
// Üretimde gerçek saat, testte sabit saat. "Ayın son günü" gibi kuralları
// test edebilmenin tek yolu budur.
```

**[ZAM-05] ZORUNLU:** Token süreleri ve zamana bağlı kontroller **saat kaymasına**
(clock skew) tolerans tanır (tipik: ±60 sn). Farklı sunucuların saatleri birebir aynı değildir.

**[ZAM-06] ZORUNLU:** Zamanlanmış işlerde saat dilimi açıkça belirtilir ve **yaz saati
geçişi** düşünülür — [20](20-ENTEGRASYON-VE-TOPLU-VERI.md) [JOB-07].

---

## 4. ASLA YAPMA

**Eşzamanlılık**
- ❌ Çok kullanıcılı düzenlenebilir kayıtta sürüm kolonu olmaması
- ❌ `UPDATE` sonrası etkilenen satır sayısına bakmamak
- ❌ Sürüm çakışmasını 200 ile geçiştirmek (409 olmalı)
- ❌ `version`'ı istemciden yazdırmak
- ❌ Oku-değiştir-yaz ile sayaç güncellemek
- ❌ Sınır kontrolünü yalnızca uygulamada yapmak (şemada `CHECK` de olmalı)
- ❌ Çok satırı rastgele sırada kilitlemek (deadlock)

**Türkçe metin**
- ❌ `LOWER()`/`UPPER()`'ı collation belirtmeden Türkçe metinde kullanmak
- ❌ Go'da `strings.ToLower` ile Türkçe metin küçültmek
- ❌ Normalize mantığını iki ayrı yerde yazmak
- ❌ `LOWER(kolon) LIKE ...` ile index'i devre dışı bırakmak
- ❌ Metin uzunluğunu bayt ile ölçmek
- ❌ UTF-8 doğrulaması yapmadan girdiyi DB'ye göndermek
- ❌ Türkçe sıralama testini yazmamak

**Zaman**
- ❌ `TIMESTAMP` (tz'siz) kullanmak
- ❌ Uygulama içinde yerel saatle çalışmak
- ❌ Takvim tarihini `time.Time` ile taşımak
- ❌ Saat kayması toleransı olmayan süre kontrolü
