# ADR-0018 — Kimlik doğrulama: gateway'de JWT, servislerde paylaşılan sır + yetki header'ı

- **Durum:** Kabul edildi
- **Tarih:** 2026-08-12
- **İlgili kurallar:** [SEC-03], [SEC-04], [SEC-05], [SEC-10], [GEN-09]

## Bağlam

İki ayrı problem var:
1. **Kullanıcı kimliği:** İstemci kim olduğunu nasıl kanıtlıyor?
2. **Servisler arası güven:** Bir servis, isteğin gerçekten gateway'den geldiğini
   nasıl biliyor?

## Seçenekler — kullanıcı kimliği

### A) JWT, yalnızca gateway'de doğrulanır (SEÇİLDİ)
**Güçlü:** Durumsuz; gateway her istekte DB'ye gitmeden doğrular. Doğrulama **tek yerde**
olduğu için `alg=none`, süre kontrolü, imza doğrulama gibi kritik kontroller bir kez ve
doğru yazılır ([SEC-03]). Servisler JWT kütüphanesi bile import etmez.
**Zayıf:** İptal (revocation) zor — token süresi dolana kadar geçerlidir. Çözüm: kısa
ömürlü access token + refresh token + iptal listesi (Redis).

### B) Her serviste JWT doğrulama
**Güçlü:** Gateway atlanırsa da koruma var.
**Zayıf:** 30 serviste tekrarlanan güvenlik kodu; biri mutlaka bir kontrolü atlar.
İmzalama anahtarı 30 servise dağıtılır — saldırı yüzeyi 30 kat.

### C) Opak token + introspection
**Güçlü:** Anında iptal edilebilir; token içeriği dışarı sızmaz.
**Zayıf:** Her istekte auth servisine bir çağrı — gecikme ve tek hata noktası.
Auth servisi düştüğünde [SEC-08] gereği fail-close, yani tüm sistem durur.

### D) Session cookie (sunucu tarafı oturum)
**Güçlü:** Anında iptal, basit zihinsel model.
**Zayıf:** Durum tutar ([PERF-29] ile gerilim); mobil/servisler arası kullanımda zahmetli.

## Seçenekler — servisler arası güven

### E) `X-Gateway-Source` + paylaşılan `X-API-Key` + `X-User-Permissions` (SEÇİLDİ)
**Güçlü:** Basit, hızlı, ek altyapı yok. Servis, gateway'i atlayan isteği reddeder
([SEC-04]) — yani iç ağ "güvenilir" varsayılmaz ([GEN-09]).
**Zayıf:** Paylaşılan sır tek bir değerdir; sızarsa tüm servisler etkilenir. Rotasyonu
elle yapılır. İç ağı dinleyebilen biri header'ları görebilir (iç trafik TLS'siz ise).

### F) mTLS (karşılıklı sertifika)
**Güçlü:** Kriptografik olarak güçlü; her servis kendi kimliğine sahip. Sızan tek sır
diye bir şey yok.
**Zayıf:** Sertifika üretimi, dağıtımı, yenilenmesi — bir PKI işletmek demek. Service
mesh olmadan elle yönetimi zahmetli.

### G) Servis başına JWT (iç token)
**Güçlü:** Her servisin kendi kimliği; süreli ve iptal edilebilir.
**Zayıf:** Bir token servisi ve dağıtım mekanizması gerektirir.

## Karar

**Gateway'de JWT + servislerde `X-Gateway-Source`/`X-API-Key`/`X-User-Permissions`.**

Bu mimarinin **tek kritik noktası** [SEC-10]: gateway, istemciden gelen `X-User-*` ve
`X-Gateway-*` header'larını **silmek** ve kendi doğruladığı değerlerle yeniden yazmak
zorundadır. Bunu yapmazsa istemci `X-User-Permissions: *` göndererek superadmin olur.
Bu yüzden gateway'de bu davranışın testi zorunludur.

Servis tarafında kontrolün **atlanmaması** da kritik: sır boşsa istek reddedilir
([SEC-04]), "sır tanımlı değilse kontrolü geç" yazımı yasaktır.

## Kabul ettiğimiz maliyetler

- Paylaşılan sır modeli mTLS kadar güçlü değil; sızma durumunda tüm servislerde rotasyon
  gerekir. Karşı önlemler: ortamlar arası farklı sır ([SEC-24]), en az 32 rastgele bayt,
  git'e girerse zorunlu rotasyon ([SEC-22]).
- JWT iptali gecikmeli; kısa ömürlü token ve iptal listesi ile sınırlanır.
- Servisler kullanıcı kimliğini **doğrulamıyor**, gateway'in verdiği bilgiye güveniyor —
  bu güven, [SEC-04]'teki kontrolle sınırlanmış durumda.

## Kararı ne değiştirir

- İç ağ güven modeli değişirse (çok kiracılı ortam, paylaşılan altyapı) **mTLS**
  değerlendirilir.
- Kubernetes'e geçilir ve bir service mesh (Linkerd/Istio) devreye girerse mTLS
  neredeyse bedava gelir; o zaman paylaşılan sır kaldırılır.
- Anında iptal yasal/işlevsel bir zorunluluk hâline gelirse opak token + introspection
  yeniden değerlendirilir.
