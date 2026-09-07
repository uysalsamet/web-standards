# 20 — Toplu Veri, Zamanlanmış İş, Bildirim, Webhook ve Canlı Akış

> Ortak tema: **bu işlerin hiçbirinde kullanıcı ekranın başında beklemiyor.** Bir şey
> yanlış giderse kimse anında fark etmez. Bu yüzden hepsinin ortak zorunluluğu aynı:
> **idempotent ol, sonucu kaydet, başarısızlığı görünür kıl.**

---

# 1. Toplu veri içe aktarma (ETL)

Belediye/kurum verisinin dosyadan sisteme aktarılması. Genelde tek seferlik sanılır,
gerçekte defalarca çalıştırılır — ve her çalıştırma bir öncekini bozma riski taşır.

**[ETL-01] ZORUNLU:** Her içe aktarma çalıştırması **kayıt altına alınır**:

```sql
CREATE TABLE import_runs (
    id            UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    source        TEXT NOT NULL,          -- dosya adı / kaynak sistem
    source_hash   TEXT,                   -- kaynak dosyanın SHA-256'sı
    started_at    TIMESTAMPTZ NOT NULL DEFAULT now(),
    finished_at   TIMESTAMPTZ,
    status        TEXT NOT NULL,          -- running | success | failed | partial
    rows_total    INT,
    rows_inserted INT,
    rows_updated  INT,
    rows_skipped  INT,
    rows_failed   INT,
    error_report  JSONB,                  -- hatalı satırlar: satır no + sebep
    triggered_by  UUID                    -- kim başlattı
);
```
> **Neden `source_hash`:** "Bu dosyayı daha önce yükledik mi" sorusunun kesin cevabı.
> Dosya adı yeterli değildir; aynı ad farklı içerik taşıyabilir.

**[ETL-02] ZORUNLU — İçe aktarma idempotenttir.** Aynı kaynak iki kez çalıştırılırsa
çift kayıt oluşmaz. Doğal anahtar üzerinden upsert yapılır:

```sql
INSERT INTO parkings (original_id, name, total_capacity, ...)
VALUES ($1, $2, $3, ...)
ON CONFLICT (original_id) DO UPDATE SET
    name           = EXCLUDED.name,
    total_capacity = EXCLUDED.total_capacity,
    updated_at     = now()
-- Değişiklik yoksa updated_at'i boşuna güncelleme: "ne zaman gerçekten değişti"
-- bilgisi kaybolur ve gereksiz WAL üretir.
WHERE parkings.* IS DISTINCT FROM EXCLUDED.*;
```
> Doğal anahtar (`original_id`) `UNIQUE` olmalıdır ([DB-08]) — yoksa `ON CONFLICT`
> çalışmaz ve her çalıştırma veriyi çoğaltır.

**[ETL-03] ZORUNLU — Kısmi başarısızlık politikası önceden kararlaştırılır ve yazılır:**

| Politika | Ne zaman | Nasıl |
|---|---|---|
| **Hepsi ya da hiç** | Veri bütünlüğü kritik, kayıtlar birbirine bağlı | Tek transaction; tek satır hatalıysa hepsi geri alınır |
| **Satır satır + rapor** | Bağımsız kayıtlar, kısmi yükleme kabul edilebilir | Her satır kendi transaction'ında; hatalılar raporlanır |

**Karar koda yorum olarak yazılır.** İkisi arasında sessizce gidip gelmek en kötüsüdür.

**[ETL-04] ZORUNLU:** Doğrulama **veritabanına gitmeden** yapılır ([SEC-12] listesi).
Hatalı satır DB'ye gönderilip sürücü hatası beklenmez — hata mesajı anlaşılmaz olur ve
performans çöker.

**[ETL-05] ZORUNLU — Atlanan ve başarısız satırlar SAYILIR ve RAPORLANIR.** Sessizce
atlanan satır yasaktır.
> **Vaka temeli:** [GEN-09] "%100 gerçek veri ve eksiksiz seed" kuralı tam olarak bu
> yüzden var. `1.245/1.245` gibi bir sayım doğrulaması yapılmadığında, eksik aktarılan
> veri aylarca fark edilmez — ve fark edildiğinde hangi kayıtların eksik olduğu bilinmez.

**[ETL-06] ZORUNLU:** İçe aktarma sonrası **sayım doğrulaması** yapılır:
```
kaynak satır sayısı == inserted + updated + skipped + failed
hedef tablo sayısı  == beklenen
```
Tutmuyorsa `status = 'partial'` ve alarm.

**[ETL-07] ZORUNLU:** Büyük veri **parti parti** işlenir (varsayılan 1.000 satır) ve
`pgx.CopyFrom` ([DB-29]) tercih edilir. Tüm dosyayı belleğe alma ([DOSYA-02]).

**[ETL-08] ZORUNLU:** Uzun süren import'un ilerlemesi izlenebilir: `import_runs` satırı
periyodik güncellenir ve metrik yayınlanır ([OBS-12]).

**[ETL-09] ZORUNLU:** Kaynak dosya saklanır (nesne deposunda, [DOSYA-09]) — sonradan
"kaynakta gerçekten ne yazıyordu" sorusunun tek cevabı odur.

**[ETL-10] ZORUNLU:** İçe aktarma **denetim izi** üretir ([AUDIT-01] toplu işlemler) ve
kişisel veri içeriyorsa [16 §2](16-PARA-VE-HASSAS-VERI.md) kuralları geçerlidir.

**[ETL-11] ZORUNLU:** Import ucu ağır uç sınıfındadır ([RES-01]: 10 istek/dk) ve aynı
kaynak için **eşzamanlı çalıştırma engellenir** (dağıtık kilit — [CACHE-19]).

---

# 2. Zamanlanmış işler (cron)

**[JOB-01] ZORUNLU — Çok replikalı kurulumda iş YALNIZCA BİR KEZ çalışır.**

> **En sık yapılan hata bu.** Uygulama içi zamanlayıcı (`time.Ticker`, cron kütüphanesi)
> **her replikada** çalışır. 3 replika = gece yarısı 3 kez çalışan borç hesaplama =
> 3 kat bildirim, 3 kat kayıt.

```go
// Dağıtık kilit ile tekilleştirme. TTL, işin en kötü süresinden uzun olmalı [CACHE-21].
func (w *Worker) runDaily(ctx context.Context) {
	token := uuid.NewString()
	ok, err := w.rdb.SetNX(ctx, "job:daily-debt-calc", token, 10*time.Minute).Result()
	if err != nil || !ok {
		return // başka replika çalıştırıyor — bu normal, hata değil
	}
	defer releaseLock(ctx, w.rdb, "job:daily-debt-calc", token)
	...
}
```
Alternatif: Postgres advisory lock (`pg_try_advisory_lock`) — Redis'e bağımlılık istemiyorsan.

**[JOB-02] ZORUNLU:** İş **idempotenttir**. Kilit alınsa bile süreç ortada ölebilir ve
iş yeniden çalışır; iki kez çalışması zarar vermemelidir.

**[JOB-03] ZORUNLU:** Kaçırılan çalıştırma politikası tanımlıdır: sistem 6 saat kapalı
kaldıysa açılınca **geçmişi telafi mi edecek (catch-up), yoksa atlayacak mı?** Karar
yazılır; varsayılan **atla**, çünkü telafi çoğu zaman istenmeyen toplu bildirim üretir.

**[JOB-04] ZORUNLU:** Her işin **süre sınırı** vardır (`context.WithTimeout`). Sonsuza
kadar süren iş, kilidi tutar ve bir sonraki çalıştırmayı engeller.

**[JOB-05] ZORUNLU — Başarısızlık görünür olur.** Sessizce başarısız olan zamanlanmış iş,
en sinsi arıza türüdür: aylarca çalışmadığı fark edilmez.
- Her çalıştırma sonucu loglanır ve metriğe yazılır
- **Son başarılı çalışma zamanı** izlenir; beklenen aralığın 2 katını aşarsa **alarm**
  ([OBS-21]) — "iş hata verdi" değil, **"iş hiç çalışmadı"** durumunu da yakalar

**[JOB-06] ZORUNLU:** İşler `main`'de değil, ayrı bir worker bileşeninde çalışır ya da
en azından graceful shutdown'a dâhil edilir ([RES-19], [RES-21]).

**[JOB-07] ZORUNLU:** Zaman dilimi açıkça belirtilir. "Her gece 03:00" ifadesi UTC mi
Europe/Istanbul mı? Yaz saati geçişinde 03:00 **iki kez** olabilir ya da **hiç olmayabilir**.
> Varsayılan: iş tanımı UTC'dedir ([ZAM-01]). Yerel saate bağlı olması **iş gereğiyse**
> (ör. mesai başlangıcı) bu açıkça yazılır ve DST testi yapılır.

---

# 3. Bildirim (e-posta / SMS / push)

**[NOTIF-01] ZORUNLU — Gönderim idempotenttir.** Retry'da ikinci SMS gitmez:

```sql
CREATE TABLE notifications (
    id             UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    -- Aynı olay için ikinci kayıt açılamaz: "borç-9f3c-hatirlatma-2026-08"
    idempotency_key TEXT NOT NULL UNIQUE,
    channel        TEXT NOT NULL,     -- email | sms | push
    recipient_ref  UUID NOT NULL,     -- kullanıcı id'si (adres DEĞİL — [KVKK-09])
    template       TEXT NOT NULL,
    status         TEXT NOT NULL,     -- pending | sent | failed | cancelled
    attempts       INT NOT NULL DEFAULT 0,
    sent_at        TIMESTAMPTZ,
    last_error     TEXT
);
```
> **Neden bu kadar önemli:** SMS geri alınamaz. Kullanıcıya 3 kez "borcunuz var" mesajı
> gitmesi, teknik bir hatadan çok bir itibar sorunudur.

**[NOTIF-02] ZORUNLU:** Bildirim **asenkron** gönderilir ([ASYNC-02]); istek yolunda
sağlayıcı beklenmez. Kullanıcı, SMS sağlayıcısı yavaş diye beklememelidir.

**[NOTIF-03] ZORUNLU:** Sağlayıcı hatası asıl işlemi **düşürmez**. Kayıt oluştu, bildirim
gitmediyse: kayıt durur, bildirim retry kuyruğunda kalır ([RES-11]…[RES-14]) ve N denemeden
sonra DLQ'ya düşer ([ASYNC-07]).

**[NOTIF-04] ZORUNLU:** İçerik **şablondan** üretilir; şablonlar kodda gömülü metin olarak
dağıtılmaz. Şablona giren kullanıcı verisi kaçışlanır (HTML e-postada XSS).

**[NOTIF-05] ZORUNLU:** Gönderim kaydında **alıcı adresi değil, kullanıcı referansı**
tutulur. Adres gerekiyorsa gönderim anında kullanıcı kaydından okunur — bildirim tablosu
kişisel verinin ikinci kopyası hâline gelmemelidir ([KVKK-02], [AUDIT-05]).

**[NOTIF-06] ZORUNLU:** Kullanıcı başına ve toplam gönderim **kotası ve rate limit'i**
vardır. Döngüye giren bir kod, saniyede binlerce SMS gönderip hem para hem itibar yakar.

**[NOTIF-07] ZORUNLU — Test/geliştirme ortamından gerçek gönderim YASAK.** Sağlayıcı
sandbox modunda çalışır ya da alıcılar beyaz listeyle sınırlanır.
> Bu kural [KVKK-10] ile aynı aileden: üretim verisiyle test yapmanın en görünür hâli,
> gerçek vatandaşa test SMS'i göndermektir.

**[NOTIF-08] ZORUNLU:** Kullanıcının bildirim tercihleri (izin/ret) saklanır ve gönderim
öncesi kontrol edilir. Ticari nitelikli iletiler için izin yönetimi ayrıca mevzuata tabidir.

---

# 4. Giden webhook

**[HOOK-01] ZORUNLU — Her istek imzalanır** (HMAC-SHA256) ve imzaya **zaman damgası** dâhildir:

```
X-Signature-Timestamp: 1754899200
X-Signature: sha256=<hmac(secret, timestamp + "." + body)>
```
> **Neden zaman damgası:** Yalnızca gövde imzalanırsa, saldırgan eski bir isteği aynen
> tekrar gönderebilir (replay). Alıcı, 5 dakikadan eski zaman damgasını reddetmelidir.

**[HOOK-02] ZORUNLU:** Alıcı URL'i **doğrulanır** — bu bir SSRF yüzeyidir ([DOSYA-18]).
Abone olan taraf iç ağ adresi veremez.

**[HOOK-03] ZORUNLU:** Timeout kısa (**5 sn**, [RES-07]), retry üstel backoff + jitter ile
en fazla birkaç deneme ([RES-13]), sonrasında DLQ ([ASYNC-07]).
> Yavaş bir alıcı, senin sistemini yavaşlatmamalıdır. Webhook gönderimi asla istek
> yolunda yapılmaz.

**[HOOK-04] ZORUNLU:** Teslimat **en az bir kez**tir; alıcının idempotent olması beklenir
ve bu **dokümana yazılır**. Her olayda benzersiz `event_id` gönderilir ([ASYNC-06] gövde
formatı).

**[HOOK-05] ZORUNLU:** Sıra garantisi **yoktur** ve bu da dokümana yazılır. Alıcı sırayı
`occurred_at` ile kurar.

**[HOOK-06] ZORUNLU:** Her teslimat denemesi kaydedilir: hedef, durum kodu, süre, deneme
sayısı. Sürekli başarısız olan abonelikler otomatik askıya alınır ve sahibine bildirilir.

**[HOOK-07] ZORUNLU:** Webhook gövdesinde kişisel veri taşınmaz; kimlik ve referans
gönderilir, alıcı yetkisiyle ayrıntıyı API'den çeker ([KVKK-12]).

---

# 5. Canlı akış (WebSocket / SSE)

**[STREAM-01] ÖNERİLEN — Tek yönlü akışta SSE tercih edilir**, WebSocket değil.
> SSE düz HTTP'dir: gateway'den geçer, yetki mekanizması aynıdır, tarayıcı yeniden
> bağlanmayı kendi yapar. WebSocket ancak **çift yönlü** iletişim gerçekten gerekliyse
> kullanılır — aksi hâlde bedavaya ikinci bir protokol ve ikinci bir güvenlik yüzeyi
> ediniyorsun.

**[STREAM-02] ZORUNLU:** Bağlantı kurulurken yetki kontrol edilir ([GEN-10]) **ve**
uzun ömürlü bağlantılarda **periyodik olarak yeniden** kontrol edilir.
> Yetkisi alınan kullanıcının açık bağlantısı, siz kapatana kadar veri almaya devam eder.
> Access token ömrü ([AUTH-14]) dolduğunda bağlantı kapatılır.

**[STREAM-03] ZORUNLU:** Bağlantı sayısı sınırlıdır: kullanıcı başına (varsayılan **5**)
ve toplam. Her bağlantı bir goroutine ve bir buffer demektir ([RES-22]).

**[STREAM-04] ZORUNLU — Backpressure.** Yavaş istemci sunucuyu bloklamaz:
```go
// Yazma kanalı SINIRLI. Dolduysa istemci mesajları tüketemiyor demektir:
// bağlantıyı kapat. Sınırsız kuyruk, tek yavaş istemcinin belleği tüketmesidir.
select {
case client.send <- msg:
default:
    close(client.send)   // yavaş istemci düşürülür
}
```

**[STREAM-05] ZORUNLU:** Heartbeat/ping gönderilir (varsayılan 30 sn) ve yanıt vermeyen
bağlantı kapatılır. Ölü bağlantılar birikirse kaynak sızıntısıdır.

**[STREAM-06] ZORUNLU:** Graceful shutdown'da açık bağlantılar düzgün kapatılır
(kapanış çerçevesi gönderilir), sertçe kesilmez ([RES-19]).

**[STREAM-07] ZORUNLU:** **Medya akışı uygulama sunucusundan geçirilmez.** Video/kamera
akışı için özel bir bileşen (MediaMTX vb.) kullanılır; Go servisi yalnızca yetkilendirme
ve akış adresi üretimi yapar.
> Medya baytlarını uygulama üzerinden proxy'lemek, konteyner kaynak limitini ([PERF-04])
> tek bir izleyiciyle doldurur.

**[STREAM-08] ZORUNLU:** Akış uçları metriklenir: aktif bağlantı sayısı, düşürülen
bağlantı sayısı, ortalama bağlantı ömrü ([OBS-12]).

---

## 6. ASLA YAPMA

**İçe aktarma**
- ❌ Idempotent olmayan import (ikinci çalıştırma veriyi çoğaltır)
- ❌ Atlanan/başarısız satırı sessizce geçmek
- ❌ Sayım doğrulaması yapmamak
- ❌ Kısmi başarısızlık politikasını yazmamak
- ❌ Tüm dosyayı belleğe almak
- ❌ Kaynak dosyayı saklamamak
- ❌ Aynı kaynağın eşzamanlı iki import'una izin vermek

**Zamanlanmış iş**
- ❌ Çok replikada kilitsiz cron (iş N kez çalışır)
- ❌ Süre sınırı olmayan iş
- ❌ "Hiç çalışmadı" durumunu yakalamayan izleme
- ❌ Zaman dilimini belirtmemek

**Bildirim**
- ❌ Idempotency anahtarı olmayan gönderim (çift SMS)
- ❌ İstek yolunda senkron gönderim
- ❌ Sağlayıcı hatasında asıl işlemi düşürmek
- ❌ Bildirim tablosunda e-posta/telefon saklamak
- ❌ Kota/rate limit olmadan gönderim
- ❌ Test ortamından gerçek alıcıya gönderim

**Webhook**
- ❌ İmzasız webhook
- ❌ Zaman damgası imzaya dâhil değil (replay)
- ❌ Alıcı URL'ini doğrulamamak (SSRF)
- ❌ İstek yolunda senkron webhook
- ❌ Sıra garantisi varmış gibi davranmak
- ❌ Webhook gövdesinde kişisel veri

**Canlı akış**
- ❌ Bağlantı kurulduktan sonra yetkiyi bir daha kontrol etmemek
- ❌ Bağlantı sayısı sınırı olmaması
- ❌ Sınırsız yazma kuyruğu (yavaş istemci belleği tüketir)
- ❌ Heartbeat'siz uzun ömürlü bağlantı
- ❌ Medya baytlarını uygulama sunucusundan geçirmek
