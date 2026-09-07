# ADR-0010 — Workflow motoru: Temporal, yalnızca gerektiğinde

- **Durum:** Kabul edildi
- **Tarih:** 2026-08-12
- **İlgili kurallar:** [ASYNC-18], [ASYNC-19], [ASYNC-20], [ASYNC-26]

## Bağlam

Bazı işler tek bir istek-yanıt döngüsüne sığmaz: çok adımlı onay akışları, günlerce
sürebilen süreçler, adım başarısız olduğunda **telafi** (compensation) gerektiren işler,
zamanlanmış hatırlatmalar.

Bunları elle yazmak, her seferinde bir durum makinesi + retry + zamanlayıcı + kalıcılık
yazmak demektir; ve o kod her projede biraz farklı, biraz hatalı olur.

## Seçenekler

### A) Temporal v1.47.0 SDK / Server 1.31.2 (SEÇİLDİ — koşullu)
**Güçlü:** Uzun süreli iş akışları için sınıfının en olgunu. Durum kalıcılığı, retry,
timeout, telafi (SAGA), zamanlayıcı, insan onayı bekleme — hepsi altyapıdan gelir.
Workflow kodu normal Go koduymuş gibi yazılır; çökmeler ve yeniden başlatmalar şeffaftır.
Görünürlük arayüzü ile hangi akışın nerede takıldığı görülebilir.
**Zayıf:** **Ciddi bir altyapı**: sunucu + kendi veritabanı + worker'lar + izleme.
Determinizm kısıtı ([ASYNC-20]) yeni bir zihinsel model gerektirir ve ihlali haftalar
sonra ortaya çıkan bir hata sınıfı üretir. Workflow versiyonlama ([ASYNC-23]) disiplin ister.

### B) river (Postgres tabanlı iş kuyruğu)
**Güçlü:** Postgres üzerine kurulu; **yeni altyapı bileşeni yok**. İşleri uygulama
verisiyle aynı transaction'da kuyruğa alır — outbox problemi çözülür. Aktif geliştiriliyor,
`CopyFrom` ile toplu ekleme, zamanlanmış iş desteği.
**Zayıf:** Bir **iş kuyruğu**dur, workflow motoru değil. Çok adımlı akış, telafi ve
"3 gün sonra devam et" gibi uzun süreli durum yönetimi elle kurulur.

### C) asynq (Redis tabanlı)
**Güçlü:** Basit, Redis üzerinde çalışır, iyi bir yönetim arayüzü var.
**Zayıf:** Redis'i kritik kalıcı rolde kullanır ([CACHE-24] ile gerilim). Geliştirme
hızı yavaşladı. Yine workflow değil, kuyruk.

### D) Elle durum makinesi + cron
**Güçlü:** Sıfır ek altyapı; tam kontrol.
**Zayıf:** Retry, idempotency, zamanlama, gözlemlenebilirlik, telafi — hepsini kendin
yazarsın ve her biri ayrı bir hata kaynağıdır. İkinci akışta pişman olunur.

### E) Cadence
**Güçlü:** Temporal'ın atası; benzer yetenekler.
**Zayıf:** Ekosistem ve geliştirme Temporal'a kaydı. Yeni projede tercih edilmez.

## Karar

**Temporal — ama yalnızca [ASYNC-18]'deki koşullar gerçekten varsa.**

Karar ağacı ([ASYNC-01]):
- Tek adımlı, kaybı tolere edilemeyen arka plan işi → **Postgres kuyruğu** (river'ın
  çözdüğü problem; kendi ~50 satırımızla da çözülüyor — [ASYNC-03]).
- Çok adımlı, telafi gerektiren, günler süren akış → **Temporal**.
- Basit bir kuyruk işi için Temporal kurmak **yasaktır** ([ASYNC-19]).

Temporal güçlü ama ağır bir araçtır; onu kurma kararı, çözdüğü problemin gerçekten
var olduğunun gösterilmesine bağlıdır.

## Kabul ettiğimiz maliyetler

- Temporal kurulduğunda işletilecek bir bileşen daha olur (sunucu + DB + worker).
- Determinizm kısıtı, ekibin öğrenmesi gereken yeni bir kural setidir; ihlali sessiz
  ve gecikmeli hata üretir.
- İki farklı asenkron mekanizma (Postgres kuyruğu + Temporal) bir arada bulunabilir;
  "hangisi ne zaman" sorusu [ASYNC-01] ile bağlanmıştır ama yine de bir karar yüküdür.

## Kararı ne değiştirir

- Yalnızca basit arka plan işleri varsa Temporal hiç kurulmaz; **river** o zaman kendi
  kuyruk kodumuzun yerine değerlendirilir (kod tekrarını azaltır).
- Temporal'ın işletme maliyeti kazancı aşarsa (izlenir) akışlar sadeleştirilir.
