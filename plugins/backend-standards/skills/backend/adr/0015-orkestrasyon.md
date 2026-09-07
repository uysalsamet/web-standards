# ADR-0015 — Orkestrasyon: Docker Compose

- **Durum:** Kabul edildi
- **Tarih:** 2026-08-12
- **İlgili kurallar:** [OPS-09], [OPS-11], [PERF-04], [PERF-30]

## Bağlam

Servisler konteynerize ediliyor ([OPS-01]). Bunları hem geliştirmede hem üretimde
çalıştıracak bir mekanizma gerekiyor.

## Seçenekler

### A) Docker Compose (SEÇİLDİ)
**Güçlü:** Tek dosya, tek komut, sıfır öğrenme maliyeti. Geliştirme ortamı ile üretim
**aynı** dosyayı kullanır (farklı `--env-file` ile) — "bende çalışıyordu" sınıfı hataları
azaltır. Kaynak limitleri ([PERF-04]), healthcheck bağımlılığı ([OPS-10]) ve log
rotasyonu ([OPS-12]) destekleniyor.
**Zayıf:** Tek makine. Otomatik ölçekleme, kendi kendini iyileştirme (self-healing),
rolling update ve dağıtık zamanlama yok. `restart: unless-stopped` ile sınırlı bir
dayanıklılık sağlanır.

### B) Kubernetes
**Güçlü:** Yatay ölçekleme, self-healing, rolling update, service discovery, secret
yönetimi, çok düğüm. Endüstri standardı.
**Zayıf:** **Büyük bir işletme yükü.** Cluster kurulumu/yönetimi, ingress, CNI, storage
class, RBAC, Helm/Kustomize — hepsi öğrenilecek ve bakımı yapılacak. Tek makinede
çalışan bir sistem için k8s, çözdüğünden fazla problem yaratır. Yönetilen bir servis
(EKS/GKE) bu yükü azaltır ama maliyeti ve bulut bağımlılığını artırır.

### C) Nomad
**Güçlü:** k8s'ten belirgin şekilde basit; tek binary, öğrenmesi kolay. Çok düğüm ve
zamanlama var.
**Zayıf:** Ekosistem k8s'e göre çok küçük. Aradaki boşluğu doldurur ama "ne compose
kadar basit ne k8s kadar yaygın" konumunda kalır.

### D) Docker Swarm
**Güçlü:** Compose dosyasına çok yakın, çok düğüm ekler.
**Zayıf:** Geliştirmesi fiilen durdu; yeni projede tercih edilmez.

## Karar

**Docker Compose.**

[PERF-30] ile aynı mantık: **önce dikey, sonra yatay.** Tek makinede çalışabilen bir
sistem için Kubernetes kurmak, çözülmemiş bir problemi çözmek için ciddi bir işletme
yükü almaktır. Compose ile başlamak, k8s'e geçişi de engellemez — konteyner imajları,
healthcheck'ler, env tabanlı config ([OPS-14]) ve stateless servisler ([PERF-29]) zaten
k8s'in beklediği şeyler. Yani bu standarda uyan bir sistem, gerektiğinde k8s'e taşınmaya
**hazır** hâlde duruyor.

## Kabul ettiğimiz maliyetler

- Tek makine sınırı; o makine düşerse sistem düşer.
- Rolling update yok — deploy sırasında kısa kesinti olabilir. [OPS-25]'teki "eski ve
  yeni sürüm aynı anda çalışır" kuralı bu yüzden hâlâ önemli: k8s'e geçildiğinde
  hazır olmak için.
- Otomatik ölçekleme yok; replika sayısı elle ayarlanır.

## Kararı ne değiştirir

- **Yüksek erişilebilirlik gerçek bir gereksinim hâline gelirse** (tek makine kesintisi
  kabul edilemezse) k8s'e geçilir.
- Trafik tek makinenin kapasitesini aşarsa önce dikey büyütülür ([PERF-30]), sonra k8s.
- Ekipte k8s işletme kapasitesi oluşursa ve birden fazla ortam yönetiliyorsa geçiş
  maliyeti düşer; karar yeniden değerlendirilir.
