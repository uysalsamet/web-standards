# 12 — Test

> Test, "çalışıyor" demenin **tek** geçerli gerekçesidir. Elle bir kez denemek kanıt değildir;
> ikinci kez aynı hatayı yapmanı engellemez.

---

## 1. Test piramidi

```
        ▲  E2E (az)         gerçek servis + gerçek DB, tek kritik akış
       ███ Entegrasyon      repository ↔ gerçek Postgres (testcontainers)
     ██████ Birim/routing   stub'larla, DB'siz, milisaniyeler içinde
```

**[TEST-01] ZORUNLU:** Testlerin çoğunluğu **DB'siz** koşar. Service ve repository
interface olduğu için ([GEN-07]) stub yazmak kolaydır.
> **Neden:** Her testi Postgres'e bağlarsan süit dakikalar sürer; süre uzadıkça geliştirici
> testi çalıştırmayı bırakır ve test yazılmış olmasının bir anlamı kalmaz.

**[TEST-02] ZORUNLU:** Testler **birbirinden bağımsız** ve sırasızdır. Bir testin ürettiği
veriye başka test dayanamaz. `t.Parallel()` eklendiğinde kırılan test, gizli bağımlılığı
olan testtir.

**[TEST-03] ZORUNLU:** Test isimleri ne doğruladığını söyler:
`TestCreate_MissingLongitude_Returns400` — `TestCreate2` değil.

---

## 2. `routes_test.go` — her serviste zorunlu

**[TEST-04] ZORUNLU:** Her servis `internal/routes/routes_test.go` içerir ve **en az**
şunları doğrular:

| # | Ne doğrulanır |
|---|---|
| 1 | **Routing:** her endpoint tanımlı mı (404 dönmüyor mu) |
| 2 | **`/health` auth'suz erişilebilir mi**, formatı `{"status":"healthy",...}` mı |
| 3 | **`api/v1` yolları 404 mü** (prefix gateway'in işi — [API-03]) |
| 3b | **Liste ucu kaynağın kökünde mi** (`GET /parkings`), `/parkings/list` 404 mü — [API-01b] |
| 4 | **Gateway baypası reddediliyor mu:** header yok → 403, sahte kaynak → 403, yanlış API key → 401 |
| 5 | **Yetki uygulanıyor mu:** `view` ile POST → 403, `create` ile POST → 201 |
| 6 | **Wildcard doğru mu:** `modul.*` çalışıyor, `*` superadmin çalışıyor |
| 7 | **Modüller arası sızıntı yok mu:** `a_modul.*` ile `b_modul` uçları → 403 |
| 8 | **Girdi doğrulama:** boş isim, geçersiz UUID, negatif sayı, sınır dışı değer, aşırı uzun metin, geçersiz UTF-8 → hepsi **400** |
| 9 | **Reddedilen istek servise ULAŞMIYOR mu** |
| 10 | **Kısmi güncelleme:** gönderilmeyen alan service'e `nil` geçiyor mu; açık `0` gönderilen alan `nil`'e düşmüyor mu |
| 11 | **Yanıt sözleşmesi:** liste `data`+`meta` mı, `meta.limit` ile dönen kayıt sayısı uyumlu mu |

**[TEST-05] ZORUNLU:** Test, `routes.Setup`'a **stub** handler/service verir ve
`httptest.NewRecorder()` + `router.ServeHTTP(w, req)` ile çağırır. DB'ye gidilmez.
Gin'in ekstra bir test yardımcısına ihtiyacı yoktur; `net/http/httptest` yeter — bu,
`net/http` tabanlı olmanın somut faydalarından biridir.

**[TEST-06] ZORUNLU:** Stub'da `reached bool` tutulur; "reddedilmesi gereken istek service
katmanına ulaştı mı" böyle doğrulanır ([SEC-14]).

```go
type stubParkingService struct {
	reached  bool
	lastReq  *dto.ParkingUpdateRequest
	response *dto.Parking
	err      error
}

func (s *stubParkingService) Update(_ context.Context, _ string, req *dto.ParkingUpdateRequest) (*dto.Parking, error) {
	s.reached = true
	s.lastReq = req
	return s.response, s.err
}

func newTestRouter(svc service.ParkingService) *gin.Engine {
	// TestMode: gin'in debug çıktısı test logunu kirletmesin.
	gin.SetMode(gin.TestMode)
	r := gin.New()
	r.ContextWithFallback = true
	routes.Setup(r, testConfig(), handler.NewParkingHandler(svc))
	return r
}

func authed(method, path, body, perms string) *http.Request {
	req := httptest.NewRequest(method, path, strings.NewReader(body))
	if body != "" {
		req.Header.Set("Content-Type", "application/json")
	}
	req.Header.Set("X-Gateway-Source", "api-gateway")
	req.Header.Set("X-API-Key", testAPIKey)
	req.Header.Set("X-User-Permissions", perms)
	return req
}

func TestCreate_WithOnlyViewPermission_Returns403AndDoesNotReachService(t *testing.T) {
	stub := &stubParkingService{}
	r := newTestRouter(stub)

	w := httptest.NewRecorder()
	r.ServeHTTP(w, authed(http.MethodPost, "/parkings", `{"name":"X"}`, "parking.view"))

	if w.Code != http.StatusForbidden {
		t.Fatalf("beklenen 403, gelen %d", w.Code)
	}
	// Asıl kritik kontrol: yetkisiz istek iş katmanına HİÇ ulaşmamalı.
	if stub.reached {
		t.Fatal("yetkisiz istek service katmanına ulaştı")
	}
}
```

---

## 3. Ne test edilir

**[TEST-07] ZORUNLU:** Her yeni endpoint için en az üç test: **mutlu yol**, **yetki reddi**,
**kötü girdi**.

**[TEST-08] ZORUNLU:** Sınır değerleri test edilir: boş, `nil`, `0`, negatif, maksimum + 1,
çok uzun metin, çok büyük sayfa, `(0,0)` koordinat, geçersiz UTF-8.
> Hataların çoğu ortada değil, sınırda çıkar.

**[TEST-09] ZORUNLU:** Düzeltilen her hata için **önce testi yaz** (kırmızı), sonra
düzelt (yeşil). Testsiz düzeltme, aynı hatanın altı ay sonra geri dönmesini engellemez.

**[TEST-10] ZORUNLU:** Bu standarttaki "tuzak"ların testi yazılır:
- Üç durumlu tarih tipi: açık `null` gönderiminde `UnmarshalJSON` çağrılıyor mu ([API-11])
- `meta.limit` ile dönen kayıt sayısı uyumlu mu ([API-18])
- Sayfalı sorguda sayfalar arası tekrar/atlama var mı ([API-27])
- Kısmi güncellemede gönderilmeyen alanlar `nil` mi ([API-06])

**[TEST-11] ÖNERİLEN:** Karmaşık saf mantık için tablo testi kullan:

```go
tests := []struct {
	name    string
	lat     float64
	lon     float64
	wantErr bool
}{
	{"geçerli", 41.19, 28.73, false},
	{"null island", 0, 0, true},
	{"enlem sınır dışı", 91, 28.73, true},
	{"boylam sınır dışı", 41.19, 181, true},
}
for _, tt := range tests {
	t.Run(tt.name, func(t *testing.T) { ... })
}
```

---

## 4. Entegrasyon testi

**[TEST-12] ÖNERİLEN:** Repository katmanı **gerçek Postgres**'e karşı test edilir;
mock DB kullanılmaz.
> **Neden:** Mock DB, SQL'inin doğru olduğunu değil, mock'un doğru yazıldığını doğrular.
> Kolon adı hatası, constraint ihlali, tip uyumsuzluğu ancak gerçek DB'de çıkar.

```go
//go:build integration

func TestParkingRepository_Create_DuplicateOriginalID_ReturnsConflict(t *testing.T) {
	ctx := context.Background()
	pg, err := postgres.Run(ctx, "postgis/postgis:18-3.6")   // testcontainers
	...
}
```

**[TEST-13] ZORUNLU:** Entegrasyon testleri build tag ile ayrılır (`//go:build integration`)
ve ayrı komutla koşar. Günlük geliştirme döngüsünü yavaşlatmamalıdır:
```bash
go test ./...                      # hızlı, DB'siz
go test -tags=integration ./...    # CI'da ve merge öncesi
```

**[TEST-14] ZORUNLU:** Migration'lar entegrasyon testinde koşturulur — bozuk bir migration
üretimde değil, CI'da fark edilmelidir.

---

## 5. Koşum ve kapsam

**[TEST-15] ZORUNLU:** CI'da `go test -race ./...` koşar.
> **Neden:** Yarış koşulları başka türlü yakalanamaz; üretimde "bazen oluyor" diye
> aylarca aranan hataların çoğu budur.

**[TEST-16] ZORUNLU:** Test kapsamı (coverage) **hedeftir, kural değildir**. Kritik yollar
(yetki, doğrulama, para/veri bütünlüğü) **%100'e yakın** olmalı; getter/setter kapsamı
için test yazmak zaman kaybıdır.
> Varsayılan alt sınır: `internal/service` ve `internal/handler` için **%70**.

**[TEST-17] YASAK:** Zayıf test. Yalnızca "hata dönmedi" kontrol eden test, kod değişince
kırılmaz ve hiçbir şeyi korumaz. Dönen **değeri** doğrula.

**[TEST-18] YASAK:** Kırılgan test. Hata mesajının tam metnine bağlı assertion, ilk metin
düzeltmesinde kırılır — status kodunu ve sentinel hatayı (`errors.Is`) doğrula.

**[TEST-19] YASAK:** Sürekli kırılan testi `t.Skip` ile susturmak. Ya düzelt ya sil —
atlanmış test, yanlış bir güven duygusu üretir.

**[TEST-20] ZORUNLU:** Testte `time.Sleep` ile beklemek yerine kanal/`Eventually` deseni
kullanılır. Sleep'li test yavaştır ve yavaş makinede rastgele kırılır (flaky).

---

## 6. Uçtan uca doğrulama (merge öncesi)

**[TEST-21] ZORUNLU:** Yeni servis/endpoint için elle bir kez şunlar denenir ve sonucu
PR'a yazılır:

```
□ Compose ile ayağa kalkıyor, /health ve /ready 200
□ CRUD akışı gateway ÜZERİNDEN çalışıyor (doğrudan servise değil)
□ Aynı benzersiz değerle ikinci POST        → 409
□ Sınırı aşan metin                          → 400
□ Eksik zorunlu alan (tek koordinat vb.)     → 400
□ Geçersiz UUID                              → 400
□ Yetkisiz kullanıcı                         → 403
□ Gateway header'ı olmadan doğrudan çağrı    → 403
□ ?limit=500 → meta.limit ile dönen kayıt sayısı uyumlu
□ Tüm sayfalar gezildiğinde toplam = total_items (tekrar/atlama yok)
```

**[TEST-22] ZORUNLU:** Yetki/seed gibi sessiz başarısız olabilen şeyler **log'a bakarak**
değil, **veri kaynağından sorgulanarak** doğrulanır:
```sql
SELECT module, COUNT(*) FROM permissions WHERE module = 'parking' GROUP BY module;
```
> **Neden:** Seed dosyasındaki tek bir SQL hatası dosyanın tamamını geri alır; servis
> "seed uyarısı" loglayıp normal açılmaya devam eder ve eksik yetkiler ancak kullanıcı
> 403 aldığında fark edilir.

---

## 7. Postman koleksiyonu — canlı sözleşme

Koleksiyon, `03` gereği her serviste bulunur. Ama dosyanın var olması onu doğru yapmaz;
koşulmayan koleksiyon bir belge bile değildir, çünkü yanlış olduğu hiç anlaşılmaz.

**Ölçüm (2026-09-08, referans depo):** 47 servisin **27**'sinde koleksiyon var, yani 20
servis `03`'ün zorunluluğunu hiç karşılamıyor. Bu 27 koleksiyon toplam **423** istek
içeriyor, ama içlerinden yalnızca **9**'unda herhangi bir test scripti var. Yani
koleksiyonların üçte ikisi, koşulsalar bile hiçbir şey doğrulamaz.

**[TEST-23] ZORUNLU:** Koleksiyon CI'da `arac/koleksiyon-kosum.sh` ile koşar ([CI-27]).
Koşmayan koleksiyon ölü artefakttır ve `15`'teki "çalışır durumda" maddesi onun için
imzalanamaz.
> **Neden:** Koleksiyon, API'nin yürütülebilir sözleşmesidir. Endpoint yolu değişir,
> koleksiyon eski kalır, ve onu ilk açan kişi (çoğunlukla frontend geliştiricisi)
> çalışmayan istekle uğraşır. Bu, standardın kendi ilkesine de aykırıdır ([ARAC-03]):
> mekanik olarak kontrol edilebilen bir şey code review'a bırakılmaz.

**[TEST-24] ZORUNLU:** Koleksiyondaki her istek en az bir assertion içerir. En azından
durum kodu ve yanıt zarfı ([API-01]) doğrulanır:

```js
// Postman "Tests" sekmesi — her istekte en az bu kadarı bulunur.
pm.test("durum 200", () => pm.response.to.have.status(200));
pm.test("zarf doğru", () => {
  const b = pm.response.json();
  pm.expect(b).to.have.property("data");      // liste ucunda ayrıca b.meta
});
```
> **Neden:** Assertion'suz koşum yalnızca "sunucu bir şey döndü" der. Ölçüm bunun teorik
> bir kaygı olmadığını gösteriyor: koleksiyonların üçte ikisi bugün tam olarak bu durumda.
> Gövdesi `null` dönen bir uç, assertion olmadan yeşil görünür.

**[TEST-25] ZORUNLU:** Koleksiyon gateway üzerinden koşar, doğrudan servise değil
([TEST-21] ile aynı gerekçe). Taban URL ortam değişkeninden gelir; koleksiyona sabit
`localhost:PORT` yazılmaz.
> **Neden:** Doğrudan servise vuran koleksiyon gateway'in yetki ve normalizasyon katmanını
> atlar; üretimde 403 verecek bir çağrı testte 200 verir.

---

## 8. Fuzzing — sınır değerlerinin otomatik hâli

[TEST-08] sınır değerlerini **elle** sayar. Fuzzing bunun otomatik hâlidir ve Go 1.18'den
beri standart kütüphanededir; yani [ADR-0011]'in "stdlib + stub + testcontainers" kararını
bozmaz, yeni bağımlılık getirmez.

**[TEST-26] ÖNERİLEN:** Dış girdiyi ayrıştıran her fonksiyon için bir fuzz hedefi yazılır.
Doğal hedefler:

| Hedef | Neden burası |
|---|---|
| GeoJSON / koordinat ayrıştırma | Kapanmayan halka, ters sarım, Null Island, NaN, kutup dışı enlem ([GIS-01]) |
| Üç durumlu tarih `UnmarshalJSON` ([API-11]) | `null`, alan yok, boş string, geçersiz format: dördü de farklı davranmalı |
| Türkçe metin normalizasyonu ([TRK-05]) | ı/İ, birleştirilmiş Unicode, sıfır genişlikli karakter |
| `clampPagination` ([YAP-18]) | Negatif, sıfır, `MaxInt`, taşma |
| Filtre/sıralama ayrıştırma ([API-26]) | Beyaz liste dışı kolon adı, araya sıkıştırılmış SQL parçası |

```go
// internal/dto/tarih_fuzz_test.go
func FuzzUcDurumluTarih(f *testing.F) {
    // Tohum korpusu: bilinen üç durum + bir geçersiz biçim.
    f.Add(`{"tarih":"2026-09-08T00:00:00Z"}`)
    f.Add(`{"tarih":null}`)
    f.Add(`{}`)
    f.Add(`{"tarih":"08.09.2026"}`)

    f.Fuzz(func(t *testing.T, govde string) {
        var d GuncellemeIstegi
        // Tek beklenti: PANİK ETME. Hata döndürmek geçerli bir sonuçtur.
        _ = json.Unmarshal([]byte(govde), &d)
    })
}
```

**[TEST-27] ZORUNLU:** Fuzz yazıldıysa, bulduğu her çökme girdisi `testdata/fuzz/` altına
commit'lenir. O dosya artık kalıcı bir regresyon testidir.
> **Neden:** Fuzzing rastgeledir; aynı çökmeyi ikinci kez bulacağının garantisi yoktur.
> Korpusa girmeyen bulgu, bulunmamış sayılır.

**[TEST-28] ZORUNLU:** CI'da fuzz **süreli** koşar (`-fuzztime=30s`), süresiz değil.
Korpustaki girdiler ise her `go test` koşumunda normal test olarak zaten çalışır.
> **Neden:** Süresiz fuzz CI'ı sonsuza kadar meşgul eder. Otuz saniye yeni girdi aramak
> için azdır, ama regresyonu yakalamak için gerekmez; onu korpus yapar. Derin arama gece
> koşumuna bırakılır.

---

## 9. ASLA YAPMA — test

- ❌ Test yazmadan "çalışıyor" demek
- ❌ Her testi gerçek DB'ye bağlamak
- ❌ Repository'yi mock DB ile test etmek
- ❌ Yalnızca "hata dönmedi" kontrol eden test
- ❌ Hata mesajı metnine bağlı assertion
- ❌ Testler arası sıra/veri bağımlılığı
- ❌ `t.Skip` ile kırık testi susturmak
- ❌ `time.Sleep` ile senkronizasyon
- ❌ Yalnızca mutlu yolu test etmek
- ❌ Düzeltilen hatayı testsiz kapatmak
- ❌ Kapsam yüzdesini test kalitesi sanmak
- ❌ Seed/yetki yüklemesini log'a bakarak doğrulamak
- ❌ Assertion içermeyen Postman koleksiyonunu "çalışıyor" saymak
- ❌ Fuzz'ın bulduğu çökme girdisini korpusa eklemeden düzeltmek
