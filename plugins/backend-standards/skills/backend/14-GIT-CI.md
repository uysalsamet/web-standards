# 14 — Git, Kod İnceleme ve CI

---

## 1. Branch ve commit

**[CI-01] ZORUNLU:** `main` her zaman deploy edilebilir durumdadır. Doğrudan `main`'e
push yapılmaz; her değişiklik branch + PR üzerinden gelir.

**Branch adlandırma:**
```
feat/<kisa-aciklama>      yeni özellik
fix/<kisa-aciklama>       hata düzeltme
chore/<kisa-aciklama>     bağımlılık, yapılandırma, temizlik
docs/<kisa-aciklama>      dokümantasyon
```

**[CI-02] ZORUNLU — Commit mesajı formatı** (Conventional Commits):
```
<tip>(<kapsam>): <ne yapıldığı, emir kipinde, 72 karakteri geçmeden>

<neden yapıldığı — asıl değerli kısım burasıdır>
<varsa: hangi alternatif neden seçilmedi>
```
Örnek:
```
fix(parking): sayfalı sorguya id tie-break'i ekle

created_at değerleri seed sırasında aynı yazıldığı için sıra kararsızdı;
sayfalar arasında kayıt hem tekrarlanıyor hem atlanıyordu. Tüm sayfaları
gezen istemci toplamı eksik hesaplıyordu.
```

**[CI-03] ZORUNLU:** Commit **tek bir iş** yapar. Formatlama + refactor + özellik aynı
commit'te olmaz — geri alınması gerektiğinde ayrıştırılamaz.

**[CI-04] YASAK:** `.env*`, `*.pem`, `*.key`, üretim yedeği, büyük ikili dosya commit'lemek.
Sır girdiyse rotasyona git ([SEC-22]).

**[CI-05] ZORUNLU:** `go.sum` commit'lenir; `vendor/` kullanılmaz (kullanılacaksa proje
genelinde ve baştan karar verilir).

---

## 2. Pull request

**[CI-06] ZORUNLU:** PR **küçük** tutulur. 400 satırı aşan diff, gerekçesiz kabul edilmez.
> **Neden:** İnceleme kalitesi diff büyüklüğüyle ters orantılıdır. 1.500 satırlık PR
> "LGTM" alır; 200 satırlık PR gerçekten okunur.

**[CI-07] ZORUNLU:** PR açıklaması şunları içerir:
```
## Ne
<değişikliğin özeti>

## Neden
<hangi problem, hangi ölçüm/talep>

## Nasıl doğrulandı
<koşan testler + elle yapılan doğrulama, 12-TEST §6 listesi>

## Riskler / geri alma
<neyi bozabilir, nasıl geri alınır>
```

**[CI-08] ZORUNLU:** Standarttan sapma varsa PR'da **açıkça** belirtilir ve koda
`// STANDART İSTİSNASI [KURAL-ID]: <gerekçe>` yorumu düşülür ([00-README] §Kural formatı).

**[CI-09] ZORUNLU:** En az bir onay olmadan merge edilmez. Onaylayan kişi kodu **okumuş**
olmalıdır — otomatik onay, incelemenin olmadığını gizler.

**[CI-10] ZORUNLU:** Bağımlılık yükseltmesi ve büyük refactor **ayrı PR**'dır; özellik
PR'ına karıştırılmaz.

---

## 3. Kod inceleme

**[CI-11] ZORUNLU — İnceleyenin bakacağı sıra:**

```
1. Güvenlik      → yetki var mı, girdi doğrulanıyor mu, sır sızıyor mu, SQL parametreli mi
2. Doğruluk      → edge case'ler (nil, 0, boş, sınır), hata yolları, eşzamanlılık
3. Sözleşme      → API/hata/sayfalama biçimi standarda uyuyor mu
4. Dayanıklılık  → timeout, context, kaynak bırakma
5. Test          → mutlu yol + yetki + kötü girdi var mı, testler gerçekten bir şey doğruluyor mu
6. Okunabilirlik → isimler, katman ihlali, dosya boyutu
7. Stil          → linter'ın işi; insan bunu tartışmaz
```

**[CI-12] ZORUNLU:** Stil tartışması yapılmaz — formatlama `gofmt`/`golangci-lint`'in işidir.
İnsan zamanı 1–6 için harcanır.

**[CI-13] ÖNERİLEN:** Yorum, **neyi** neden değiştirmesi gerektiğini söyler ve tercihen
alternatif önerir. "Bu yanlış" değil, "burada `limit` sınırı kontrol edilmiyor; `?limit=100000`
ile tüm tablo dönebilir — `clampPagination` kullanılmalı".

**[CI-14] ZORUNLU:** Aldığın incelemede teknik olarak katılmıyorsan **uygulamadan önce
söyle**. Gerekçesiz uygulanan öneri, incelemede yakalanmayan bir hataya dönüşebilir.

---

## 4. CI pipeline

**[CI-15] ZORUNLU — Her PR'da koşacak adımlar (sırayla):**

```yaml
1. go mod download && go mod tidy    → tidy sonrası diff varsa FAIL (kullanılmayan/eksik bağımlılık)
2. gofmt -l .                        → çıktı boş değilse FAIL
3. ./backend-standartlari/arac/standart-kontrol.sh .   → FAIL'de merge yok
4. golangci-lint run                 → FAIL'de merge yok
5. go build ./...                    → FAIL'de merge yok
6. go test -race ./...               → FAIL'de merge yok
7. go test -tags=integration ./...   → gerçek Postgres'e karşı
8. govulncheck ./...                 → bilinen açık varsa FAIL
9. docker build                      → imaj gerçekten build oluyor mu
10. (öneri) imaj taraması (Trivy)    → HIGH/CRITICAL varsa FAIL
```

**[CI-16] ZORUNLU:** CI kırmızıysa merge edilmez. "Sonra düzeltirim" ile merge edilen
kırmızı build, ertesi gün herkesin build'ini kırar.

**[CI-17] ZORUNLU:** CI `-mod=readonly` ile koşar ([VER-04]) — pipeline sessizce
bağımlılık çekmemelidir.

**[CI-18] ZORUNLU:** Build reprodüksiyonu için sürüm ve commit binary'ye gömülür
([OPS-01] `-ldflags`).

**[CI-19] ZORUNLU:** CI'da sır **CI'nın secret deposundan** gelir; pipeline dosyasına
yazılmaz ve log'a basılmaz.

**[CI-20] ÖNERİLEN:** Pipeline **10 dakikanın altında** kalmalıdır. Uzun pipeline
atlanmaya ve baypas edilmeye başlanır.

---

## 5. `.golangci.yml`

**[CI-24] ZORUNLU:** Servis kökündeki `.golangci.yml`, [arac/golangci.yml](arac/golangci.yml)
dosyasından kopyalanır. İçinde `forbidigo` ve `depguard` ile standardın Go kuralları
(yasaklı bağımlılık, `gin.Default()`, `c.BindJSON`, `fmt.Print*`, `md5`, `math/rand`…)
linter'a devredilmiştir.

**[CI-25] ZORUNLU:** Dil dışı kurallar (SQL, Dockerfile, compose, route yetkisi, para tipi)
[arac/standart-kontrol.sh](arac/standart-kontrol.sh) ile denetlenir ve CI'da koşar.
Araçların kapsamı ve **sınırları** [arac/README.md](arac/README.md)'de.

### Aşağıdaki blok, tam yapılandırmanın kısaltılmış örneğidir

```yaml
version: "2"

linters:
  enable:
    - errcheck        # dönen hatayı yok sayma [GEN-19]
    - govet
    - staticcheck
    - ineffassign
    - unused
    - bodyclose       # HTTP response body kapatılmıyor -> bağlantı sızıntısı
    - rowserrcheck    # rows.Err() kontrol edilmiyor -> sessiz eksik veri
    - sqlclosecheck   # rows/stmt kapatılmıyor -> havuz tükenmesi [PERF-16]
    - contextcheck    # context taşınmıyor [GEN-17]
    - noctx           # context'siz HTTP isteği
    - errorlint       # errors.Is/As yerine == karşılaştırması [API-22]
    - gosec           # yaygın güvenlik hataları
    - misspell

  settings:
    gosec:
      excludes:
        - G104        # errcheck ile örtüşüyor

  exclusions:
    rules:
      # Testlerde bazı kontroller gereksiz gürültü üretir.
      - path: _test\.go
        linters: [errcheck, gosec]
```

**[CI-21] ZORUNLU:** Linter uyarısı `//nolint` ile susturulacaksa **gerekçe yazılır**:
`//nolint:errcheck // kapanışta hata anlamlı değil, süreç zaten sonlanıyor`.
Gerekçesiz `//nolint` reddedilir.

---

## 6. Sürümleme ve etiketleme

**[CI-22] ÖNERİLEN:** Semantic versioning (`v1.4.2`) kullanılır; `main`'e merge edilen
her değişiklik bir imaj etiketi üretir (`<servis>:<commit-sha>` — [OPS-24]).

**[CI-23] ZORUNLU:** Üretime çıkan her sürüm için ne değiştiğini gösteren bir kayıt tutulur
(CHANGELOG ya da release notu). "Dün ne deploy ettik" sorusu tahminle cevaplanmaz.

---

## 7. ASLA YAPMA — git & CI

- ❌ Doğrudan `main`'e push
- ❌ Kırmızı CI ile merge
- ❌ 400+ satırlık, tek konuya odaklanmayan PR
- ❌ Formatlama + refactor + özelliği tek commit'te karıştırmak
- ❌ `.env` / anahtar / sır commit'lemek
- ❌ Gerekçesiz `//nolint`
- ❌ Okumadan onay vermek
- ❌ Testleri CI'da atlamak veya `-race`'i kaldırmak
- ❌ Sırrı pipeline dosyasına yazmak veya loglamak
- ❌ Sürüm/commit bilgisi taşımayan imaj
- ❌ Aynı PR'da hem bağımlılık yükseltip hem özellik eklemek
