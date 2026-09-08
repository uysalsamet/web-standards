# Otomatik Denetim Araçları

> Standardın **makine ile kontrol edilebilen** kısmı buradadır. Amaç, insanın (ve AI'ın)
> yükünü azaltmak: mekanik olarak yakalanabilen bir kural, code review'a bırakılmaz.
>
> **Bu araçlar standardın yerine geçmez.** 584 kuralın ~%9'unu kontrol ederler; kalanı
> [KURAL-HARITASI.md](../KURAL-HARITASI.md) §1 sinyal taramasıyla insana/AI'a kalır.

---

## Dosyalar

| Dosya | Ne yapar |
|---|---|
| `standart-kontrol.sh` | Dil dışı ve çapraz kurallar: SQL, Dockerfile, compose, route yetkisi, para tipi, repo hijyeni |
| `golangci.yml` | Go diline özgü kurallar; servis kökünde `.golangci.yml` olarak kopyalanır |
| `sir-tarama.sh` | Sır sızıntısı: izlenen `.env`/`.pem`, gömülü sır, `.gitignore` eksiği ([SEC-38]) |
| `koleksiyon-kosum.sh` | Postman koleksiyonunu koşturur, assertion arar, kaba süre ölçer ([TEST-23]) |
| `yuk-testi.sh` | k6 yük testi + [PERF-01] karşılaştırması + ölçüm geçerlilik kapısı ([PERF-33]) |
| `surum-onerisi.sh` | Upstream sürüm önerisi ([VER-21]). **Asla FAIL vermez** |

İkisi **birbirini tamamlar**: `golangci-lint` Go AST'ine bakar (kesin), script metin
desenlerine bakar (geniş ama heuristik).

---

## Kullanım

```bash
# Tüm repo
./backend-standartlari/arac/standart-kontrol.sh .

# Tek servis
./backend-standartlari/arac/standart-kontrol.sh services/parking-service

# Go tarafı
cp backend-standartlari/arac/golangci.yml services/parking-service/.golangci.yml
cd services/parking-service && golangci-lint run
```

Çıkış kodu: **0** = temiz · **1** = ZORUNLU/YASAK ihlali var (CI'ı kırar).
Uyarılar çıkış kodunu etkilemez.

---

## CI entegrasyonu

[14-GIT-CI.md](../14-GIT-CI.md) §4'teki pipeline'a eklenir:

```yaml
- name: Standart denetimi
  run: ./backend-standartlari/arac/standart-kontrol.sh .

- name: Lint
  run: golangci-lint run
```

---

## Kontrol edilen kurallar — `standart-kontrol.sh` (29 + linter)

### `standart-kontrol.sh`

| Kural | Ne yakalar |
|---|---|
| [VER-01] | `go.mod` sürümü standarttan farklı |
| [VER-02] | compose'da `image: ...:latest` |
| [VER-05] | Yasaklı bağımlılık (fiber, lib/pq, gorm, viper, zap, testify…) |
| [PARA-01] | Para alanı `float32/64` ile tanımlı |
| [PARA-02] | SQL'de para kolonu `REAL/DOUBLE PRECISION/MONEY` |
| [AUTH-05] | `crypto/md5`, `crypto/sha1` importu |
| [SEC-25] | Log satırında parola/token/sır |
| [DB-05] | `SERIAL PRIMARY KEY` |
| [DB-06] | `TIMESTAMP` (tz'siz) |
| [DB-12] | goose `Down` bloğu yok |
| [DB-18] | `SELECT *` |
| [DB-19] | `ORDER BY … LIMIT` tie-break'siz |
| [GIS-05] | `GEOMETRY` kolonu var, GIST index yok |
| [SEC-15] | `Sprintf` ile SQL'e değer gömme |
| [YAP-05] | Dosya > 500 satır |
| [YAP-10] | `*gin.Context` alt katmana geçirilmiş |
| [YAP-11] | `main.go` > 150 satır |
| [YAP-13] | `gin.Default()` |
| [YAP-14] | `gin.New()` var, `ContextWithFallback` yok |
| [YAP-19] | Hata yanıtında `c.JSON` (Abort değil) |
| [API-06] | `*UpdateRequest` alanı pointer değil |
| [API-12] | `c.Bind*` / `BindJSON` |
| [API-01b] | Yolda `/list` |
| [GEN-10] | Yetkisiz endpoint |
| [GEN-19] | Boş hata bloğu (iki biçim) |
| [OBS-01] | `fmt.Print*` / `log.Print*` |
| [TRK-05] | `strings.ToLower/ToUpper` |
| [RES-07] | `http.Server` timeout'suz |
| [RES-08] | `http.Client{}` timeout'suz |
| [OPS-02] | Dockerfile `FROM …:latest` |
| [OPS-03] | Dockerfile'da `USER` yok |
| [OPS-04] | `HEALTHCHECK` yok |
| [OPS-06] | `.dockerignore` yok |
| [OPS-12] | compose'da log rotasyonu yok |
| [SEC-01] | compose'da `ports:` |
| [SEC-18] | compose'a gömülü sır |
| [SEC-20] | `.gitignore`'da `.env` yok |
| [PERF-05] | compose'da bellek limiti yok |

### `golangci.yml` ek olarak

`errcheck`, `errorlint` ([API-22]), `bodyclose`, `rowserrcheck`, `sqlclosecheck`
([PERF-16]), `noctx`/`contextcheck` ([GEN-17]), `gosec`, ve `forbidigo`/`depguard`
ile yukarıdakilerin AST tabanlı — yani kesin — karşılıkları.

---

## Doğrulama — bu araçlar test edildi

Araçlar iki sahte servis üzerinde sınandı (`kotu-service` / `iyi-service`):

| Ölçüm | Sonuç |
|---|---|
| Kasten hatalı serviste yakalanan farklı kural | **29** |
| Toplam bulgu (hatalı serviste) | 40 hata + 3 uyarı |
| **Standarda uyumlu serviste yanlış pozitif** | **0** |
| Yorum satırındaki örnek ihlaller | **yakalanmadı** (doğru davranış) |
| Çıkış kodu | hatalı → `1`, temiz → `0` |

Test sırasında bulunup düzeltilen kusur: `if err := f(); err != nil {}` biçimindeki boş
hata bloğu ilk sürümde kaçıyordu — `awk` tabanlı iki satırlık desene çevrildi.

---

## Yeni araçlar (2026-09-08)

Dört araç eklendi. Üçü CI'ı kırar, biri **bilerek kırmaz**.

| Dosya | Ne yapar | CI'ı kırar mı |
|---|---|---|
| `sir-tarama.sh` | Sır sızıntısı: izlenen `.env`/`.pem`, gömülü sır, `.gitignore` eksiği ([SEC-38]) | Evet, kritik bulguda |
| `koleksiyon-kosum.sh` | Postman koleksiyonunu koşturur, assertion arar, kaba süre ölçer ([TEST-23], [TEST-24]) | Evet |
| `yuk-testi.sh` | k6 ile yük testi, [PERF-01] hedefleriyle karşılaştırır, ölçüm geçerliliğini denetler ([PERF-33], [PERF-34]) | Evet, ölçüm geçerliyse |
| `surum-onerisi.sh` | Upstream'de yeni sürüm var mı ([VER-21]) | **Hayır, asla** |

```bash
# Sır taraması — her PR'da
bash arac/sir-tarama.sh .

# Koleksiyon: servis ayakta değilken bile statik inceleme yapılabilir
bash arac/koleksiyon-kosum.sh docs/Servis.postman_collection.json --sadece-analiz
bash arac/koleksiyon-kosum.sh docs/Servis.postman_collection.json \
     --taban-url http://localhost:9000 --tekrar 3 --kod-dizini services/parking-service

# Yük testi — gece koşumunda ya da performansa dokunan PR'da
bash arac/yuk-testi.sh http://localhost:9000/parkings --sinif liste --sure 30s --vu 10
bash arac/yuk-testi.sh --ozet onceki-ozet.json --sinif liste     # k6 olmadan değerlendirme
bash arac/yuk-testi.sh <url> --sinif liste --karsilastir dun.json

# Sürüm önerisi — aylık, ya da bağımlılık dokunulan PR'da
bash arac/surum-onerisi.sh .
```

Çıkış kodları: `0` temiz · `1` ihlal · `2` araç yok, kullanım hatası **veya ölçüm
yorumlanamaz**. `surum-onerisi.sh` her koşumda `0` döner.

---

### Neden `2` ayrı bir kod

`1` "kural ihlal edildi" demektir; `2` "bir şey söyleyemiyorum" demektir. İkisini aynı koda
bağlamak, aracın bilmediği durumu ihlal gibi gösterir ve tersi de olur: k6 kurulu olmadığı
için başarısız olan bir adım, "performans hedefi kaçtı" gibi okunur. Ayrım, [PERF-34]'ün
ölçüm geçerlilik kapısının çalışabilmesi için gerekli.

### `sir-tarama.sh` — üç tasarım kararı

**Değeri asla basmaz.** Bulunan sır yalnızca konum, tür ve dört karakterlik önek + uzunluk
olarak raporlanır (`ca75... (32 karakter)`). Bir denetim raporu, bulduğu sırrı yayınlamamalı;
bu standardın kendi [SEC-25] kuralıdır ve araç kendi kuralına uyar.

**Düzeltme yapmaz.** `git rm` yok, geçmiş temizleme yok, rotasyon yok. Sebebi teknik: sızmış
bir sırrı dosyadan silmek onu geçmişten kaldırmaz, ve rotasyon yapılmadan silmek sorunu
çözmeden görünmez kılar. Kapatma sırası insanda: önce rotasyon, sonra takipten çıkarma,
geçmiş temizliği en son ve ayrı bir karar.

**Git geçmişini taramaz.** Yalnızca çalışma ağacına ve `git ls-files` çıktısına bakar.
Geçmişte silinmiş ama bir commit'te duran sır bu araca **görünmez**. En büyük eksiği budur
ve script bunu her koşumda kendi çıktısında söyler.

### `koleksiyon-kosum.sh` — neden p95 yazmaz

Endpoint başına üç örnekle p95 hesaplanamaz. Araç min/medyan/maks verir, SLO kararı
**vermez** ve JSON çıktısında bunu açıkça işaretler (`p95_hesaplandi_mi: false`,
`slo_karari: null`). Hedefe göre karar [PERF-33]'ün işidir, `yuk-testi.sh` ile.

`newman run -n 3` koleksiyonun tamamını üç kez koşar, yani aynı uca peş peşe vurulmaz;
istekler doğal olarak serpiştirilir. Bu, cache'in aynı endpoint'i art arda ısıtmasını
engeller ama etkisini sıfırlamaz, ve araç bunu söyler.

Endpoint sınıflandırması (tek kayıt / liste / yazma / ağır) metot ve yol deseninden
çıkarılan bir **sezgiseldir**. Yolda `search` geçen bir `POST` yazma değil okuma sayılır;
bu istisna hem kodda hem çıktıda işaretli. Adı masum ama pahalı bir uç yanlış sınıflanır.

### `surum-onerisi.sh` — neden asla FAIL etmez

İki farklı soru vardır ve karıştırılırsa ikisi de işe yaramaz hâle gelir:

| Soru | Kural | Sonuç |
|---|---|---|
| Bu servis standardın tablosuna uyuyor mu | [VER-01] | **FAIL** — `standart-kontrol.sh`'nin işi |
| Upstream'de daha yenisi var mı | [VER-21] | Bilgi — bu aracın işi |

Yeni sürüm çıktı diye pipeline kırmak, ekibi aracı devre dışı bırakmaya iter ve sonunda
hiçbir şey güncellenmez. Araç `-mod=readonly` ile koşar: eksik `go.sum` girdisini bildirir
ama **yazmaz**. Rapor üreten bir araç, raporladığı deponun kaynak dosyalarını değiştirmez.

---

## Doğrulama — yeni araçlar da test edildi

Ölçüm tarihi 2026-09-08, gerçek depolar üzerinde.

| Araç | Koşum | Sonuç |
|---|---|---|
| `sir-tarama.sh` | frontend deposu | 31 kritik, 3 uyarı, çıkış 1 |
| `sir-tarama.sh` | microservices deposu | 8 kritik, 3 uyarı, çıkış 1 |
| `sir-tarama.sh` | temiz örnek depo | **0 bulgu, çıkış 0** |
| `koleksiyon-kosum.sh` | address-search koleksiyonu, statik | 9 istek, **0 assertion**, çıkış 1 |
| `koleksiyon-kosum.sh` | newman yok / servis kapalı | temiz mesaj, çıkış 2 |
| `yuk-testi.sh` | k6 yok / hedef verilmemiş | temiz mesaj, çıkış 2 |
| `yuk-testi.sh` | 7 geçerlilik kapısı, sahte özetlerle | 7/7 doğru karar |
| `surum-onerisi.sh` | 47 modül, ağlı | 47 standart dışı, 1127 güncelleme, **çıkış 0** |

Bu koşumlarda ortaya çıkan gerçek bulgular — izlenen `.env` ve özel anahtar dosyaları,
assertion'suz koleksiyonlar, üç farklı Go sürümü, eksik `go.sum` — kuralların gerekçe
bölümlerine ölçüm olarak işlendi. Standardın maddeleri varsayımdan değil, bu depoların
gerçek durumundan türetildi.

Test sırasında araçlarda bulunup düzeltilen kusurlar: Windows sürücü harfinin (`C:`) satır
numarasını bozması, arayüz çevirisindeki "Şifreniz" metninin sır sanılması, MQTT
`token.Error()` çağrısının [SEC-25] ihlali sanılması, `ST_Intersects` deseninden sahte kolon
adı üretilmesi, migration dosyalarının N+1 bulgusu vermesi. Hepsi [ARAC-02] gereği kuralı
**daraltarak** çözüldü, kontrolü kapatarak değil.

---

## Yeni araçların sınırları

**[ARAC-05] ZORUNLU:** `sir-tarama.sh` git geçmişini taramaz ve entropi hesaplamaz. İsimsiz
bir değişkene atanmış (`k = "..."`) ya da base64 gömülü sırrı kaçırır. Taradığı uzantılar
`.go .yml .yaml .json .sql Dockerfile*` ile sınırlıdır. Temiz çıkması "sır yok" demek
değildir; "bu desenlerle bulunamadı" demektir.

**[ARAC-06] ZORUNLU:** `koleksiyon-kosum.sh`'nin endpoint sınıfı ve kod bulguları metin
desenidir, kanıt değildir. Ölçüm istemci tarafındadır: ağ, gateway ve makine yükü sürelerin
içindedir. `node` gerektirir; yoksa çıkış 2.

**[ARAC-07] ZORUNLU:** `surum-onerisi.sh` ağ gerektirir ve 47 modülde dakikalar sürer.
Ağ yoksa `go` direktifi tablosunu yine üretir ve ağ gerektiren kısmın neden atlandığını
söyler. `--major-tara` yalnızca **bir üst** major'ı yoklar; kapalıyken rapor "taranmadı"
yazar, "yok" demez.

**[ARAC-08] ZORUNLU:** `yuk-testi.sh` sonucu mutlak bir hüküm değildir. Ölçüm makineye ve
ağa bağlıdır ([PERF-35]); anlam, aynı ortamdaki önceki koşumla karşılaştırmadadır. Geçerlilik
kapılarından biri düşerse araç karar **vermez** ve çıkış 2 döner — bu bir başarısızlık değil,
"bu sayıdan hüküm çıkmaz" demektir.

## Sınırlar — dürüstlük bölümü (standart-kontrol.sh)

**[ARAC-01] ZORUNLU:** Bu araçlar **heuristiktir, kanıt değildir.**
- Metin deseni tabanlı kontroller yanlış pozitif/negatif verebilir.
- Yorum satırları elenir, ancak **string literal içindeki** kod elenmez.
- `GEN-10` (yetkisiz endpoint) yalnızca `routes*.go` dosyalarına bakar; route başka
  yerde tanımlanmışsa göremez.
- `PARA-01` alan **adına** bakar; `X float64` gibi anlamsız isimli bir para alanını kaçırır.

**[ARAC-02] ZORUNLU:** Yanlış pozitif çıkarsa **kuralı daralt**, kontrolü sessizce
kapatma. Kapatmak gerekiyorsa gerekçesi commit mesajına yazılır ([CI-21] ile aynı mantık).

**[ARAC-03] ZORUNLU:** Yeni bir kural makineye devredilebiliyorsa buraya eklenir ve
yukarıdaki tabloya işlenir. **Ekleme yapılınca sahte servislerle yeniden test edilir** —
test edilmemiş bir kontrol, yanlış güven üretir.

**[ARAC-04] ZORUNLU:** Denetim **temiz geçti diye kod standarda uygun sayılmaz.** Araçlar
kuralların ~%9'unu görür. Kalanı için [KURAL-HARITASI.md](../KURAL-HARITASI.md) §1 sinyal
taraması ve [15-YENI-SERVIS-CHECKLIST.md](../15-YENI-SERVIS-CHECKLIST.md) zorunludur.
