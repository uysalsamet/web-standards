# ADR-0005 — Loglama: log/slog (stdlib)

- **Durum:** Kabul edildi
- **Tarih:** 2026-08-12
- **İlgili kurallar:** [OBS-01], [OBS-06], [VER-05], [VER-07]

## Bağlam

Log yapısal (JSON) olmalı ki aranabilsin ([OBS-01]). Go 1.21'den beri stdlib'de
`log/slog` var; öncesinde bu iş üçüncü parti kütüphanelerle yapılıyordu.

## Seçenekler

### A) log/slog — stdlib (SEÇİLDİ)
**Güçlü:** **Sıfır bağımlılık.** Stdlib olduğu için ekosistem ona doğru kayıyor;
kütüphaneler `slog.Handler` üzerinden entegre oluyor. `With()` ile bağlam taşıma, seviye
yönetimi, JSON handler hazır. Terk edilme riski yok.
**Zayıf:** zerolog/zap'e göre daha fazla allocation — saniyede on binlerce satır yazan
sistemlerde ölçülebilir fark.

### B) zerolog
**Güçlü:** Sıfıra yakın allocation, çok hızlı, zarif zincirleme API.
**Zayıf:** Bağımlılık. Ekosistem entegrasyonları için adaptör gerekir.

### C) zap (uber-go)
**Güçlü:** Çok hızlı, olgun, kurumsal kullanımda yaygın.
**Zayıf:** İki katmanlı API (`Logger` / `SugaredLogger`) gereksiz yere karmaşık.
Bağımlılık.

### D) logrus
**Güçlü:** Tarihsel olarak en yaygın; çok örnek var.
**Zayıf:** Bakım modunda. Yeni projede kullanılmaz.

## Karar

**log/slog.** Log hızı bizim darboğazımız değil — bir isteğin süresinin ezici çoğunluğu
DB'de geçiyor ([09](../09-PERFORMANS-MALIYET.md)); log satırı başına birkaç yüz
nanosaniyelik fark toplam gecikmede görünmez. Buna karşılık bağımlılık kazancı somut:
yükseltilecek, güvenlik taraması yapılacak, terk edilme riski taşıyacak bir paket daha yok.

[VER-07] ("stdlib çözüyorsa paket çekme") burada birebir uygulanıyor.

## Kabul ettiğimiz maliyetler

- Yüksek hacimli log senaryosunda zerolog'un allocation avantajından vazgeçtik.
- Bazı üçüncü parti kütüphaneler kendi log arayüzlerini bekler; köprü yazmak gerekebilir.

## Kararı ne değiştirir

- Profiling, log allocation'ının sıcak yolda anlamlı pay tuttuğunu **gösterirse**
  ([PERF-18] akışıyla ölçülmüş olmak şartıyla) zerolog değerlendirilir.
- Bu ölçüm olmadan "daha hızlı" gerekçesiyle değişiklik önerisi kabul edilmez.
