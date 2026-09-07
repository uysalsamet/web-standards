# ADR-0012 — Metrik ve trace: Prometheus + OpenTelemetry

- **Durum:** Kabul edildi
- **Tarih:** 2026-08-12
- **İlgili kurallar:** [OBS-09], [OBS-10], [OBS-14], [OBS-15]

## Bağlam

Metrik (ne kadar/ne sıklıkta) ve trace (süre nerede geçti) ayrı problemlerdir ve ayrı
araçlarla çözülebilir; ya da tek bir standartla (OTel) birleştirilebilir.

## Seçenekler — metrik

### A) prometheus/client_golang + Prometheus (SEÇİLDİ)
**Güçlü:** Fiilî standart. Pull modeli, servis düşse bile "scrape başarısız" olarak
görünür. PromQL güçlü ve yaygın biliniyor. Grafana ile doğal entegrasyon. Alarm kuralları
([OBS-21]) aynı yerde.
**Zayıf:** Pull modeli kısa ömürlü işlerde (batch job) zorluk çıkarır — Pushgateway gerekir.
Uzun süreli saklama için ek çözüm (Thanos/Mimir/VictoriaMetrics) gerekir.

### B) OTel metrics (tek standart)
**Güçlü:** Metrik + trace + log tek SDK, tek yapılandırma. Satıcı bağımsız.
**Zayıf:** Metrik tarafı, trace tarafı kadar olgun değil ve ekosistem hâlâ Prometheus
formatına dönüyor. İki katman (OTel → Prometheus exporter) fazladan karmaşıklık.

### C) VictoriaMetrics
**Güçlü:** Prometheus uyumlu, daha az kaynak, uzun saklama yerleşik.
**Zayıf:** Prometheus'a göre daha küçük topluluk. Ölçeğimiz bunu gerektirmiyor.

## Seçenekler — trace

### D) OpenTelemetry v1.45.0 (SEÇİLDİ)
**Güçlü:** Satıcı-bağımsız standart; backend'i (Jaeger, Tempo, ticari APM) sonradan
değiştirebilirsin. `otelgin` ile Gin entegrasyonu hazır. Bağlam yayılımı (`traceparent`)
standartlaşmış ([OBS-15]).
**Zayıf:** SDK yapılandırması ilk kurulumda ayrıntılı. Örnekleme stratejisi bilinçli
bir karar gerektirir ([OBS-17]).

### E) Doğrudan Jaeger istemcisi
**Güçlü:** Daha az soyutlama.
**Zayıf:** Jaeger kendi istemcilerini kullanımdan kaldırıp OTel'e yönlendirdi. Yeni
projede tercih edilmez.

## Karar

**Metrik için Prometheus, trace için OpenTelemetry.**

Her iki alanda da kendi olgun standardını kullanıyoruz. OTel'i metrik için de kullanıp
"tek SDK" elde etmek cazip ama bugün fazladan bir dönüşüm katmanı demek; kazancı yok.

Trace [OBS-14] uyarınca **önerilendir, zorunlu değil** — üç veya daha fazla servisin
zincirlendiği akışlar ortaya çıkmadan kurulması erken optimizasyondur.

## Kabul ettiğimiz maliyetler

- İki ayrı SDK ve iki ayrı yapılandırma.
- Prometheus'un uzun süreli saklama sınırı; ihtiyaç doğarsa ek bileşen gerekecek
  ([PERF-26] saklama süresi kuralı bunu erteliyor).

## Kararı ne değiştirir

- OTel metrics ekosistemi olgunlaşır ve Prometheus exporter'ı gereksiz hâle gelirse
  tek SDK'ya geçilir.
- Metrik hacmi Prometheus'un tek düğümünü zorlarsa VictoriaMetrics/Mimir değerlendirilir.
