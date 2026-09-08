# Kural Haritası — "Sinir Uçları"

> **Bu dosya ne işe yarar:** 476 kuralı kimse ezberleyemez ve her seferinde 19 dosyayı
> okumak da context israfıdır. Bu harita, **önündeki koda bakıp** hangi kuralların
> devreye girdiğini söyler.
>
> Mantık şu: her kural bir **sinyale** bağlıdır. Kodunda ya da şemanda o sinyal varsa,
> ilgili kural **tetiklenir** ve okunması zorunludur. Sinyal yoksa o dosyayı hiç açma.
>
> **[MAP-01] ZORUNLU:** Kod yazmadan önce §1'deki sinyal tablosunu tara. Yazdığın/
> değiştirdiğin kodda geçen her sinyal için karşısındaki kuralları oku.

---

## 1. Sinyal tablosu — kodunda BUNU görüyorsan, ŞUNU oku

### 1.1 Veri tipleri ve şema

| Sinyal (kodda/şemada gördüğün şey) | Tetiklenen kural | Neden acil |
|---|---|---|
| `float64` / `REAL` + tutar, fiyat, borç, ücret, bakiye | **[PARA-01]** → [16 §1](16-PARA-VE-HASSAS-VERI.md) | Kuruşlar sessizce kayar, mutabakat tutmaz |
| Yeni `CREATE TABLE` | [DB-05]…[DB-10] | UUID PK, TIMESTAMPTZ, CHECK, yorum |
| `SERIAL` / `BIGSERIAL` primary key | [DB-05], [API-02] | IDOR — ardışık id dışarı sızar |
| `TIMESTAMP` (tz'siz) | [DB-06] | Sunucu saati değişince veri kayar |
| Nullable `FOREIGN KEY` | [DB-07] | Boşta kalan kayıt üretir |
| Ad, soyad, TCKN, telefon, e-posta, adres kolonu | **[KVKK-01]…[KVKK-12]** → [16 §2](16-PARA-VE-HASSAS-VERI.md) | Envanter, saklama süresi, silme |
| `GEOMETRY` / koordinat kolonu | [EK-GIS](EK-GIS-POSTGIS.md) tamamı | Tip ölçümü, GIST index, ST_IsValid |
| `deleted_at` (soft delete) | [DB-33], **[KVKK-05]** | Kişisel veri için silme sayılmaz |
| Hesaplanabilir kolon (toplam − dolu vb.) | [DB-09], [API-08] | `GENERATED` olmalı, istemciden alınmaz |

### 1.2 Sorgu

| Sinyal | Tetiklenen kural | Neden acil |
|---|---|---|
| `ORDER BY` + `LIMIT`/`OFFSET` | **[DB-19]**, [API-27] | Tie-break yoksa sayfalar arası kayıt tekrarı/atlaması |
| `SELECT *` | [DB-18] | Kolon eklenince scan sırası kayar |
| `fmt.Sprintf` ile SQL kurma | **[SEC-15]** | SQL injection |
| Döngü içinde sorgu | **[DB-28]** | N+1 |
| `WHERE` içinde istemciden gelen kolon/sort adı | [API-26], [SEC-16] | Beyaz liste şart |
| `LOWER()`, `UPPER()`, `ILIKE` (Türkçe metin) | **[TRK-02]**, [TRK-03] → [18 §2](18-ESZAMANLILIK-VE-TURKCE-VERI.md) | `İ`/`ı` dönüşümü beklediğin gibi değil; arama kayıt bulamaz |
| Çok tabloyu değiştiren iş | [DB-22], [DB-23] | Tek transaction + `defer Rollback` |
| Para kolonu okuma | [PARA-06] | `::text` ile seçilmeli |

### 1.3 HTTP katmanı

| Sinyal | Tetiklenen kural | Neden acil |
|---|---|---|
| Yeni endpoint tanımı | **[GEN-10]**, [YAP-20] | Her ucun bir yetkisi olmalı |
| `PUT` handler'ı | **[API-06]** | Tüm alanlar pointer, yoksa diğer alanlar sıfırlanır |
| `POST` DTO'sunda zorunlu sayısal/koordinat alan | **[API-07]** | Değer tipi → eksik gönderim sessizce `0` |
| Tarih alanı + kısmi güncelleme | **[API-11]** | Üç durum: dokunma / null / değer |
| Liste dönen uç | [API-18], [API-19], [YAP-18] | Sayfalama + `clampPagination` |
| `c.JSON(...)` ile hata dönme | [YAP-19] | `AbortWithStatusJSON` olmalı, zincir durmalı |
| `c.ShouldBindJSON` sonrası `return` yok | **[API-12b]** | İkinci yanıt yazılmaya çalışılır |
| `h.svc.X(c, ...)` — gin.Context alt katmana | **[YAP-10]** | Katman ihlali + test edilemezlik |
| `binding:"required"` tag'i | [SEC-12b], [VER-09] | Sıfır değeri "eksik" sayar |
| Yol: `/kaynak/list` | [API-01b], [YAP-21] | Liste kaynağın kökünde olmalı |

### 1.4 Dış dünyaya açılan her şey

| Sinyal | Tetiklenen kural | Neden acil |
|---|---|---|
| `multipart`, `FormFile`, dosya yükleme | **[17](17-DOSYA-YUKLEME.md) tamamı** | Saldırganın en çok kontrol ettiği yüzey |
| Kullanıcıdan gelen URL'e istek atma | **[DOSYA-18]** | SSRF — iç ağa proxy olursun |
| `http.Client{}` oluşturma | **[RES-08]**, [PERF-14] | Varsayılan timeout **sonsuz** |
| Yüklenen dosyayı servis etme | **[DOSYA-11]** | Ana domain'den servis = stored XSS |
| Dış API çağrısı | [RES-07], [RES-11]…[RES-14] | Timeout, retry, jitter, tek katman |
| Yeni bağımlılık ekleme | **[GEN-03]**, [VER-07] | Onay + ADR gerekir |

### 1.5 Eşzamanlılık ve kaynak

| Sinyal | Tetiklenen kural | Neden acil |
|---|---|---|
| `go func(...)` | [RES-21], [RES-22] | Bitiş koşulu + sınır |
| `rows`, dosya, bağlantı açma | [PERF-16] | Kapatılmazsa havuz tükenir |
| Döngü içinde `defer` | [PERF-15] | Kaynaklar fonksiyon bitene kadar birikir |
| Süreç belleğinde durum tutma | [PERF-29] | Yatay ölçeklenemez |
| Aynı kaydı iki kullanıcı düzenleyebiliyor | **[CONC-01]**, [CONC-02] → [18 §1](18-ESZAMANLILIK-VE-TURKCE-VERI.md) | Sessiz üzerine yazma (lost update) |
| `count = count + 1` yerine oku-değiştir-yaz | **[CONC-09]** | Eşzamanlı istekte sayaç kaybolur |
| `ORDER BY` + Türkçe isim | [TRK-02] | Ç/Ğ/İ/Ö/Ş/Ü yanlış sıralanır |
| Go'da `strings.ToLower` + Türkçe metin | **[TRK-05]** | Dilden bağımsız kural Türkçe'de yanlış |
| Cache/kilit/sayaç | [08](08-CACHE-REDIS.md), [CACHE-08], [CACHE-19] | TTL zorunlu, kilit sahibi doğrulanmalı |

### 1.6 Hassas işlemler

| Sinyal | Tetiklenen kural | Neden acil |
|---|---|---|
| Para değiştiren işlem | **[PARA-12]**, [PARA-13], [API-25] | Transaction + idempotency + denetim izi |
| `DELETE` endpoint | **[AUDIT-01]**, [AUDIT-08], [KVKK-04] | İz kalmalı, kişisel veri gerçekten silinmeli |
| Yetki/rol değiştiren işlem | [AUDIT-01], [SEC-09] | Denetim izi zorunlu |
| Toplu güncelleme/silme | [DB-34], [AUDIT-01] | Önce `COUNT(*)`, sonra çalıştır |
| Özel nitelikli veri (sağlık, biyometrik) | **[KVKK-07]** | Ayrı yetki + her erişim loglanır |
| Sır/anahtar/şifre | [GEN-13], [SEC-18]…[SEC-24] | Koda, compose'a, git'e girmez |
| Parola saklama | **[AUTH-01]** → [19](19-KIMLIK-VE-OTURUM.md) | argon2id + OWASP parametreleri |
| Giriş / token / oturum | [AUTH-10]…[AUTH-21] | Enumeration, kilitleme, refresh rotasyonu |
| Toplu içe aktarma (import) | **[ETL-02]**, [ETL-05] → [20 §1](20-ENTEGRASYON-VE-TOPLU-VERI.md) | Idempotency + atlanan satır raporu |
| `time.Ticker` / cron / zamanlanmış iş | **[JOB-01]** | Çok replikada iş N kez çalışır |
| E-posta / SMS gönderimi | **[NOTIF-01]** | Retry'da çift bildirim |
| Giden webhook | **[HOOK-01]** | İmzalama + replay koruması |
| WebSocket / SSE bağlantısı | [STREAM-02], [STREAM-04] | Yetki tazeleme + backpressure |

### 1.7 Altyapı

| Sinyal | Tetiklenen kural |
|---|---|
| Yeni `Dockerfile` | [OPS-01]…[OPS-08] |
| `docker-compose.yml` düzenleme | [OPS-09]…[OPS-13], [PERF-04] |
| Yeni servis (uçtan uca) | [15](15-YENI-SERVIS-CHECKLIST.md) tamamı |
| Yeni migration | [DB-12]…[DB-16] |
| Yeni event/kuyruk | [ASYNC-04], [ASYNC-07], [ASYNC-17] |
| Yeni Temporal workflow | [ASYNC-20]…[ASYNC-24] |
| Log satırı ekleme | [OBS-01], [OBS-06], [SEC-25] |
| Yeni metrik | [OBS-10], **[OBS-11]** (etikette UUID/IP yok) |
| `.env`, `*.pem`, `*.key` dosyasına dokunma | [SEC-20], [SEC-21], **[SEC-38]** (sır taraması) |
| Yeni endpoint (koleksiyona da eklenir) | [TEST-23], [TEST-24], [TEST-25] |
| Dış girdi ayrıştıran fonksiyon yazma | [TEST-08], [TEST-26] (fuzz hedefi) |
| `go.mod` sürüm değiştirme | [VER-01] (FAIL), [VER-21] (öneri) — **ikisi farklı şey** |
| Performansa dokunan değişiklik | [PERF-33] (yük testi), [PERF-34] (ölçüm geçerliliği) |

---

## 2. Göreve göre okuma listesi

Sinyal taramasına ek olarak, işin türüne göre baştan okunacaklar:

| Ne yapıyorsun | Oku | Atla |
|---|---|---|
| Yeni proje açıyorum | 01, 02, 03, 13, [adr/](adr/README.md) | 08, 11, 16, 17 (ihtiyaç yoksa) |
| Yeni servis ekliyorum | 02, 03, 13, 15 | — |
| Endpoint ekliyorum | 04, 05, 12 + §1 sinyal taraması | 13, 14 |
| Şema/tablo değiştiriyorum | 07, 16 §2 (kişisel veri varsa) | — |
| Para/ödeme/borç işi var | **16 §1 (zorunlu)**, 07, 12 | — |
| Dosya yükleme yapıyorum | **17 (zorunlu)**, 05 | — |
| Yavaşlık/maliyet sorunu | 09 → 07 → 08 | — |
| Kuyruk/worker/zamanlanmış iş | 11, 06 | — |
| Cache ekliyorum | 08, 09 | — |
| Deploy/CI kuruyorum | 13, 14, 10 | — |
| Türkçe metin arama/sıralama | **18 §2 (zorunlu)** | — |
| Aynı kaydı birden fazla kişi düzenliyor | **18 §1 (zorunlu)** | — |
| Parola/giriş/token yazıyorum | **19 (zorunlu)**, 05 | — |
| Veri aktarımı / cron / bildirim / webhook | **20 (zorunlu)**, 11 | — |
| Güvenlik incelemesi | 05, 16, 17, 19 | — |
| Harita/geometri verisi | [EK-GIS](EK-GIS-POSTGIS.md), 07 | — |
| "Neden X kullanıyoruz?" | [adr/](adr/README.md) | diğer hepsi |

---

## 3. Konu → dosya hızlı dizin

```
API sözleşmesi, DTO, hata gövdesi, sayfalama ......... 04
Bildirim (e-posta/SMS) .............................. 20 §3
Audit / denetim izi ................................. 16 §3
Bağımlılık ekleme, sürüm seçimi ..................... 02 + adr/
Cache, TTL, invalidation, dağıtık kilit ............. 08
Canlı akış (WebSocket/SSE) .......................... 20 §5
CI, lint, PR, commit ................................ 14
Circuit breaker, retry, backoff ..................... 06 §3-4
Docker, compose, env katmanları ..................... 13
Eşzamanlı düzenleme, optimistic locking ............. 18 §1
Dosya yükleme, indirme, SSRF ........................ 17
Geometri, GeoJSON, PostGIS .......................... EK-GIS
Graceful shutdown, panic, health .................... 06 §5, §7
Girdi doğrulama ..................................... 05 §3
Katmanlar, klasör yapısı, main.go ................... 03
Kimlik, parola, token, oturum ....................... 19
Kişisel veri, KVKK, 72 saat ......................... 16 §2
Log, metrik, trace, alarm ........................... 10
Migration, goose, index, transaction ................ 07
Para, ondalık, yuvarlama ............................ 16 §1
Performans hedefleri, profiling, kaynak limiti ...... 09
Rate limit, timeout, gövde limiti ................... 06 §1-2
Test, stub, testcontainers .......................... 12
Toplu içe aktarma (ETL), zamanlanmış iş ............. 20 §1-2
Türkçe metin, collation, kodlama, zaman ............. 18 §2-3
Webhook (giden) ..................................... 20 §4
Yetki, gateway, sır yönetimi, CORS .................. 05
Yeni servis kontrol listesi ......................... 15
```

---

## 4. ⚠️ Bilinen kapsam boşlukları

> **Dürüstlük bölümü.** Bu konularda **henüz kural yok**. Sinyal tablosunda bunlarla
> karşılaşırsan standarda güvenme — dikkatli davran ve boşluğu kapatmayı gündeme getir.
> Bu liste, standardın olgunluk göstergesidir; kısaldıkça standart güçleniyor demektir.

| Boşluk | Risk | Durum |
|---|---|---|
| **Olay müdahale (incident) süreci** | Runbook kuralı var ([OBS-22]), ama "alarm çaldı, kim ne yapar" akışı yazılı değil | Açık |
| **Yerel geliştirme kurulumu** | Yeni geliştiricinin ilk gün akışı yazılı değil | Açık |
| **Kapasite planlama** | "Ne zaman büyütmeliyiz" için eşik yok | Açık |
| **Arama altyapısı** | Postgres FTS mi ayrı arama motoru mu — karar yok | Açık |
| **API sürümleme** | `04` yolu `/v1` ile başlatıyor ama kırıcı değişiklik gerektiğinde ne olacağı yazılı değil: `/v2` mi açılır, eski sürüm ne kadar yaşar, istemci nasıl haberdar edilir. Frontend ile backend ayrı deploy edildiği için bu er ya da geç gerekir | Açık |
| **Yedekleme ve geri dönüş** | `07`'de tek kural var; yedek sıklığı, saklama süresi, **geri dönüşün test edilmesi** ve RPO/RTO hedefi yok. Test edilmemiş yedek, yedek değildir | Açık |
| Çok kiracılılık (multi-tenancy) | Tek kurumlu projede gerekmez | Kapsam dışı (bilinçli) |
| Özellik bayrağı (feature flag) | İhtiyaç doğmadı | Kapsam dışı (bilinçli) |

> **Kapatılanlar (2026-08-12):** eşzamanlı düzenleme → [18 §1](18-ESZAMANLILIK-VE-TURKCE-VERI.md) ·
> Türkçe collation → [18 §2](18-ESZAMANLILIK-VE-TURKCE-VERI.md) · parola saklama, oturum,
> hesap kilitleme → [19](19-KIMLIK-VE-OTURUM.md) · toplu içe aktarma, cron, bildirim,
> giden webhook, canlı akış → [20](20-ENTEGRASYON-VE-TOPLU-VERI.md)

**[MAP-02] ZORUNLU:** Bu tabloya yeni bir boşluk eklemek, kural yazmak kadar değerlidir.
Standardın kapsamadığı bir konuda kod yazdıysan **buraya bir satır ekle** — bir sonraki
kişi en azından uyarılmış olur.

**[MAP-03] ZORUNLU:** Bir boşluk kapatıldığında bu tablodan silinir ve §1'deki sinyal
tablosuna karşılığı eklenir. Boşluk listesi güncel değilse yanlış güven üretir.

---

## 4b. Hangi kurallar otomatik kontrol ediliyor?

Beş araç CI'da makine tarafından denetim yapıyor — bunları ayrıca aramana gerek yok,
ihlal edersen build kırılır: [arac/README.md](arac/README.md)

| Araç | Ne denetler | FAIL verir mi |
|---|---|---|
| `standart-kontrol.sh` | 29 dil dışı kural: SQL, Dockerfile, compose, route yetkisi, para tipi | Evet |
| `golangci.yml` | Go AST tabanlı kurallar | Evet |
| `sir-tarama.sh` | İzlenen sır dosyası, gömülü sır, `.gitignore` eksiği ([SEC-38]) | Evet, kritik bulguda |
| `koleksiyon-kosum.sh` | Koleksiyon koşuyor mu, assertion var mı, kaba süre ([TEST-23], [TEST-24]) | Evet |
| `yuk-testi.sh` | [PERF-01] hedefleri + ölçüm geçerliliği ([PERF-33], [PERF-34]) | Evet, ölçüm geçerliyse |
| `surum-onerisi.sh` | Upstream'de yeni sürüm var mı ([VER-21]) | **Hayır, asla** |

Kalan ~550 kural **hâlâ senin sorumluluğunda.** Otomatik denetimin temiz geçmesi
"standarda uygun" demek değildir ([ARAC-04]).

---

## 5. AI ajanı için kullanım

```
1. Görevi oku → §2'den okuma listesini belirle
2. Yazacağın/değiştireceğin kodu düşün → §1 sinyal tablosunu tara
3. Tetiklenen her kuralı ilgili dosyadan OKU (hafızandan varsayma)
4. §4'teki boşluklardan birine giriyorsan: kullanıcıyı UYAR, kendi kararını
   gerekçesiyle yaz ve boşluğu rapor et
5. `arac/standart-kontrol.sh` çalıştır → sonra 15-YENI-SERVIS-CHECKLIST.md
```

**[MAP-04] ZORUNLU (AI):** "Bu değişiklik küçük, sinyal taraması gerekmez" deme.
Sinyal tablosundaki maddelerin çoğu **tek satırlık değişikliklerden** doğmuş hatalardır —
bir `ORDER BY`, bir `float64`, eksik bir `return`.
