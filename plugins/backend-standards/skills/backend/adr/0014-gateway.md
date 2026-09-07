# ADR-0014 — Gateway: kendi Go gateway'imiz

- **Durum:** Kabul edildi
- **Tarih:** 2026-08-12
- **İlgili kurallar:** [GEN-08], [SEC-03], [SEC-10], [RES-01], [OPS-18]

## Bağlam

Tek dış kapı gerekiyor: TLS sonlandırma, JWT doğrulama, rate limit, CORS, yönlendirme ve
**en kritiği** — istemciden gelen `X-User-*` header'larının silinip doğrulanmış
değerlerle yeniden yazılması ([SEC-10]).

## Seçenekler

### A) Kendi Go gateway'imiz (SEÇİLDİ)
**Güçlü:** [SEC-10]'daki header yeniden yazma ve [SEC-05]'teki yetki modeli **bize özgü**;
hazır gateway'lerde bu mantık plugin/Lua/WASM ile yazılır. Go ile yazınca aynı dilde,
aynı test araçlarıyla, aynı loglama standardıyla ([OBS-01]) çalışır ve **normal kod gibi
test edilir**. Yetki fallback mantığı ve servis route tablosu tek yerde okunur.
**Zayıf:** Bakımı bize ait. Rate limit, circuit breaker, retry gibi özellikleri kendimiz
yazarız. Güvenlik yamaları bizim sorumluluğumuz.

### B) Traefik
**Güçlü:** Docker etiketleriyle otomatik servis keşfi, otomatik TLS (Let's Encrypt),
olgun middleware seti. Compose ile çok iyi çalışır.
**Zayıf:** Özel yetki mantığı için ForwardAuth ile ayrı bir servise gitmek gerekir —
her istekte fazladan bir ağ turu. Header manipülasyonu yapılandırma diliyle yazılır ve
karmaşıklaştıkça okunmaz hâle gelir.

### C) Kong
**Güçlü:** Zengin plugin ekosistemi, API yönetimi özellikleri, olgun.
**Zayıf:** Ağır (veritabanı gerektirebilir). Plugin yazmak Lua/Go PDK öğrenmek demek.
İhtiyacımızın çok üstünde bir araç.

### D) Envoy
**Güçlü:** Endüstri standardı proxy; en gelişmiş trafik yönetimi, circuit breaker,
observability.
**Zayıf:** Yapılandırması (xDS) dik bir öğrenme eğrisi. Bir kontrol düzlemi olmadan
elle yönetmek zor. Service mesh kurmadığımız sürece fazla.

### E) nginx
**Güçlü:** Herkesin bildiği, çok hızlı, güvenilir.
**Zayıf:** JWT doğrulama ve dinamik yetki için Lua (OpenResty) gerekir. Yapılandırma
test edilemez; hata çalışma zamanında ortaya çıkar.

## Karar

**Kendi Go gateway'imiz.**

Belirleyici gerekçe: gateway'in yaptığı işin **en kritik parçası** ([SEC-10] header
yeniden yazma + [SEC-05] yetki modeli) bize özgü iş mantığıdır, altyapı yapılandırması
değil. Bunu yapılandırma diliyle yazmak, test edilemez ve gözden geçirilemez bir güvenlik
kontrolü üretir — oysa bu, mimarideki **tek kritik nokta**.

Go ile yazınca: normal kod, normal test ([TEST-04] deseni gateway'e de uygulanır),
normal log, normal code review.

## Kabul ettiğimiz maliyetler

- Rate limit ([RES-04]), circuit breaker ([RES-15]), retry ([RES-13]) gibi özellikleri
  kendimiz yazıyoruz ve bakımını üstleniyoruz.
- Otomatik TLS sertifika yönetimi yok — önüne bir reverse proxy (nginx/Caddy/bulut LB)
  konur ya da elle yönetilir.
- Otomatik servis keşfi yok; yeni servis dört adımla elle bağlanır ([OPS-18]…[OPS-22]).
  Bu adımlardan biri unutulduğunda 404 alınır ve teşhisi zaman alır — bu yüzden
  [OPS-20]'de ayrıca uyarı var.

## Kararı ne değiştirir

- Servis sayısı elle route yönetimini hataya açık hâle getirirse (elle bağlama kaynaklı
  hatalar tekrarlanmaya başlarsa) **Traefik + ForwardAuth** değerlendirilir: yönlendirme
  ve TLS ona, yetki mantığı bize kalır.
- Kubernetes'e geçilirse ([ADR-0015](0015-orkestrasyon.md)) ingress controller zaten
  yönlendirmeyi üstlenir ve bu karar yeniden açılır.
