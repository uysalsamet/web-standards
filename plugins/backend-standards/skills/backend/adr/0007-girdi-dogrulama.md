# ADR-0007 — Girdi doğrulama: elle, handler katmanında

- **Durum:** Kabul edildi
- **Tarih:** 2026-08-12
- **İlgili kurallar:** [SEC-12], [SEC-12b], [VER-09], [API-06], [API-07], [API-11]

## Bağlam

Her yazma ucunda girdi doğrulanmalı ([SEC-12]). Gin, `go-playground/validator`'ı
**transitif bağımlılık olarak zaten getiriyor** ve `binding:"required,max=255"` gibi
struct tag'leriyle deklaratif doğrulama sunuyor.

Yani bu karar "fazladan paket çekelim mi" değil — **"zaten elimizde olanı kullanalım mı"**
sorusudur. Gerekçenin de buna göre kurulması gerekir.

## Seçenekler

### A) Elle doğrulama, ortak yardımcılarla (SEÇİLDİ)
**Güçlü:** Pointer/üç-durum tasarımıyla ([API-06], [API-07], [API-11]) uyumlu. Hata
mesajları Türkçe, bağlamlı ve tam kontrolümüzde ([API-15]). Doğrulama sırası ve kısa
devre davranışı açık. `pkg/validator.go` yardımcıları (`ValidateUUID`, `maxLen`,
`nonNegative`, `ValidateCoordinates`) tekrarı toplar.
**Zayıf:** Her alan için açık kontrol satırı; handler'lar uzar.

### B) `binding:"..."` struct tag'leri
**Güçlü:** Kısa, deklaratif, kurallar DTO'da görünür, kod tekrarı az.

**Zayıf — ve belirleyici olan:** `required`, **değer tipinde sıfır değeri "eksik" sayar.**
`{"latitude": 0}` ile "latitude hiç gönderilmedi" aynı muameleyi görür. Bu, standardın
merkezindeki ayrımın tam tersidir:

> [API-07]: eksikliği fark edilmesi gereken alan, zorunlu olsa bile **pointer** olur —
> çünkü `{"name":"X","latitude":41.19}` (longitude yok) isteğinde `longitude` sessizce
> `0` olup noktayı Gana açıklarına taşımıştı.

Pointer alanlarda `required` doğru çalışır (nil kontrolü). Ama o zaman doğrulamanın yarısı
tag'de yarısı elde olur ve "hangisi nerede" tartışması her PR'da tekrarlanır. Ayrıca hata
mesajları İngilizce ve alan-yolu biçiminde gelir; istemciye gösterilebilir hâle getirmek
için ayrı bir çeviri katmanı gerekir.

### C) İkisi birlikte
**Güçlü:** Basit alan kuralları tag'de, iş kuralları elde.
**Zayıf:** Sınırın nerede olduğu her seferinde yeniden tartışılır. Bir standardın amacı
tam olarak bu tartışmayı bitirmektir.

## Karar

**Elle doğrulama.** Tek ve tutarlı bir yol. Belirleyici gerekçe teknik: `required`
semantiği ile pointer/üç-durum tasarımı **uyuşmuyor** ve o tasarım gerçek bir üretim
hatasından doğdu.

## Kabul ettiğimiz maliyetler

- Handler'lar daha uzun; doğrulama satırları tekrar ediyor.
- Bir alanı doğrulamayı **unutmak** mümkün. Karşı önlemler: [SEC-12] minimum kontrol
  tablosu, [SEC-13] iki katmanlı savunma (handler + şema), [TEST-08] sınır değer testleri.

## Kararı ne değiştirir

- DTO'larda pointer/üç-durum ihtiyacı ortadan kalkarsa (ör. kısmi güncelleme JSON Merge
  Patch gibi ayrı bir mekanizmaya taşınırsa) tag tabanlı doğrulama yeniden değerlendirilir.
- Doğrulama kodu tekrarının ölçülebilir bir hata kaynağına dönüştüğü gösterilirse
  (aynı tip hata birden çok serviste tekrarlanıyorsa) hibrit yaklaşım tartışılır.
