# ADR-0001 — HTTP Framework: Gin

- **Durum:** Kabul edildi
- **Tarih:** 2026-08-12
- **İlgili kurallar:** [GEN-01], [GEN-02], [VER-05]

## Bağlam

Tüm HTTP servisleri tek bir framework kullanmalı. Farklı framework'ler demek: farklı
middleware seti, farklı hata gövdesi, farklı test deseni, farklı güvenlik yüzeyi ve
ortak `pkg/` paketinin her serviste farklı davranması demek.

Karar noktası, aday framework'lerin hız farkı değil — **hangi HTTP çekirdeği üzerine
oturdukları**. Gin, Echo ve chi Go'nun `net/http`'i üzerine kuruludur; Fiber ise ayrı
bir implementasyon olan `fasthttp` üzerine.

## Seçenekler

### A) Gin v1.12.0 — `net/http` (SEÇİLDİ)
**Güçlü:**
- `net/http` uyumu → tüm Go ekosistemi çalışır: `otelhttp`/`otelgin`, `httptest`,
  `pprof`, `http.Handler` alan her kütüphane, her middleware.
- HTTP/2 stdlib'den ücretsiz gelir.
- API yıllardır kırılmıyor (v1 hattı). Yavaş release cadence'i burada **avantaj**:
  yükseltme sürprizi yok.
- En büyük Go framework topluluğu → en çok örnek, en çok bilen geliştirici, ve
  **AI'ın en güvenilir kod ürettiği** framework.
- Timeout'lar `http.Server`'da, yani stdlib'in bilinen yerinde ([RES-07]).

**Zayıf:**
- `*gin.Context` bir miktar lock-in yaratır (chi'de bu yok).
- Yerleşik rate limiter yok; kendimiz yazıyoruz ([RES-04]).
- Router'ında statik/parametre kardeşliği tarihsel olarak panik üretmiş bir alandır
  (v1.7'den beri destekleniyor, ama biz belirsizliği hiç yaratmıyoruz — [API-01b]).

### B) Fiber v3.4.0 — `fasthttp`
**Güçlü:**
- Sentetik benchmark'larda en hızlısı; düşük allocation.
- Express benzeri API, JS'ten gelen ekip için tanıdık.
- v3 çok aktif geliştiriliyor; `net/http` handler imzalarını da kabul ediyor.

**Zayıf:**
- **HTTP/2 yok.** `fasthttp`'nin mimarisi HTTP/2 ile uyuşmuyor; resmî destek hâlâ
  "under construction". Tarayıcının doğrudan konuştuğu servislerde (tile, statik)
  bu gerçek bir eksik.
- Ekosistem daha ince; `net/http` bekleyen kütüphanelerde sürtünme.
- v2 → v3 kırıcı geçiş 2026 Şubat'ta yapıldı (`*fiber.Ctx` → `fiber.Ctx`,
  `BodyParser` → `Bind().Body()`). Eğitim verisinin çoğu hâlâ v2 olduğu için **AI
  sürekli v2 sözdizimi üretiyor** ve her seferinde düzeltme gerekiyor.
- `fasthttp`'nin buffer yeniden kullanımı, değerleri handler dışına taşırken kopyalama
  gerektirebilen bir tuzak sınıfı üretir.

**Performans farkı bizim için geçersiz:** bir isteğin süresinin %95+'ı DB sorgusunda
geçiyor (5–50 ms). Framework payı mikrosaniyeler mertebesinde; ölçülemez.

### C) chi v5.3.1 — `net/http`
**Güçlü:** Sıfır lock-in (saf `http.Handler`), en uzun ömürlü teknik seçim, stdlib
idiomlarına en yakın, minimal.
**Zayıf:** Binding, hata yönetimi, yanıt yardımcıları — hepsini kendin kurarsın.
Standardın yazması gereken kural sayısı artar ve her ekip kendi çözümünü üretir; bu,
"tek standart" amacının tersine çalışır.

### D) Echo v5.3.1 — `net/http`
**Güçlü:** Gin'e çok yakın, `net/http` tabanlı, batteries-included.
**Zayıf:** Gin'e göre belirgin bir üstünlüğü yok; topluluk ve örnek havuzu daha küçük.
İki benzer seçenekten daha yaygın olanı seçmek, tie-break olarak yeterlidir.

## Karar

**Gin v1.12.0.** Belirleyici üç sebep:

1. **`net/http` uyumu** — ekosistem sürtünmesini sıfırlar, HTTP/2'yi ücretsiz getirir.
2. **API stabilliği** — yükseltmeler sürpriz üretmiyor; standardın kod örnekleri yıllarca
   geçerli kalır.
3. **AI güvenilirliği** — bu standart AI ajanları tarafından uygulanacak. Gin'in devasa
   ve tutarlı korpusu, üretilen kodun ilk seferde doğru olma oranını belirgin şekilde
   yükseltiyor.

Performans bu kararda **hiç** rol oynamadı; oynamamalıydı da.

## Kabul ettiğimiz maliyetler

- Fiber'ın sentetik benchmark üstünlüğünden vazgeçtik. (Bizim yükümüzde ölçülemez.)
- `*gin.Context` lock-in'i kabul ettik; chi'nin sıfır-lock-in avantajını almadık.
  Karşılığında binding/hata/yanıt için hazır ve tek bir yol aldık.
- Rate limit middleware'ini kendimiz yazıyoruz (~40 satır, [RES-04]).
- **En büyük maliyet:** Fiber ile yazılmış mevcut servisler bir süre yerinde kalacak,
  yani repolar geçiş boyunca **karışık** olacak. Bu bilinçli bir karardır ([VER-17],
  [VER-18]): bundan sonra yazılan her servis Gin'dir, eskiler dokunulduğu zaman tek tek
  taşınır. Toplu migrasyon projesi yapılmıyor — 34 servisi bir seferde çevirmek, tüm
  ekibi haftalarca durduran ve hiçbir kullanıcı değeri üretmeyen bir iş olurdu.
  Karışıklığın bedeli, kopyala-yapıştır riskiyle sınırlı ve [VER-18]'deki karşı
  önlemlerle yönetiliyor.

## Kararı ne değiştirir

- `fasthttp` gerçek ve stabil HTTP/2 desteği yayınlarsa Fiber'ın en büyük eksiği kapanır.
- Gin'in geliştirmesi durursa (12 aydan uzun commit yokluğu) chi'ye geçiş değerlendirilir.
- Projede gRPC/HTTP/2-ağırlıklı bir ihtiyaç doğarsa [ADR-0013](0013-api-protokolu.md)
  ile birlikte yeniden bakılır.
- Ölçülmüş, gerçek bir yük altında framework'ün darboğaz olduğu **gösterilirse** —
  bu bugüne kadar hiçbir CRUD servisinde olmadı, ama olursa kayıt yeniden açılır.
