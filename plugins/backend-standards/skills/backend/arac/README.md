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

## Kontrol edilen kurallar (29 + linter)

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

## Sınırlar — dürüstlük bölümü

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
