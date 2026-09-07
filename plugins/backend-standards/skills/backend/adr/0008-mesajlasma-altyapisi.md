# ADR-0008 — Mesajlaşma: önce Postgres kuyruğu, gerekirse Kafka (franz-go)

- **Durum:** Kabul edildi
- **Tarih:** 2026-08-12
- **İlgili kurallar:** [ASYNC-01], [ASYNC-03], [ASYNC-11], [ASYNC-17]

## Bağlam

İki ayrı soru var ve sık sık karıştırılıyor:
1. **Asenkron altyapı olarak neyi kullanacağız?** (Kafka mı, NATS mi, kuyruk mu, hiçbiri mi)
2. Kafka kullanılıyorsa **hangi Go istemcisi?**

## Seçenekler — altyapı

### A) Postgres tabanlı iş kuyruğu — varsayılan başlangıç (SEÇİLDİ)
`FOR UPDATE SKIP LOCKED` ile ([ASYNC-03]).
**Güçlü:** **Yeni altyapı bileşeni yok.** İşi uygulama verisiyle **aynı transaction'da**
kuyruğa alabilirsin — outbox problemi ([ASYNC-17]) kendiliğinden çözülür. Yedekleme,
izleme, erişim kontrolü zaten var. Küçük/orta yükte fazlasıyla yeterli.
**Zayıf:** Çok yüksek hacimde (saniyede on binlerce mesaj) DB'yi yorar. Fan-out (bir
olayı çok tüketiciye dağıtmak) elle kurulur. Kalıcı olay günlüğü (event log) semantiği yok.

### B) Kafka 4.3.1 — ölçek/fan-out gerektiğinde (SEÇİLDİ, ikinci aşama)
**Güçlü:** Kalıcı, tekrar okunabilir olay günlüğü. Bir olayı **birden fazla** bağımsız
tüketici okuyabilir ve sonradan katılan tüketici geçmişi baştan işleyebilir. Partition ile
yatay ölçek + anahtar bazlı sıra garantisi. KRaft ile ZooKeeper bağımlılığı kalktı.
**Zayıf:** İşletme maliyeti yüksek — cluster, disk, retention, partition planlaması, izleme.
Yanlış partition sayısı sonradan düzeltilmesi acılı bir karardır ([ASYNC-16]).

### C) NATS JetStream
**Güçlü:** Kafka'ya göre çok daha hafif; tek binary, kolay işletme. Hem request/reply hem
stream. Düşük gecikme.
**Zayıf:** Ekosistem ve operasyonel bilgi birikimi Kafka'ya göre küçük. Connector/CDC
dünyası (Debezium vb.) Kafka etrafında kurulu. Uzun süreli olay günlüğü senaryolarında
Kafka kadar oturmuş değil.

### D) RabbitMQ
**Güçlü:** Zengin yönlendirme (exchange/binding), olgun, iyi bilinen.
**Zayıf:** Bir **kuyruk**tur, olay günlüğü değil — mesaj tüketilince gider, geçmişi
tekrar okuyamazsın. Bizim ihtiyacımızın (olay yayınlama + sonradan katılan tüketici)
tersine çalışır.

### E) Redis Streams
**Güçlü:** Redis zaten varsa ek bileşen yok.
**Zayıf:** Kalıcılık garantileri Kafka seviyesinde değil; Redis'i cache dışı kritik bir
role sokar. [CACHE-24] ile çelişir.

## Seçenekler — Kafka Go istemcisi

### F) franz-go v1.21.6 (SEÇİLDİ)
**Güçlü:** Aktif geliştiriliyor, protokolün tamamını destekliyor (transaction/exactly-once,
KRaft, consumer group'un tüm ayrıntıları), **cgo yok**, performansı iyi.
**Zayıf:** API'si segmentio'ya göre daha alt seviye; öğrenme eğrisi biraz dik.

### G) segmentio/kafka-go v0.4.51
**Güçlü:** Basit ve okunabilir API; hızlı başlanır.
**Zayıf:** Geliştirme hızı yavaşladı (son sürüm Nisan 2026). Transaction desteği zayıf.

### H) confluent-kafka-go
**Güçlü:** librdkafka'yı sarar; en olgun protokol implementasyonu.
**Zayıf:** **cgo gerektirir** — statik binary ve `CGO_ENABLED=0` ile alpine imajı
([OPS-01]) hedefimizle çelişir.

### I) IBM/sarama
**Güçlü:** Uzun geçmiş, çok yaygın.
**Zayıf:** Bakımı devredildi; API'si tarihsel yük taşıyor.

## Karar

**Sırayla ilerle** ([ASYNC-01]):
1. İş < 300 ms ve sonucu istemci bekliyorsa → **senkron**, kuyruk yok.
2. Uzun ama tek tüketicili iş → **Postgres kuyruğu**.
3. Bir olayı **birden fazla** servis dinliyor/dinleyecekse → **Kafka + franz-go**.

Kafka'yı "ileride lazım olur" diye baştan kurmak, işletme maliyetini kazançtan önce
ödemektir. Postgres kuyruğundan Kafka'ya geçiş, outbox deseni ([ASYNC-17]) zaten
kuruluysa mekanik bir iştir.

franz-go seçimi cgo yasağı ve transaction desteği üzerinden netleşti.

## Kabul ettiğimiz maliyetler

- NATS JetStream'in işletme kolaylığından vazgeçtik; Kafka'ya geçtiğimizde daha ağır bir
  altyapı işleteceğiz.
- franz-go'nun daha alt seviye API'si için ince bir sarmalayıcı yazmamız gerekebilir.
- İki aşamalı yaklaşım, geçiş anında bir migrasyon işi doğuracak.

## Kararı ne değiştirir

- Ekip Kafka işletme kapasitesine sahip değilse ve fan-out ihtiyacı doğduysa **NATS
  JetStream** ciddi şekilde yeniden değerlendirilir — bu, en yakın alternatif.
- Debezium/CDC ya da stream processing (Flink vb.) ihtiyacı doğarsa Kafka kaçınılmaz olur.
- Postgres kuyruğu DB yükünün ölçülebilir bir kısmına dönüşürse (izlenir) Kafka'ya
  geçiş zamanı gelmiştir.
