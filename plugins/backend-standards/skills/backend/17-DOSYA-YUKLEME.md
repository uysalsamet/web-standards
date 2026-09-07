# 17 — Dosya Yükleme, Servis Etme ve Dış Kaynak Çekme

> Dosya yükleme, bir web uygulamasının **saldırgana en çok kontrol verdiği** yerdir:
> içeriği o belirler, adını o belirler, boyutunu o belirler. Bu yüzden buradaki kuralların
> neredeyse tamamı "istemciden geleni kullanma, sen üret" etrafında döner.
>
> Nesne deposu olarak MinIO/S3 varsayılır; dosyalar uygulama sunucusunun diskinde tutulmaz.

---

## 1. Kabul: ne alınır

**[DOSYA-01] ZORUNLU:** Her yükleme ucunun **açık bir boyut sınırı** vardır. Genel 4 MB
gövde limiti ([RES-05]) yükleme ucunda **o uca özel** olarak ayarlanır; genel limit
yükseltilmez.

```go
// Yükleme ucuna özel limit. Genel limiti yükseltmek TÜM uçları savunmasız bırakır.
func UploadLimit(max int64) gin.HandlerFunc {
	return func(c *gin.Context) {
		c.Request.Body = http.MaxBytesReader(c.Writer, c.Request.Body, max)
		c.Next()
	}
}
```

**[DOSYA-02] ZORUNLU:** Dosya **akış hâlinde** işlenir, tümüyle belleğe alınmaz.
`multipart.Reader` ile parça parça oku ve doğrudan nesne deposuna aktar.
> 200 MB'lık bir yüklemeyi belleğe almak, 256 MB'lık konteyner limitinde ([PERF-04])
> tek istekle OOM demektir. Saldırgana gerek yok; büyük bir dosya yeter.

**[DOSYA-03] YASAK — `Content-Type` header'ına güvenmek.** İstemci ne yazarsa yazar.
İçerik **gerçekten** ne olduğuna bakılır:

```go
// İlk 512 bayta bak: http.DetectContentType sihirli baytlardan tipi çıkarır.
// İstemcinin gönderdiği Content-Type bilgi amaçlıdır, KARAR VERİCİ DEĞİL.
head := make([]byte, 512)
n, _ := io.ReadFull(file, head)
detected := http.DetectContentType(head[:n])

if !allowedTypes[detected] {
	badRequest(c, "bu dosya türü kabul edilmiyor")
	return
}
```

**[DOSYA-04] ZORUNLU — İzin verilen tipler beyaz listedir**, kara liste değil:
```go
// BEYAZ liste: neyin geçeceğini sayarsın. Kara liste her zaman eksiktir —
// aklına gelmeyen bir uzantı/tip mutlaka vardır.
var allowedTypes = map[string]struct{}{
	"image/jpeg":       {},
	"image/png":        {},
	"application/pdf":  {},
}
```

**[DOSYA-05] YASAK — SVG'yi "resim" diye kabul etmek.** SVG bir **XML belgesidir** ve
`<script>` çalıştırabilir. Kabul edilecekse ya sunucuda sanitize edilir ya da yalnızca
`Content-Disposition: attachment` ile servis edilir ([DOSYA-11]).

**[DOSYA-06] YASAK — Arşiv dosyasını sunucuda açmak** (gerekli değilse). Gerekiyorsa:
- Açılmış toplam boyut ve dosya sayısı sınırlanır (**zip bomb**: 1 MB'lık arşiv 10 GB açılabilir)
- Her girdinin yolu doğrulanır — `../` içeren girdi reddedilir (**zip slip**: arşiv,
  dosyayı hedef dizinin dışına yazdırabilir)
- Sembolik bağlantı içeren girdiler reddedilir

---

## 2. İsimlendirme ve depolama

**[DOSYA-07] ZORUNLU — İstemcinin gönderdiği dosya adı **asla** dosya sistemi ya da nesne
anahtarı olarak kullanılmaz.** Sunucu yeni bir ad üretir:

```go
// Anahtar SUNUCU tarafından üretilir. İstemcinin adı yalnızca "gösterim adı" olarak,
// ayrı bir kolonda saklanır.
// Neden: "../../etc/passwd", "..\\..\\web.config", NUL bayt, unicode normalizasyon
// hileleri ve aşırı uzun adlar — hepsi dosya adı üzerinden gelir.
objectKey := fmt.Sprintf("uploads/%s/%s%s",
	time.Now().UTC().Format("2006/01"),   // tek dizinde milyonlarca nesne olmasın
	uuid.NewString(),
	safeExt(detected),                     // uzantı TESPİT EDİLEN tipten türetilir
)
```

**[DOSYA-08] ZORUNLU:** Orijinal dosya adı ayrı kolonda saklanır, uzunluğu sınırlanır
([SEC-13]) ve gösterilirken kaçışlanır. İndirme sırasında `Content-Disposition`
header'ına konurken **RFC 5987 kodlaması** kullanılır — Türkçe karakterli ad header'ı bozar.

**[DOSYA-09] ZORUNLU:** Dosyalar **nesne deposunda** (MinIO/S3) tutulur, uygulama
konteynerinin diskinde değil.
> **Neden:** Konteyner diski geçicidir ([PERF-29] stateless kuralı), yeniden başlatmada
> gider ve replikalar arasında paylaşılmaz. Ayrıca uygulama diskine yazma yetkisi,
> yükleme açığını doğrudan kod çalıştırmaya dönüştürebilir.

**[DOSYA-10] ZORUNLU:** Nesne deposu **public değildir**. Bucket varsayılan olarak
kapalıdır; erişim uygulama üzerinden ya da **kısa ömürlü presigned URL** ile verilir.

---

## 3. Servis etme: en kritik bölüm

**[DOSYA-11] ZORUNLU — Kullanıcı yüklemesi ana domain'den servis edilmez.** Üç seçenekten
biri uygulanır:

1. **Ayrı domain** (`files.ornek.gov.tr`) — en güvenlisi
2. Uygulama üzerinden, **her zaman** şu başlıklarla:
   ```
   Content-Disposition: attachment; filename*=UTF-8''<kodlanmis-ad>
   X-Content-Type-Options: nosniff
   Content-Security-Policy: default-src 'none'; sandbox
   Content-Type: application/octet-stream   (görüntülenmesi gerekmiyorsa)
   ```
3. Presigned URL ile doğrudan nesne deposundan (depo ayrı domain'de ise)

> **Neden bu kadar önemli:** Ana domain'den servis edilen bir HTML/SVG dosyası, o
> domain'in **origin'inde** çalışır. Yani yüklenen dosya, oturum çerezlerini okuyabilir
> ve kullanıcı adına istek atabilir — klasik "stored XSS via file upload". `nosniff`
> olmadan tarayıcı içeriği koklayıp `text/html` gibi işleyebilir; `attachment` olmadan
> da tarayıcıda açılır.

**[DOSYA-12] ZORUNLU:** İndirme **her seferinde** yetki kontrolünden geçer ([GEN-10]).
"URL'yi bilen erişir" bir yetkilendirme değildir — UUID tahmin edilemez olsa bile URL
paylaşılır, loglara düşer, `Referer` ile sızar.

**[DOSYA-13] ZORUNLU:** Presigned URL ömrü **kısa** tutulur (varsayılan: 5 dakika) ve
yalnızca gereken işlem için verilir (okuma için okuma, yazma için yazma).

---

## 4. İçerik işleme

**[DOSYA-14] ÖNERİLEN — Görseller yeniden kodlanır (re-encode).** Yüklenen görsel
decode edilip yeniden encode edilerek saklanır.
> **İki kazanç:** (1) Görsel dosyasına gömülmüş yükler (polyglot dosyalar) temizlenir.
> (2) **EXIF verisi silinir** — EXIF içindeki GPS koordinatı ve cihaz bilgisi
> **kişisel veridir** ([KVKK-02]); farkında olmadan toplamak ve yayınlamak istemezsin.

**[DOSYA-15] ZORUNLU:** Görsel decode etmek **güvenli bir işlem değildir**; kaynak
tüketimi sınırlanır: maksimum piksel boyutu (decompression bomb — 100 KB'lık PNG
25.000×25.000 piksele açılabilir), işlem timeout'u, ve tercihen ayrı bir worker sürecinde.

**[DOSYA-16] ÖNERİLEN:** Halka açık (kimliksiz) yükleme varsa **virüs taraması** yapılır
(ClamAV vb.). Tarama asenkron olabilir; dosya taranana kadar "beklemede" durumunda tutulur
ve indirilemez.

**[DOSYA-17] ZORUNLU:** Yüklenen dosya **hiçbir koşulda çalıştırılmaz** — shell komutuna
argüman olarak geçirilmez, `exec` edilmez, dinamik olarak yüklenmez. Bir dış araca
(ffmpeg, imagemagick) verilecekse dosya adı değil, **sunucunun ürettiği anahtar** geçirilir
ve argümanlar dizi olarak verilir, shell ile birleştirilmez.

---

## 5. Dış kaynaktan çekme — SSRF

Bu bölüm "URL'den içe aktar", webhook doğrulama, uzak görsel çekme gibi **sunucunun
kullanıcıdan gelen bir adrese istek attığı** her yer için geçerlidir.

**[DOSYA-18] ZORUNLU:** Kullanıcının verdiği URL'e sunucu doğrudan istek atmaz.
> **Neden (SSRF):** Sunucu iç ağdadır. `http://169.254.169.254/` (bulut metadata servisi),
> `http://localhost:5432`, `http://arnavutkoy-auth-service:3000/` gibi adresler
> **dışarıdan erişilemez ama senin sunucundan erişilir**. Saldırgan, sunucunu iç ağa
> proxy olarak kullanır ve gateway'in tüm korumalarını atlar.

**Uygulama:**
```go
// 1) Şema beyaz listesi: yalnızca http/https. file://, gopher://, dict:// YASAK.
// 2) DNS çözümlemesinden SONRA IP kontrolü — "evil.com" özel IP'ye çözülebilir.
// 3) Yönlendirme TAKİP EDİLMEZ; edilecekse her adımda aynı kontrol tekrarlanır
//    (ilk istek meşru bir adrese, redirect 169.254.169.254'e gidebilir).
func safeDial(ctx context.Context, network, addr string) (net.Conn, error) {
	host, _, _ := net.SplitHostPort(addr)
	ip := net.ParseIP(host)
	if ip == nil || ip.IsLoopback() || ip.IsPrivate() ||
		ip.IsLinkLocalUnicast() || ip.IsUnspecified() {
		return nil, errors.New("bu adrese erişim engellendi")
	}
	return (&net.Dialer{Timeout: 5 * time.Second}).DialContext(ctx, network, addr)
}
```

**[DOSYA-19] ZORUNLU:** Dış çekme isteğinde timeout ([RES-07]), boyut sınırı
(`io.LimitReader`) ve yönlendirme sayısı sınırı bulunur.

**[DOSYA-20] ÖNERİLEN:** Mümkünse **allowlist** kullan: hangi alan adlarından çekilebileceği
sayılıdır. Kara liste (özel IP aralıklarını engelleme) doğru ama eksiktir; beyaz liste
kesindir.

---

## 6. Kota, temizlik, izleme

**[DOSYA-21] ZORUNLU:** Yükleme uçları rate limit'e tabidir ([RES-01] "ağır uçlar"
kategorisi) ve kullanıcı/kurum başına **depolama kotası** vardır. Kotasız yükleme,
maliyeti sınırsız bir kaynaktır.

**[DOSYA-22] ZORUNLU:** Yarım kalan yüklemeler ve **sahipsiz nesneler** (kaydı silinmiş
ama dosyası duran) düzenli olarak temizlenir. Kayıt silindiğinde dosyanın da silinmesi
aynı iş akışında olmalıdır — kişisel veri içeriyorsa bu ayrıca [KVKK-04] gereğidir.

**[DOSYA-23] ZORUNLU:** Yükleme ve indirme işlemleri **denetim izine** yazılır
([AUDIT-01]) — kim ne yükledi, kim ne indirdi. Dosyalar kişisel veri içerebilir.

**[DOSYA-24] ÖNERİLEN:** İzlenecek metrikler ([OBS-12]): yükleme sayısı/boyutu, reddedilen
yükleme sayısı ve **sebebi**, depolama kullanımı, tarama kuyruğu derinliği.

---

## 7. Doğrulama testleri

**[DOSYA-25] ZORUNLU:** Aşağıdakiler test edilir ve hepsi reddedilmelidir:

```
□ Uzantısı .jpg ama içeriği HTML olan dosya          → 400
□ Content-Type: image/png yazan ama PDF olan dosya   → tespit edilen tipe göre karar
□ Dosya adı "../../../etc/passwd"                    → sunucu adı üretir, yol dışına çıkmaz
□ Dosya adı NUL bayt / 500 karakter                  → 400
□ Boyut sınırını 1 bayt aşan dosya                   → 400 (413 de kabul)
□ Sıfır baytlık dosya                                → 400
□ SVG içinde <script>                                → reddedilir veya attachment olarak servis
□ Zip bomb (yüksek sıkıştırma oranı)                 → 400
□ Yetkisiz kullanıcı başkasının dosyasını indirir    → 403
□ Süresi geçmiş presigned URL                        → 403
□ URL'den içe aktarma: http://169.254.169.254        → engellenir
□ URL'den içe aktarma: iç servis adresi              → engellenir
□ Yüklenen dosya ana domain'den HTML olarak açılıyor mu → açılmamalı
```

---

## 8. ASLA YAPMA

- ❌ `Content-Type` header'ına güvenmek
- ❌ Kara liste ile uzantı/tip filtrelemek
- ❌ İstemcinin dosya adını dosya yolu / nesne anahtarı yapmak
- ❌ Dosyayı uygulama konteynerinin diskinde tutmak
- ❌ Kullanıcı yüklemesini ana domain'den, `nosniff`/`attachment` olmadan servis etmek
- ❌ SVG'yi sanitize etmeden "resim" saymak
- ❌ Nesne deposu bucket'ını public yapmak
- ❌ "URL'yi bilen erişsin" mantığı (yetki kontrolsüz indirme)
- ❌ Uzun ömürlü presigned URL
- ❌ Tüm dosyayı belleğe okumak
- ❌ Arşivi sınırsız açmak (zip bomb / zip slip)
- ❌ Görsel decode'unu piksel/timeout sınırı olmadan yapmak
- ❌ EXIF'i temizlemeden konum içerebilecek görseli yayınlamak
- ❌ Yüklenen dosyayı shell komutuna string olarak geçirmek
- ❌ Kullanıcının verdiği URL'e doğrudan istek atmak (SSRF)
- ❌ Yönlendirmeleri kontrolsüz takip etmek
- ❌ Kota ve rate limit olmadan yükleme ucu açmak
- ❌ Sahipsiz dosyaları temizlememek
