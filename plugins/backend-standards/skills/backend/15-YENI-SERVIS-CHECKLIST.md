# 15 — Yeni Servis Kontrol Listesi

> Kopyala, madde madde işaretle. **Atlanan her madde PR'da gerekçesiyle yazılır.**
> "Sonra yaparım" ile atlanan madde yapılmaz.

---

## A. Kurulum

- [ ] Servis adı `<isim>-service` (küçük harf, tire), `go.mod` modül adı aynı — [YAP-01]
- [ ] `go.work`'e eklendi; `go.work` sürümü düşürülmedi — [YAP-02]
- [ ] `go.mod`: `go 1.25.12`, Gin `v1.12.0`, pgx `v5.10.0` — [VER-01], [02](02-TEKNOLOJI-SURUMLERI.md)
- [ ] Tabloda olmayan bağımlılık eklenmedi (eklendiyse onay alındı ve tabloya işlendi) — [GEN-03]
- [ ] Klasör yapısı [03](03-PROJE-YAPISI.md) §2'ye uygun; `repository/postgres/` alt dizini var — [YAP-06]

## B. Kod

- [ ] `main.go` yalnızca wiring, 150 satırın altında — [YAP-11]
- [ ] `config.go` yalnızca env okuyor; `DSN()` tek kaynak; sır varsayılanı boş — [YAP-15], [YAP-16]
- [ ] Her modül için: DTO (3 tip) + repository (interface) + service (interface) + handler — [YAP-04], [GEN-07]
- [ ] Hiçbir dosya 500 satırı geçmiyor — [YAP-05]
- [ ] Katman ihlali yok: handler'da SQL yok, service'e `*gin.Context` geçirilmiyor — [GEN-04], [GEN-05], [YAP-10]
- [ ] Her fonksiyonun ilk parametresi `context.Context` — [YAP-09]
- [ ] `handler/common.go`: `Health`, `Ready`, `recordID`, `badRequest`, `writeError`, `clampPagination`
- [ ] `clampPagination` tek kaynak; `meta.limit` ile dönen kayıt sayısı uyumlu — [YAP-18]
- [ ] `routes.go`: tek `Setup`; `/health` + `/ready` açık; gruplar `GatewayAuth` alıyor;
      her uç yetkili — [YAP-20], [GEN-10]
- [ ] Liste ucu kaynağın kökünde (`GET /parkings`), `/list` alt yolu yok — [API-01b], [YAP-21]
- [ ] Her grup middleware'ini kendi tanımında açıkça alıyor — [YAP-22]
- [ ] PUT DTO'sunda tüm alanlar pointer; POST'ta zorunlu sayısal/koordinat alanlar da pointer — [API-06], [API-07]
- [ ] `GENERATED`/türetilmiş alan Request DTO'sunda yok — [API-08]
- [ ] `gin.New()` + `ContextWithFallback`; bağlama `ShouldBindJSON`; hatalarda `AbortWithStatusJSON` + `return` — [YAP-13], [YAP-14], [YAP-19], [API-12]
- [ ] Yorumlar "neden"i anlatıyor — [YAP-23]

## C. Güvenlik

- [ ] `GatewayAuth`: `X-Gateway-Source` + `X-API-Key`, sabit zamanlı karşılaştırma;
      sır boşsa kontrol **atlanmıyor** — [SEC-04]
- [ ] Her endpoint bir yetki istiyor; açık uçlar yorumla gerekçelendirilmiş — [GEN-10]
- [ ] Yetki anahtarları `<modul>.<eylem>` formatında, seed ile birebir aynı — [SEC-06]
- [ ] Fail-open yok — [SEC-08], [GEN-11]
- [ ] Yetki reddi yapısal loglanıyor — [SEC-09]
- [ ] Sahiplik (ownership) kontrolü gereken uçlarda sorgu daraltılmış — [SEC-11]
- [ ] Girdi doğrulama tablosundaki tüm kontroller var — [SEC-12]
- [ ] `VARCHAR` sınırları handler'da sabit olarak kontrol ediliyor ve DDL ile aynı — [SEC-13]
- [ ] Tüm SQL parametreli; dinamik kolon/sort beyaz listeden — [SEC-15], [API-26]
- [ ] Gateway arkasındaki serviste CORS **yok** — [SEC-31]
- [ ] `.gitignore` içinde `.env*`, `*.pem`, `*.key`; `.env.example` var — [SEC-20], [SEC-21]
- [ ] Sır loglanmıyor; config `%+v` ile basılmıyor — [SEC-25], [SEC-26]

## D. Dayanıklılık

- [ ] `http.Server`: `ReadHeaderTimeout` 5s, `ReadTimeout` 15s, `WriteTimeout` 30s, `IdleTimeout` 60s + `BodyLimit` middleware 4MB — [RES-07], [RES-05]
- [ ] Upstream HTTP istemcisi paylaşılan ve timeout'lu — [RES-08], [PERF-14]
- [ ] `recover` middleware var, stack trace yalnızca log'a — [RES-18]
- [ ] Graceful shutdown var; kapanış sırası doğru — [RES-19], [RES-20]
- [ ] Retry varsa: tek katman, en fazla 3, jitter'lı backoff, yalnız geçici hatalar — [RES-11]…[RES-14]
- [ ] Goroutine'lerin bitiş koşulu var; sınırsız fan-out yok — [RES-21], [RES-22]
- [ ] `/health` bağımlılık kontrol **etmiyor**; `/ready` ediyor — [RES-27], [RES-29]
- [ ] `/health` formatı `{"status":"healthy","service":"<ad>"}` — [RES-28]

## E. Veritabanı

- [ ] Havuz ayarlı (`MaxConns`, `MaxConnLifetime`, `MaxConnIdleTime`); `Ping` başarısızsa açılmıyor — [DB-01], [DB-02]
- [ ] Havuz bütçesi hesaplandı: servis × MaxConns × replika < `max_connections` — [DB-03]
- [ ] UUID PK; `created_at`/`updated_at` `TIMESTAMPTZ` — [DB-05], [DB-06]
- [ ] Zorunlu ilişkilerde FK `NOT NULL`; iş kuralları `CHECK`/`UNIQUE` ile de korunuyor — [DB-07], [DB-08]
- [ ] Türetilebilen değer `GENERATED` ya da sunucuda hesaplanıyor — [DB-09]
- [ ] Şema kararları yorumlu — [DB-10]
- [ ] Migration `goose` ile, `Down` bloğu var, ileriye uyumlu — [DB-12], [DB-13]
- [ ] Migration hatası fatal; seed idempotent ve hatası uyarı — [DB-15]
- [ ] `SELECT *` yok; kolon listesi tek sabitte — [DB-18]
- [ ] Sayfalı sorguların `ORDER BY`'ında benzersiz tie-break var — [DB-19]
- [ ] `errors.go`: sekiz hata kodunun **hepsi** çevrilmiş; sentinel hatalar dışa açık — [DB-20], [DB-21]
- [ ] Çok tablolu iş transaction'da; `defer tx.Rollback` var; transaction kısa — [DB-22], [DB-23]
- [ ] Sık filtrelenen kolonlarda index; liste sorgusu `EXPLAIN` ile bakıldı — [DB-26], [DB-27]
- [ ] N+1 yok — [DB-28]

## F1. Para / kişisel veri / denetim izi (varsa — [16](16-PARA-VE-HASSAS-VERI.md))

- [ ] Para alanları şemada `NUMERIC(n,2)`; `REAL`/`DOUBLE PRECISION`/`MONEY` **yok** — [PARA-02]
- [ ] Go tarafında `Money` (int64 kuruş) tipi; hiçbir yerde `float` ile para yok — [PARA-01], [PARA-03]
- [ ] JSON'da tutarlar **string** — [PARA-04]
- [ ] Para kolonları sorguda `::text` ile seçiliyor — [PARA-06]
- [ ] Yuvarlama kuralı ve yönü tek yerde, yorumlu — [PARA-08], [PARA-10]
- [ ] Taksit/paylaştırmada kalan kuruş kaybolmuyor (`sum(Split) == total` testi) — [PARA-09]
- [ ] Para birimi açıkça belirtilmiş — [PARA-11]
- [ ] Para işlemleri transaction içinde + idempotency korumalı — [PARA-12]
- [ ] Kişisel veri kolonları şemada etiketli; saklama süresi yazılı — [KVKK-01], [KVKK-03]
- [ ] Silme talebi teknik olarak uygulanabilir (hard delete / anonimleştirme kararı verilmiş) — [KVKK-04]
- [ ] Soft delete kişisel veri silme sayılmıyor — [KVKK-05]
- [ ] Üretim verisi test/geliştirme ortamına kopyalanmıyor — [KVKK-10]
- [ ] Denetim izi tablosu var, append-only (`REVOKE UPDATE, DELETE`) — [AUDIT-02], [AUDIT-03]
- [ ] Para/yetki/silme/kişisel veri işlemleri denetim izi üretiyor — [AUDIT-01]
- [ ] Denetim kaydı iş ile **aynı transaction'da** yazılıyor — [AUDIT-04]

## F2. Dosya yükleme (varsa — [17](17-DOSYA-YUKLEME.md))

- [ ] Uca özel boyut limiti; genel limit yükseltilmemiş — [DOSYA-01]
- [ ] Dosya akış hâlinde işleniyor, belleğe alınmıyor — [DOSYA-02]
- [ ] Tip **içerikten** tespit ediliyor; `Content-Type` header'ına güvenilmiyor — [DOSYA-03]
- [ ] İzinli tipler **beyaz liste** — [DOSYA-04]
- [ ] Nesne anahtarını sunucu üretiyor; istemci dosya adı yol olarak kullanılmıyor — [DOSYA-07]
- [ ] Dosyalar nesne deposunda, konteyner diskinde değil; bucket public değil — [DOSYA-09], [DOSYA-10]
- [ ] Yüklemeler ana domain'den servis edilmiyor **veya** `attachment` + `nosniff` + CSP var — [DOSYA-11]
- [ ] Her indirmede yetki kontrolü var; presigned URL kısa ömürlü — [DOSYA-12], [DOSYA-13]
- [ ] Görseller yeniden kodlanıyor (EXIF/konum temizleniyor) — [DOSYA-14]
- [ ] Kullanıcı URL'ine doğrudan istek atılmıyor (SSRF koruması) — [DOSYA-18]
- [ ] Kota + rate limit var; sahipsiz dosyalar temizleniyor — [DOSYA-21], [DOSYA-22]
- [ ] [17](17-DOSYA-YUKLEME.md) §7'deki 13 maddelik red testi koşuldu — [DOSYA-25]

## F3. Eşzamanlılık / Türkçe veri ([18](18-ESZAMANLILIK-VE-TURKCE-VERI.md))

- [ ] Çok kullanıcılı düzenlenebilir tablolarda `version` kolonu var — [CONC-01]
- [ ] `UPDATE ... WHERE version = $n` + etkilenen satır kontrolü; çakışmada 409 — [CONC-02], [CONC-04]
- [ ] Sayaçlar atomik SQL ile artıyor (oku-değiştir-yaz yok) — [CONC-09]
- [ ] Türkçe metin araması ICU collation ya da normalize kolon ile — [TRK-02], [TRK-03]
- [ ] Go'da `strings.ToLower` yerine `cases.Lower(language.Turkish)` — [TRK-05]
- [ ] Normalize mantığı tek fonksiyonda — [TRK-06]
- [ ] UTF-8 doğrulaması var; uzunluk `[]rune` ile ölçülüyor — [TRK-08], [TRK-09]
- [ ] Türkçe test listesi koşuldu (İSTANBUL/ISPARTA/sıralama) — [TRK-10]

## F4. Kimlik / oturum (auth servisi ise — [19](19-KIMLIK-VE-OTURUM.md))

- [ ] Parolalar argon2id, OWASP parametreleriyle; PHC formatında saklanıyor — [AUTH-01], [AUTH-02]
- [ ] Girişte parametre eskiyse yeniden hash — [AUTH-03]
- [ ] Kullanıcı sayımı engellenmiş; kullanıcı yokken de hash hesaplanıyor — [AUTH-10], [AUTH-11]
- [ ] Hesap bazlı kilitleme var (IP bazlı limitin ötesinde) — [AUTH-12]
- [ ] Access 15 dk / refresh rotasyonlu; yeniden kullanım tespiti var — [AUTH-14], [AUTH-15], [AUTH-16]
- [ ] Refresh token DB'de hash'li — [AUTH-17]
- [ ] `alg` doğrulaması var, `none` reddediliyor — [AUTH-19]
- [ ] Sıfırlama token'ı tek kullanımlık ve kısa ömürlü — [AUTH-22]
- [ ] [19](19-KIMLIK-VE-OTURUM.md) §5 test listesi koşuldu — [AUTH-27]

## F5. Entegrasyon / toplu veri ([20](20-ENTEGRASYON-VE-TOPLU-VERI.md))

- [ ] Import idempotent (`ON CONFLICT`), `import_runs` kaydı tutuluyor — [ETL-01], [ETL-02]
- [ ] Kısmi başarısızlık politikası yazılı; atlanan satırlar raporlanıyor — [ETL-03], [ETL-05]
- [ ] Sayım doğrulaması yapılıyor (kaynak == hedef) — [ETL-06]
- [ ] Zamanlanmış iş çok replikada tekilleştirilmiş (dağıtık kilit) — [JOB-01]
- [ ] "İş hiç çalışmadı" durumu alarm üretiyor — [JOB-05]
- [ ] Bildirim gönderimi idempotent; test ortamından gerçek gönderim yok — [NOTIF-01], [NOTIF-07]
- [ ] Giden webhook imzalı (timestamp dâhil); alıcı URL doğrulanıyor — [HOOK-01], [HOOK-02]
- [ ] Canlı akışta yetki tazeleniyor + backpressure var — [STREAM-02], [STREAM-04]

## F. Cache / asenkron (varsa)

- [ ] Cache ölçülerek eklendi; kabul edilen bayatlık süresi yazılı — [CACHE-01], [CACHE-03]
- [ ] Anahtar formatı `<servis>:<varlık>:<sürüm>:<kimlik>`; TTL'siz anahtar yok — [CACHE-04], [CACHE-08]
- [ ] Kullanıcıya özel veri anahtarında kullanıcı kimliği var — [CACHE-07]
- [ ] Redis hatası isteği düşürmüyor (rate limit/kilit hariç) — [CACHE-10]
- [ ] `KEYS`/`FLUSHALL` kullanılmıyor; `maxmemory-policy` ayarlı — [CACHE-15], [CACHE-23]
- [ ] Tüketiciler idempotent; DLQ var ve izleniyor — [ASYNC-04], [ASYNC-07], [ASYNC-08]
- [ ] DB yazması + event üretimi outbox ile aynı transaction'da — [ASYNC-17]
- [ ] Workflow kodu deterministik; IO activity'de — [ASYNC-20], [ASYNC-21]

## G. Gözlemlenebilirlik

- [ ] `log/slog` ile JSON log, stdout'a; seviye env ile — [OBS-01], [OBS-02], [OBS-03]
- [ ] Her log satırında `service`, `version`, `request_id` — [OBS-04]
- [ ] Gelen `X-Request-ID` korunuyor — [OBS-05]
- [ ] Log mesajı sabit, değişkenler alan — [OBS-06]
- [ ] `/metrics` var ve dışarı açık değil; RED metrikleri tanımlı — [OBS-09], [OBS-10]
- [ ] Metrik etiketlerinde UUID/e-posta/IP yok; `route` şablon — [OBS-11]
- [ ] En az bir iş metriği tanımlı — [OBS-12]

## H. Docker & entegrasyon

- [ ] Dockerfile multi-stage, non-root, `HEALTHCHECK`, doğru `EXPOSE` — [OPS-01]…[OPS-05]
- [ ] Migration SQL dosyaları imaja kopyalanmış — [OPS-01]
- [ ] `.dockerignore` var — [OPS-06]
- [ ] Compose: `expose` (ports değil), env referansları, kaynak limitleri, log rotasyonu,
      `depends_on: service_healthy` — [OPS-09]…[OPS-12]
- [ ] `GOMEMLIMIT` limitin %80'ine ayarlı — [PERF-06]
- [ ] `.env.local` + `.env.prod` + `.env.example`: `<ISIM>_SERVICE_PORT` ve `<ISIM>_SERVICE_URL` — [OPS-15]
- [ ] Port repo genelinde benzersiz; `docs/README.md`'deki port listesi güncellendi — [OPS-16]
- [ ] Gateway: config alanı + route tablosu + **router kaydı** (dört adımın hepsi) — [OPS-18]…[OPS-22]
- [ ] Yetki tanımları eklendi ve admin rolüne bağlandı — [OPS-21]

## I. Test ve doğrulama

- [ ] `routes_test.go` [12](12-TEST.md) §2'deki 11 maddeyi kapsıyor — [TEST-04]
- [ ] Reddedilen isteklerin service'e ulaşmadığı doğrulandı — [TEST-06]
- [ ] Her endpoint için mutlu yol + yetki reddi + kötü girdi testi var — [TEST-07]
- [ ] Sınır değerleri test edildi — [TEST-08]
- [ ] Repository entegrasyon testi gerçek Postgres'e karşı koştu — [TEST-12]
- [ ] `go build ./...` temiz
- [ ] `go test -race ./...` geçiyor — [TEST-15]
- [ ] `arac/standart-kontrol.sh` temiz (exit 0) — [CI-25]
- [ ] `.golangci.yml` arac/golangci.yml'den kopyalanmış; `golangci-lint run` temiz — [CI-15], [CI-24]
- [ ] `govulncheck ./...` temiz — [SEC-34]
- [ ] Elle E2E listesi ([12](12-TEST.md) §6) koşuldu ve sonucu PR'a yazıldı — [TEST-21]
- [ ] Yetki yüklemesi **DB'den sorgulanarak** doğrulandı, log'a bakılarak değil — [TEST-22]

## J. Dokümantasyon

- [ ] `docs/README.md`: servis ne yapar, endpoint listesi, yetki listesi — [API-31]
- [ ] `docs/ui-integration.md`: frontend akışları, örnek istek/yanıt
- [ ] Postman koleksiyonu çalışır durumda
- [ ] Standarttan sapma varsa koda `// STANDART İSTİSNASI [ID]: gerekçe` yazıldı ve PR'da belirtildi — [CI-08]

---

## Son kontrol — üç soru

1. **Bu servisi ben yazmasam, başka biri açtığında ne bulacağını biliyor mu?**
   (Klasör, isimlendirme, hata gövdesi, sayfalama aynı mı?)
2. **Bir bağımlılık düştüğünde ne olur?** DB, Redis, upstream, yetki kaynağı —
   her biri için cevabın var mı ve o cevap "erişim genişler" değil mi?
3. **Bir şey ters gittiğinde nereden bakacağım?** Log'da `request_id` var mı, metrik
   var mı, alarm kurulu mu?

Üçüne de cevabın yoksa iş bitmemiştir.
