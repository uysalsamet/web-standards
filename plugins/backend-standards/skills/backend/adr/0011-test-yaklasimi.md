# ADR-0011 — Test: stdlib testing + stub + testcontainers

- **Durum:** Kabul edildi
- **Tarih:** 2026-08-12
- **İlgili kurallar:** [TEST-01], [TEST-05], [TEST-12], [VER-05]

## Bağlam

Üç ayrı karar: (1) assertion kütüphanesi kullanacak mıyız, (2) bağımlılıkları mock mu
stub mu edeceğiz, (3) repository'yi neye karşı test edeceğiz.

## Seçenekler — assertion

### A) stdlib `testing` (SEÇİLDİ)
**Güçlü:** Sıfır bağımlılık. Hata mesajını sen yazarsın, yani **anlamlı** olur
(`beklenen 403, gelen %d`). Go ekibinin önerdiği yol.
**Zayıf:** Daha uzun; `if got != want { t.Fatalf(...) }` tekrarı.

### B) testify
**Güçlü:** `assert.Equal(t, want, got)` kısa ve okunaklı; zengin matcher seti; mock paketi.
**Zayıf:** Bağımlılık. `assert` (devam eder) ile `require` (durur) ayrımı sürekli
karıştırılır; `assert` kullanılan bir testte ilk hata sonrası nil pointer panic'i sık görülür.

## Seçenekler — çift (double) stratejisi

### C) Elle yazılmış stub (SEÇİLDİ)
**Güçlü:** Service/repository zaten interface ([GEN-07]) olduğu için stub yazmak birkaç
satır. `reached bool` gibi teste özgü alanlar eklenebilir — [TEST-06]'daki "reddedilen
istek service'e ulaşmadı mı" kontrolü bu sayede mümkün.
**Zayıf:** Interface değişince stub'lar elle güncellenir.

### D) mockgen / testify mock ile üretilen mock
**Güçlü:** Interface değişince yeniden üretilir; çağrı doğrulaması (times, order) hazır.
**Zayıf:** Kod üretimi adımı; üretilen mock'lar okunmaz ve gözden geçirilmez. Aşırı
belirtilmiş mock'lar (her çağrıyı doğrulayan) testi kırılgan yapar — refactor edilince
davranış aynı kalsa bile test kırılır.

## Seçenekler — repository testi

### E) testcontainers-go + gerçek Postgres (SEÇİLDİ)
**Güçlü:** SQL'in **gerçekten** çalıştığını doğrular: kolon adı, constraint, tip
uyumsuzluğu, `ON CONFLICT` davranışı, migration'ın kendisi. Bunların hiçbiri mock DB ile
yakalanamaz.
**Zayıf:** Yavaş (konteyner başlatma) ve Docker gerektirir → build tag ile ayrılır
([TEST-13]).

### F) sqlmock (mock DB)
**Güçlü:** Hızlı, Docker gerekmez.
**Zayıf:** SQL'inin doğru olduğunu değil, **mock'un doğru yazıldığını** doğrular. Kolon
adı yanlışsa test geçer, üretim patlar. Yanlış güven üretir.

## Karar

**stdlib `testing` + elle stub + testcontainers.**

Ortak tema: **testin neyi doğruladığı belirsiz olmasın.** testify'ın kısalığı, mockgen'in
otomasyonu ve sqlmock'un hızı — üçü de bir belirsizlik ya da yanlış güven karşılığında
geliyor. Elle yazılan stub ve gerçek DB, ne doğruladığını saklamıyor.

## Kabul ettiğimiz maliyetler

- Testler daha uzun (assertion tekrarı).
- Interface değişince stub'lar elle güncellenir. Derleyici bunu yakalar, yani sessiz
  bir maliyet değil.
- Entegrasyon testleri Docker gerektirir ve yavaştır; bu yüzden ayrı komutla koşar
  ([TEST-13]).

## Kararı ne değiştirir

- Stub bakımı ölçülebilir bir yüke dönüşürse (interface'ler sık değişiyorsa) mockgen
  değerlendirilir.
- Ekip testify'ı zaten her yerde kullanıyorsa tutarlılık adına yeniden tartışılabilir —
  ama o zaman `require` kullanımı zorunlu kılınmalıdır.
