# EK — GIS, PostGIS ve Konum Verisi

> **Bu dosya opsiyoneldir.** Yalnızca projede geometri/harita verisi varsa okunur.
> Geometri yoksa buradaki hiçbir kural geçerli değildir ve uygulanmamalıdır.
>
> Kurallar ana standardın üzerine **eklenir**, onun yerine geçmez.

---

## 1. Kurulum

**[GIS-01] ZORUNLU:** Postgres imajı `postgis/postgis:18-3.6` olur ([VER-09]) ve
migration'ın ilk adımı eklentiyi kurar:
```sql
-- +goose Up
CREATE EXTENSION IF NOT EXISTS postgis;
```

**[GIS-02] ZORUNLU:** Tüm geometri **SRID 4326** (WGS84) saklanır. Karışık SRID'li kolonlar
`ST_Intersects` gibi işlemlerde sessizce yanlış sonuç verir.

---

## 2. Geometri tipi seçimi — ölçerek karar ver

**[GIS-03] ZORUNLU:** Kaynak dosyanın `"type"` alanına bakarak kolon tipi seçilmez. **Önce
geçerliliği ve parça sayısını ölç:**

```sql
SELECT
  COUNT(*) FILTER (WHERE NOT ST_IsValid(g))                        AS gecersiz,
  COUNT(*) FILTER (WHERE ST_NumGeometries(
      ST_CollectionExtract(ST_MakeValid(g), 3)) > 1)               AS aslinda_cok_parcali
FROM kaynak;
```

**[GIS-04] ZORUNLU:** Kaynakta **tek bir kayıt** bile onarıldığında çok parçalıya
ayrılıyorsa kolon `MultiPolygon` kurulur. Tek parçalı kayıtlar da MultiPolygon'a sarılır —
istemci tipe göre dallanmak zorunda kalmasın.
> **Vaka:** Kaynak `"type": "Polygon"` diyordu; 265 alanın 10'u geçersizdi ve onarıldığında
> **hepsi** 2–3 parçaya ayrılıyordu. Bunlar bozuk çizim değil, tek halkaya sıkıştırılmış
> çok parçalı alanlardı (parça toplamları kaynak alana birebir eşitti). `Polygon` seçilseydi
> elde yalnızca kötü seçenekler kalırdı: parçalardan birini atmak (bir okulda %50 alan
> kaybı) ya da kaydı tümüyle silmek.

---

## 3. Şema

```sql
CREATE TABLE IF NOT EXISTS facilities (
    id       UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    name     VARCHAR(255) NOT NULL,
    location GEOMETRY(MultiPolygon, 4326) NOT NULL,
    ...
    -- Kendini kesen halkayı yalnızca PostGIS görebilir; handler tek başına yetmez.
    CONSTRAINT facilities_location_valid CHECK (ST_IsValid(location))
);

-- Geometri kolonunda GIST index ZORUNLU: onsuz her uzamsal sorgu tam tarama yapar.
CREATE INDEX IF NOT EXISTS idx_facilities_location ON facilities USING GIST (location);
```

**[GIS-05] ZORUNLU:** Her geometri kolonunda **GIST index** bulunur.

**[GIS-06] ZORUNLU:** Her geometri kolonunda `CHECK (ST_IsValid(...))` bulunur.
> **Neden:** Geçersiz geometrinin tehlikesi **sessiz** olmasıdır — kayıt yazılır, harita
> çizer, alan hesaplanır, ama `ST_Intersects`/`ST_Contains` yanlış cevap verir ve bu
> aylar sonra fark edilir.

**[GIS-07] ZORUNLU:** `23514` (check violation) hatası constraint adına bakarak
sınıflandırılır ve mesajda **çözüm** söylenir ("parçaları tek halkada birleştirmeyin").
Aksi hâlde istemci "değer aralık dışında" gibi anlamsız bir hata görür ([DB-20]).

---

## 4. Girdi doğrulama

**[GIS-08] ZORUNLU:** Koordinat doğrulaması handler'da yapılır:

| Kontrol | Neden |
|---|---|
| Enlem `-90..90`, boylam `-180..180` | WGS84 sınırı |
| `(0, 0)` **reddedilir** | Null Island Gine Körfezi'ndedir; çoğu veri setinde asla geçerli değildir |
| Polygon halkası kapalı (ilk nokta == son nokta) ve ≥ 4 nokta | Açık halka PostGIS'te hata üretir |
| Proje sınır kutusu (bounding box) içinde mi | İl/ilçe verisinde sınır dışı nokta veri hatasıdır |

```go
// (0,0) reddedilir: kabul edilirse kayıt sessizce haritanın dışına taşınır ve
// bunu ancak haritaya bakan bir kullanıcı fark eder.
func ValidateCoordinates(lat, lon float64) error {
	if lat < -90 || lat > 90 {
		return fmt.Errorf("enlem -90 ile 90 arasında olmalı, gelen: %v", lat)
	}
	if lon < -180 || lon > 180 {
		return fmt.Errorf("boylam -180 ile 180 arasında olmalı, gelen: %v", lon)
	}
	if lat == 0 && lon == 0 {
		return errors.New("koordinat (0,0) geçerli değil")
	}
	return nil
}
```

**[GIS-09] ZORUNLU:** Reddedilen geometri **mevcut kaydı bozmaz** — doğrulama yazma
işleminden önce yapılır ve testle doğrulanır.

---

## 5. API sözleşmesi — GeoJSON

```json
{ "type": "FeatureCollection", "features": [
  { "type": "Feature",
    "geometry": { "type": "MultiPolygon", "coordinates": [...] },
    "properties": { "id": "…", "name": "…" } } ]}
```

**[GIS-10] ZORUNLU — Konum YALNIZCA `geometry` içindedir.** `properties` içinde
`latitude`, `longitude`, `lat`, `lon`, `location`, `coordinates` **bulunmaz**.
> **Neden:** Tekrar eden konum verisi payload'ı şişirir ve iki kaynak zamanla birbirinden
> sapar; hangisinin doğru olduğu belirsizleşir ([PERF-09]).

**[GIS-11] ZORUNLU:** Harita katmanı ucu ayrıdır ve sayfalanmaz **ama sınırlıdır**:
```
GET /<kaynak>/map?bbox=<minx,miny,maxx,maxy>
```
`bbox` olmadan tüm geometriyi döndüren uç, tek istekte yüzlerce MB üretebilir.

**[GIS-12] ZORUNLU:** Yanıtta koordinat hassasiyeti sınırlanır: `ST_AsGeoJSON(geom, 6)`
(≈ 10 cm). Varsayılan 15 basamak, payload'ı gereksiz yere 2–3 katına çıkarır.

**[GIS-13] ÖNERİLEN:** Görüntüleme amaçlı katmanlarda zoom seviyesine göre sadeleştirme
uygula (`ST_SimplifyPreserveTopology`). Alan/mesafe hesaplarında **ham geometri** kullanılır.

---

## 6. Sorgu

**[GIS-14] ZORUNLU:** Uzamsal filtre `ST_Intersects` / `ST_DWithin` ile yazılır — bunlar
GIST index kullanır. `ST_Distance(...) < x` **index kullanmaz** ve tam tarama yapar:
```sql
-- YANLIŞ: index kullanılmaz
WHERE ST_Distance(location, $1) < 500

-- DOĞRU: index kullanılır
WHERE ST_DWithin(location::geography, $1::geography, 500)
```

**[GIS-15] ZORUNLU:** Metre cinsinden mesafe/alan hesabı `geography` tipine cast edilerek
yapılır. `geometry` üzerinde 4326 ile hesaplanan "mesafe" **derece** cinsindendir ve
enleme göre değişir — sessizce yanlış sonuç verir.

**[GIS-16] ZORUNLU:** Geometri okuma `ST_AsGeoJSON(location, 6) AS location` ile yapılır;
ham WKB dışarı verilmez.

---

## 7. Veri aktarımı ve onarım

**[GIS-17] ZORUNLU:** Onarım (`ST_MakeValid`) **seed üretiminde** yapılır, çalışma anında
değil. Seed statik SQL'dir; onarım sonucu dosyaya yazılır.

**[GIS-18] ZORUNLU:** Mevcut kurulumlar için migration sırası: **önce** `ALTER COLUMN TYPE`,
**sonra** onarım. Tersi "Geometry type (MultiPolygon) does not match column type (Polygon)"
hatası verir.

**[GIS-19] ZORUNLU:** Migration ile seed **aynı** sonucu üretmelidir ([DB-16]). `ST_MakeValid`
yeni kesişim noktaları hesaplar; seed bunları `ST_AsGeoJSON(g, 9)` ile yuvarlarken migration
yuvarlamazsa iki kurulum yolu ayrışır. Aynı round-trip'i her ikisinde de uygula.

---

## 8. Kaynak veriden iş kuralı çıkarma

Kurumsal/belediye verisi bir sözleşme taşır ama bunu yazmaz. Şemayı kurmadan **önce**
kaynağı ölçerek kuralları çıkar.

**[GIS-20] ÖNERİLEN — Karar tablosu:**

| Ölçüm | Anlamı | Yapılacak |
|---|---|---|
| Kural %100 sağlanıyor | Gerçek iş kuralı | API'de zorla (400), mümkünse `CHECK` ekle |
| %100 ama tek değer var | Kural değil, veri eksikliği | `CHECK` koyma; operasyonel değerleri şemaya baştan ekle |
| Küçük sapma (3/1245) | Kuralın meşru istisnası | Sapmayı incele — genelde daha genel bir kuraldır |
| Bir alan diğerlerinden hesaplanabiliyor | Türetilmiş alan | `GENERATED` yap ya da sunucuda türet; istemciden **alma** ([DB-09]) |

**[GIS-21] ZORUNLU:** Kaynakta **tek değer taşıyan** alan "gereksiz" diye atılmaz — veri
vardır, yalnızca çeşitlilik yoktur. Atlanacak alan, **hiçbir kayıtta** değeri olmayan alandır.

**[GIS-22] YASAK:** Boş kolonu "ileride dolar" diye açmak. "Veri var ama görünmüyor"
izlenimi yaratır. Gerekçeyi şema yorumuna yaz; gerektiğinde eklemek tek satırlık migration'dır.

**[GIS-23] YASAK:** Ham ve türetilmiş değeri tek kolona sıkıştırmak. Ham tutarsan filtre
eksik bulur, normalize tutarsan belgedeki yazım kaybolur. İkisini ayrı kolonda tut ve
türetilmişi istemciden alma.

---

## 9. ASLA YAPMA — GIS

- ❌ Geometri tipini ölçmeden, kaynağın `"type"` alanına bakarak seçmek
- ❌ `CHECK (ST_IsValid(...))` koymadan geometri kabul etmek
- ❌ Geometri kolonunda GIST index'i unutmak
- ❌ Karışık SRID kullanmak
- ❌ `(0,0)` koordinatını kabul etmek
- ❌ `properties` içinde koordinat tekrarlamak
- ❌ `bbox`/sınır olmadan tüm geometriyi döndüren uç açmak
- ❌ Tam hassasiyette (15 basamak) koordinat döndürmek
- ❌ `ST_Distance(...) < x` ile filtrelemek (index kullanmaz)
- ❌ `geography` cast'i olmadan metre cinsinden mesafe hesaplamak
- ❌ Onarımı çalışma anında yapmak
- ❌ `ALTER COLUMN TYPE`'tan önce geometriyi onarmak
- ❌ Seed ile migration'ın farklı hassasiyet kullanması
