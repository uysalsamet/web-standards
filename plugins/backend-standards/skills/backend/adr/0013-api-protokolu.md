# ADR-0013 — API protokolü: REST/JSON

- **Durum:** Kabul edildi
- **Tarih:** 2026-08-12
- **İlgili kurallar:** [API-01], [GEN-06], [GEN-08]

## Bağlam

Servisler hem dış dünyaya (tarayıcı, mobil) hem birbirlerine konuşacak. Bu iki durum
için farklı protokoller seçilebilir.

## Seçenekler

### A) REST/JSON — her yerde (SEÇİLDİ)
**Güçlü:** Tarayıcı doğal olarak konuşur; ara katman gerekmez. Postman/curl ile elle
denenebilir — bu, hata ayıklama ve [TEST-21] elle doğrulama akışı için büyük kolaylık.
Frontend ekibi ek araç öğrenmez. Gateway'de yönlendirme, önbellekleme ve loglama basit.
**Zayıf:** Şema sözleşmesi kod tarafından zorlanmaz — sözleşme dokümanla ve testle
korunur ([API-31]). JSON, protobuf'a göre daha büyük ve daha yavaş serileşir.

### B) gRPC — servisler arası, REST — dışarı
**Güçlü:** Güçlü şema (protobuf), kod üretimi, HTTP/2 multiplexing, streaming, daha küçük
payload. Servisler arası çağrıda tip güvenliği derleme zamanında.
**Zayıf:** İki protokol, iki araç seti, iki hata modeli, iki gözlemlenebilirlik yolu.
Gateway'de gRPC↔REST çevirimi gerekir. Elle test etmek zorlaşır (grpcurl). Bizim
servisler arası çağrı hacmimiz düşük — [GEN-06] gereği servisler zaten birbirinin
veritabanına gitmiyor ve çoğu akış tek servis içinde tamamlanıyor.

### C) Connect (connectrpc)
**Güçlü:** gRPC uyumlu ama **tarayıcıdan doğrudan çağrılabilir**; aynı endpoint hem
gRPC hem HTTP/JSON konuşabilir. gRPC'nin en büyük dezavantajını (tarayıcı erişimi)
kaldırır. `net/http` üzerine kurulu — Gin ile yan yana çalışır.
**Zayıf:** Yine protobuf ve kod üretimi zinciri. Ekosistem gRPC'ye göre küçük.
Kazancı, servisler arası çağrı hacmi yüksek olan sistemlerde ortaya çıkar; bizde değil.

### D) GraphQL
**Güçlü:** İstemci istediği alanı seçer; over-fetching yok. Tek uçtan çok kaynak.
**Zayıf:** Yetkilendirme alan bazına iner ve karmaşıklaşır ([GEN-10] ile gerilim).
N+1 problemi varsayılan davranıştır (dataloader şart). Önbellekleme zorlaşır. Rate limit
"istek sayısı" ile ölçülemez — sorgu maliyeti hesaplamak gerekir ([RES-01] ile gerilim).
Bizim iş yükümüz (CRUD + harita katmanı) GraphQL'in çözdüğü problemi taşımıyor.

## Karar

**REST/JSON, her yerde.**

Belirleyici olan basitlik değil, **tutarlılık maliyeti**: ikinci bir protokol, standardın
tanımladığı her şeyin (hata gövdesi [API-13], sayfalama [API-18], yetki [SEC-05],
gözlemlenebilirlik [OBS-10]) ikinci bir versiyonunu gerektirir. Kazanç ise bizim
kullanım profilimizde küçük — servisler arası çağrı hacmi düşük.

## Kabul ettiğimiz maliyetler

- Şema sözleşmesi kod tarafından zorlanmıyor; kırılmayı test ve doküman yakalıyor.
- Servisler arası çağrılarda JSON serileştirme maliyeti ve tip güvensizliği.
- Streaming gereken senaryolar için ayrı bir çözüm (SSE/WebSocket) gerekecek.

## Kararı ne değiştirir

- Servisler arası çağrı hacmi belirgin şekilde artar ve JSON serileştirme ölçülebilir
  bir maliyete dönüşürse **Connect** değerlendirilir (gRPC'den önce — tarayıcı uyumu
  sayesinde ikinci bir protokol yükü daha hafif).
- Gerçek zamanlı akış (canlı konum, telemetri) ihtiyacı doğarsa bu **ayrı bir karardır**
  ve REST kararını iptal etmez.
