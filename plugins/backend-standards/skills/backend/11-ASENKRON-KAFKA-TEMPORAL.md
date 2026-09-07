# 11 — Asenkron İşler: Kafka ve Temporal

> Varsayılan senkrondur. Asenkronluk **karmaşıklık satın alarak** dayanıklılık ve ölçek
> satın almaktır; ihtiyaç kanıtlanmadan alınmaz.

---

## 1. Hangi aracı ne zaman

**[ASYNC-01] ZORUNLU:** Sırayla değerlendir, ilk yeteni kullan:

| Durum | Çözüm |
|---|---|
| İş < 300 ms sürüyor ve sonucu istemci bekliyor | **Senkron** yap. Kuyruk ekleme. |
| İş uzun ama tek servisi ilgilendiriyor, kaybı tolere edilemez | **Postgres tabanlı iş kuyruğu** (`FOR UPDATE SKIP LOCKED`) |
| Bir olayı **birden fazla** servis dinliyor / dinleyecek | **Kafka** |
| Çok adımlı, saatler-günler süren, telafi (compensation) gerektiren süreç | **Temporal** |

**[ASYNC-02] ZORUNLU:** p95'i 3 saniyeyi aşan uçlar asenkron olur ([PERF-01]): istek
**202 Accepted** + iş kimliği döner, istemci durumu ayrı bir uçtan sorar.

**[ASYNC-03] ÖNERİLEN:** Küçük/orta ölçekte Kafka'ya koşma. Tek tüketicisi olan bir iş
için Postgres kuyruğu yeterlidir ve işletmesi kat kat ucuzdur:

```sql
-- SKIP LOCKED: iki worker aynı işi almaz, birbirini de beklemez.
UPDATE jobs SET status = 'running', started_at = now()
WHERE id = (
    SELECT id FROM jobs
     WHERE status = 'pending' AND run_after <= now()
     ORDER BY run_after, id
     FOR UPDATE SKIP LOCKED
     LIMIT 1
)
RETURNING id, payload;
```

---

## 2. Ortak kurallar (her asenkron sistem için)

**[ASYNC-04] ZORUNLU:** Tüketici **idempotent**tir. Aynı mesaj iki kez işlenirse sonuç
değişmemelidir.
> **Neden:** Kafka, Temporal ve HTTP retry'ların hepsi **at-least-once** teslimat verir.
> "Tam bir kez" garantisi pratikte yoktur; idempotency tüketicinin sorumluluğudur.

Uygulama: her mesajın bir `event_id`'si olur, işlenen id'ler tabloda tutulur:
```sql
INSERT INTO processed_events (event_id, processed_at) VALUES ($1, now())
ON CONFLICT (event_id) DO NOTHING;   -- 0 satır etkilendiyse: zaten işlenmiş, atla
```

**[ASYNC-05] ZORUNLU:** Mesaj **kendi kendine yeter**. Alıcının veriyi geri çağırmak için
üreticiye HTTP atması gerekiyorsa sıkı bağ (coupling) kurulmuş demektir; üretici düştüğünde
tüketici de düşer.

**[ASYNC-06] ZORUNLU:** Mesaj şeması **versiyonlanır** ve geriye uyumlu değişir. Alan
eklenir, silinmez ([API-29]). Tüketici tanımadığı alanı **yok sayar**, hata vermez.

```json
{
  "event_id": "9f3c...",
  "event_type": "parking.updated",
  "version": 1,
  "occurred_at": "2026-08-12T10:00:00Z",
  "producer": "parking-service",
  "data": { "id": "…", "name": "…" }
}
```

**[ASYNC-07] ZORUNLU:** Kalıcı olarak işlenemeyen mesaj **DLQ**'ya (dead letter queue)
gider; sonsuza kadar retry edilmez.
> **Neden:** "Zehirli mesaj" (poison message) sonsuz retry döngüsünde partition'ı bloklar
> ve arkasındaki tüm mesajlar bekler. Tek bozuk kayıt tüm akışı durdurur.

**[ASYNC-08] ZORUNLU:** DLQ **izlenir** ve boşaltma prosedürü yazılıdır. Kimsenin bakmadığı
DLQ, sessizce kaybolan veridir.

**[ASYNC-09] ZORUNLU:** Kuyruk derinliği ve tüketici gecikmesi (consumer lag) metriktir
([OBS-12]); artan trend alarm üretir ([RES-24]).

**[ASYNC-10] ZORUNLU:** Worker'lar da graceful shutdown yapar: SIGTERM'de **yeni mesaj
almayı bırakır**, işlenmekte olanı bitirir, sonra kapanır.

---

## 3. Kafka

**[ASYNC-11] ZORUNLU:** İstemci `franz-go`'dur ([02](02-TEKNOLOJI-SURUMLERI.md)). Kafka
KRaft modunda çalışır; ZooKeeper kullanılmaz.

**[ASYNC-12] ZORUNLU — Topic adlandırma:** `<alan>.<varlık>.<olay>` — küçük harf, nokta ile.
```
parking.occupancy.changed
market.stall.created
auth.user.deactivated
```
Ortam ayrımı topic adında değil, **ayrı cluster/namespace** ile yapılır.

**[ASYNC-13] ZORUNLU:** Partition anahtarı, **sıra garantisi gereken** birimdir — genelde
varlık id'si.
> **Neden:** Kafka sırayı yalnızca partition içinde garanti eder. Anahtar verilmezse aynı
> kaydın "oluşturuldu" ve "güncellendi" olayları farklı partition'lara düşer ve tüketici
> güncellemeyi oluşturmadan önce görebilir.

**[ASYNC-14] ZORUNLU:** Offset commit'i **işlem başarıyla bittikten sonra** yapılır.
Otomatik commit ile "aldım, commit ettim, sonra çöktüm" senaryosunda mesaj kaybolur.

**[ASYNC-15] ZORUNLU:** Üretici ayarları: `acks=all`, `enable.idempotence=true`,
sıkıştırma açık (`lz4`/`zstd`).
> `acks=1` lider çökmesinde mesaj kaybettirir; `acks=all` bunu engeller.

**[ASYNC-16] ZORUNLU:** Topic'lerin `retention` ve `partition` sayısı **açıkça** belirlenir.
Partition sayısı sonradan **artırılabilir ama azaltılamaz** ve artırmak mevcut anahtar
dağılımını bozar — baştan makul seç.

**[ASYNC-17] ZORUNLU — Transactional Outbox.** DB yazması ile event üretimi **aynı
transaction**'da olmalıdır:

```sql
BEGIN;
  UPDATE parkings SET occupied_capacity = $1 WHERE id = $2;
  INSERT INTO outbox (id, topic, key, payload) VALUES (...);
COMMIT;
-- Ayrı bir yayıncı süreç outbox'ı okur, Kafka'ya basar, satırı işaretler.
```
> **Neden:** DB'ye yazıp Kafka'ya yazmadan çökersen event kaybolur; Kafka'ya yazıp DB'ye
> yazmadan çökersen olmayan bir olayı duyurmuş olursun. İki sistem tek transaction'da
> olamaz; outbox bu problemi tek transaction'a indirger.

---

## 4. Temporal

**[ASYNC-18] ÖNERİLEN:** Temporal şu durumlarda kullanılır:
- Çok adımlı, adımları farklı servislerde olan uzun süreçler (onay akışı, sipariş, import)
- Adım başarısız olunca **telafi** (compensation) gereken süreçler (SAGA)
- Zamanlanmış/gecikmeli işler ("3 gün sonra hatırlat")
- İnsan onayı bekleyen, günlerce sürebilen akışlar

**[ASYNC-19] YASAK:** Basit bir kuyruk işi için Temporal kurmak. Temporal bir sunucu, bir
veritabanı ve worker'lar demektir; küçük bir iş için işletme maliyeti faydayı aşar.

**[ASYNC-20] ZORUNLU:** **Workflow kodu deterministik olmalıdır.** İçinde `time.Now()`,
`rand`, doğrudan ağ çağrısı, map üzerinde sırasız iterasyon **kullanılmaz**. Bunların
hepsi **activity** içinde yapılır.
> **Neden:** Temporal workflow'u yeniden oynatarak (replay) durumu kurar. Determinizm
> bozulursa replay farklı sonuç üretir ve workflow kalıcı olarak bozulur — üstelik bu,
> haftalar sonra bir yeniden başlatmada ortaya çıkar.

```go
// YANLIŞ — workflow içinde
now := time.Now()

// DOĞRU
now := workflow.Now(ctx)
workflow.Sleep(ctx, time.Hour)          // time.Sleep DEĞİL
workflow.SideEffect(ctx, ...)           // rastgelelik/UUID için
```

**[ASYNC-21] ZORUNLU:** Tüm IO (DB, HTTP, dosya) **activity** içinde yapılır. Activity'ler
idempotent yazılır ([ASYNC-04]) — Temporal onları retry eder.

**[ASYNC-22] ZORUNLU:** Her activity'nin `StartToCloseTimeout` ve `RetryPolicy`'si açıkça
verilir. Varsayılan retry politikası **sonsuzdur**; kalıcı hatalar için
`NonRetryableErrorTypes` tanımla.

**[ASYNC-23] ZORUNLU:** Çalışan workflow'un kodu değiştirilecekse **versiyonlama** kullanılır
(`workflow.GetVersion`). Kodu doğrudan değiştirmek, o an koşan workflow'ları replay'de bozar.

**[ASYNC-24] ZORUNLU:** Workflow'a büyük veri geçirilmez. Payload'a **referans** (id, S3
anahtarı) konur; veriyi activity çeker. Workflow geçmişi her adımı saklar; büyük payload
geçmişi şişirir ve limitlere takılır.

---

## 5. Tutarlılık

**[ASYNC-25] ZORUNLU:** Asenkron sistemde **eventual consistency** vardır ve bu API
dokümanına yazılır. "Kayıt oluşturuldu ama listede yok" davranışı sürpriz olmamalıdır.

**[ASYNC-26] ZORUNLU:** Dağıtık transaction (2PC) kullanılmaz. Çok adımlı iş SAGA ile
kurulur: her adımın bir **telafi adımı** vardır ve hata durumunda ters sırayla işletilir.

**[ASYNC-27] ZORUNLU:** Telafi edilemeyen adımlar (e-posta gönderimi, ödeme çekimi) akışın
**en sonuna** konur. Geri alınamayan işi önce yapıp sonrasında hata almak, elde
düzeltilemeyen bir durum bırakır.

---

## 6. ASLA YAPMA — asenkron

- ❌ İhtiyaç kanıtlanmadan kuyruk/Kafka/Temporal eklemek
- ❌ İdempotent olmayan tüketici
- ❌ Sonsuz retry (DLQ'suz)
- ❌ İzlenmeyen DLQ
- ❌ DB yazması ile event üretimini ayrı transaction'larda yapmak (outbox'sız)
- ❌ Partition anahtarını atlayıp sıra garantisi beklemek
- ❌ İşlemden **önce** offset commit etmek
- ❌ `acks=1` ile kritik event üretmek
- ❌ Workflow içinde `time.Now()` / `rand` / doğrudan IO
- ❌ Timeout ve retry politikası verilmemiş activity
- ❌ Çalışan workflow'un kodunu versiyonlamadan değiştirmek
- ❌ Workflow payload'ında büyük veri taşımak
- ❌ Telafi edilemeyen adımı akışın başına koymak
- ❌ Graceful shutdown yapmayan worker
