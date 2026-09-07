# 01 — Altın Kurallar

> Bu dosyadaki 24 madde **tartışmaya kapalıdır**. Geri kalan her şey bunlardan türer.
> Her madde ayrıntısının bulunduğu dosyaya link verir; emin değilsen oraya git.
> Bu dosya tek başına okunduğunda da bir servisi doğru kurmaya yeter.

---

## A. Stack ve sürüm

**[GEN-01] ZORUNLU — Tek stack.** Tüm HTTP servisleri Go + Gin ile yazılır. Fiber, Echo,
chi, ham `net/http` router karışımı olmaz.
> **Neden:** İki framework demek iki middleware seti, iki hata gövdesi, iki test deseni,
> iki güvenlik yüzeyi demek. Kazanç yok, bakım maliyeti iki katı.
> Ayrıntı: [02-TEKNOLOJI-SURUMLERI.md](02-TEKNOLOJI-SURUMLERI.md)

**[GEN-02] ZORUNLU — Tek sürüm.** Repodaki tüm servisler aynı Go ve aynı Gin sürümünü
kullanır. Sürüm tablosu `02`'dedir; sürüm yükseltmesi **tüm servisler için birlikte** yapılır.
> **Neden:** Servis A Gin v1.10, servis B v1.12 ise, ortak `pkg/` paketi ikisinde farklı
> davranır ve hata sadece birinde çıkar. Teşhisi saatler alır.

**[GEN-03] ZORUNLU — Bağımlılık eklemek onay gerektirir.** `02`'deki tabloda olmayan bir
kütüphaneyi kendi başına ekleme. Ekleniyorsa tabloya da işlenir.
> **Neden:** Her bağımlılık bir güvenlik yüzeyi, bir lisans riski ve bir yükseltme borcudur.
> Standart kütüphaneyle 30 satırda çözülen şey için paket çekilmez.

---

## B. Mimari

**[GEN-04] ZORUNLU — Bağımlılık tek yöne akar:** `handler → service → repository`.
Ters yönde import yok. Repository handler'ı bilmez, service Gin'i bilmez.
> Ayrıntı: [03-PROJE-YAPISI.md](03-PROJE-YAPISI.md)

**[GEN-05] ZORUNLU — Her katman tek iş yapar.**
> - `handler` = HTTP. Girdi doğrulama, status kodu, JSON. **İş kuralı yok.**
> - `service` = iş kuralı ve dönüşüm. **HTTP yok, SQL yok.**
> - `repository` = veri erişimi. **İş kuralı yok, HTTP yok.**

**[GEN-06] ZORUNLU — Servis kendi şemasının sahibidir.** Başka servisin tablosuna doğrudan
`SELECT`/`INSERT` atılmaz; o servisin API'si çağrılır.
> **Neden:** Doğrudan sorgu, o servisin şemasını dondurur. Sahibi kolon adını değiştirdiğinde
> haberi olmayan üç servis birden patlar.

**[GEN-07] ZORUNLU — Interface döndür, struct değil.** Service ve repository katmanı
interface olarak tanımlanır, implementasyon unexported olur.
> **Neden:** DB'siz test yazmanın tek yolu budur. Concrete struct döndüren constructor,
> testi entegrasyon testine mahkûm eder.

**[GEN-08] ZORUNLU — Servisler gateway arkasında çalışır.** Auth, rate limit, CORS ve
public routing gateway'in işidir. Servis iç ağdadır ve dışarı port açmaz.
> Ayrıntı: [05-GUVENLIK.md](05-GUVENLIK.md), [06-RATE-LIMIT-DAYANIKLILIK.md](06-RATE-LIMIT-DAYANIKLILIK.md)

---

## C. Güvenlik

**[GEN-09] ZORUNLU — Gateway'i varsay, gateway'e güvenme.** Gateway JWT'yi doğrular;
servis yine de `X-Gateway-Source` + `X-API-Key` + yetki kontrolünü **kendi** yapar.
> **Neden:** İç ağa erişen biri (yanlış yapılandırılmış bir konteyner, sızmış bir pod)
> gateway'i atlar. Tek katmanlı savunma, savunma değildir.

**[GEN-10] ZORUNLU — Her endpoint'in bir yetkisi vardır.** "Bu uç herkese açık" bilinçli
bir karardır, kod yorumuyla gerekçelendirilir. Unutulmuş olamaz.

**[GEN-11] YASAK — Fail-open.** Yetki servisi/Redis/DB düştüğünde erişim **daralır**,
genişlemez. `if err != nil { return true }` gibi bir yetki fonksiyonu asla yazılmaz.

**[GEN-12] ZORUNLU — Dış dünyadan gelen hiçbir veriye güvenilmez.** Kullanıcı girdisi,
başka servisin yanıtı, dosya, env — hepsi tip ve sınır doğrulamasından geçer.
> Ayrıntı: [05-GUVENLIK.md](05-GUVENLIK.md)

**[GEN-13] YASAK — Sır koda gömmek.** Şifre, token, anahtar; koda, Dockerfile'a, compose'a
ya da git'e girmez. `getEnv("DB_PASSWORD", "Secret123")` gibi bir varsayılan da sırdır.

**[GEN-14] YASAK — SQL'i string birleştirerek kurmak.** Değer **her zaman** parametredir.
`fmt.Sprintf` SQL'de yalnızca placeholder numarası (`$%d`) için kullanılır.

**[GEN-15] YASAK — İç hata detayını istemciye sızdırmak.** Ham sürücü hatası, tablo/constraint
adı, iç servis URL'i, port, stack trace — hiçbiri yanıt gövdesine girmez. Loglanır, maskelenir.

---

## D. Dayanıklılık

**[GEN-16] ZORUNLU — Her ağ çağrısının timeout'u vardır.** HTTP sunucusu, HTTP istemcisi,
DB sorgusu, Redis, Kafka. Varsayılan `http.Client{}` **sonsuz** bekler; kullanılmaz.
> Ayrıntı: [06-RATE-LIMIT-DAYANIKLILIK.md](06-RATE-LIMIT-DAYANIKLILIK.md)

**[GEN-17] ZORUNLU — `context` çağrı zincirinin sonuna kadar taşınır.** İstemci bağlantıyı
kapattığında iş de durmalıdır. Gin'de kaynak `c.Request.Context()`'tir; `*gin.Context`'in
kendisi alt katmana geçirilmez ([YAP-10]).

**[GEN-18] ZORUNLU — `recover` middleware + graceful shutdown.** Tek panic servisi
düşürmez; SIGTERM yarım kalan isteği kesmez.

**[GEN-19] YASAK — Hata yutmak.** `if err != nil { }` ya da `_ = doSomething()` olmaz.
Ya anlamlı şekilde ele al, ya yukarı fırlat, ya da **neden yok saydığını** yoruma yaz.

---

## E. Veri

**[GEN-20] ZORUNLU — "Bilinmiyor" `NULL`'dur; `0` ya da `""` değildir.** Bu ayrım DTO'da
pointer ile korunur. PUT gövdesinde **tüm alanlar pointer**tır.
> **Neden:** Değer tipi kullanırsan tek alan güncellemesi diğer tüm alanları sıfırlar ve
> bu sessizce olur. Ayrıntı: [04-API-SOZLESMESI.md](04-API-SOZLESMESI.md)

**[GEN-21] ZORUNLU — Liste uçları sayfalıdır ve `ORDER BY` benzersiz tie-break içerir.**
> **Neden:** Tie-break'siz sıralamada sayfalar arasında kayıt tekrarlanır ve atlanır; tüm
> sayfaları gezen istemci **eksik veri** toplar ve bunu fark etmez.

**[GEN-22] ZORUNLU — İş kuralı hem uygulamada hem şemada.** Uygulama kontrolü atlanabilir;
`NOT NULL`, `CHECK`, `UNIQUE`, `FOREIGN KEY` atlanamaz.
> Ayrıntı: [07-VERITABANI.md](07-VERITABANI.md)

---

## F. Süreç

**[GEN-23] ZORUNLU — Test yazılmadan "çalışıyor" denmez.** En az: mutlu yol + yetki reddi +
kötü girdi. CI'da `go test -race ./...` koşar.
> Ayrıntı: [12-TEST.md](12-TEST.md)

**[GEN-24] ZORUNLU — Servis yazmak işin yarısıdır.** Gateway route'u, yetki tanımı, env
satırları, compose bloğu, dokümantasyon yapılmadan iş bitmiş sayılmaz.
> Ayrıntı: [15-YENI-SERVIS-CHECKLIST.md](15-YENI-SERVIS-CHECKLIST.md)

---

## Tek sayfalık hatırlatma

```
Tek stack, tek sürüm            → 02
handler → service → repository  → 03
Gateway'e güvenme, kendin doğrula → 05
Timeout + context + recover     → 06
NULL ≠ 0, PUT'ta hepsi pointer  → 04
Sayfala + tie-break'li sırala   → 07
Kural şemada da olsun           → 07
Test yoksa bitmedi              → 12
Checklist geçilmediyse bitmedi  → 15
```
