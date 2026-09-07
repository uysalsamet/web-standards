# Backend Geliştirme Standardı — İndeks

> **Bu set ne işe yarar:** Bir backend projesine başlarken ya da mevcut bir projeye servis
> eklerken uyulacak **bağlayıcı çizgidir**. Amaç tek: 30 servisin 30 farklı şekilde
> yazılmaması. Kim yazarsa yazsın — insan ya da AI — aynı framework, aynı sürüm, aynı
> klasör, aynı hata gövdesi, aynı limitler.
>
> **Kapsam:** Go + Gin tek stack. Gateway arkasında çalışan mikroservisler.
> Dijital ikiz / GIS projelerine özgü kurallar ayrı ekte (`EK-GIS-POSTGIS.md`), sadece
> harita verisi olan projede okunur.
>
> **Son güncelleme:** 2026-08-12 — sürüm tablosu bu tarihte doğrulandı.

---

## Dosyalar

| # | Dosya | Ne zaman okunur |
|---|---|---|
| 🚀 | [BASLANGIC.md](BASLANGIC.md) | **İlk iş.** Standardı projeye bağlama: `sablon/` kurulumu, açılış promptu, göreve özel girişler |
| 📁 | [sablon/](sablon/) | Kopyalanacak ajan dosyaları: `AGENTS.md` (ortak) + Claude/Cursor/Antigravity/Copilot/Windsurf işaretçileri |
| 01 | [ALTIN-KURALLAR.md](01-ALTIN-KURALLAR.md) | **Her zaman.** Tartışmaya kapalı maddeler. |
| 02 | [TEKNOLOJI-SURUMLERI.md](02-TEKNOLOJI-SURUMLERI.md) | Proje açarken, bağımlılık eklerken, `go.mod` / Dockerfile / compose yazarken |
| 03 | [PROJE-YAPISI.md](03-PROJE-YAPISI.md) | Proje/servis iskeletini kurarken |
| 04 | [API-SOZLESMESI.md](04-API-SOZLESMESI.md) | Endpoint tasarlarken, DTO yazarken, hata döndürürken |
| 05 | [GUVENLIK.md](05-GUVENLIK.md) | Auth, yetki, girdi doğrulama, secret yönetimi |
| 06 | [RATE-LIMIT-DAYANIKLILIK.md](06-RATE-LIMIT-DAYANIKLILIK.md) | Limit, timeout, retry, circuit breaker, shutdown |
| 07 | [VERITABANI.md](07-VERITABANI.md) | Şema, migration, sorgu, pool, index |
| 08 | [CACHE-REDIS.md](08-CACHE-REDIS.md) | Cache ekleyeceğin an |
| 09 | [PERFORMANS-MALIYET.md](09-PERFORMANS-MALIYET.md) | Hedef belirlerken, yavaşlık/maliyet sorununda |
| 10 | [GOZLEMLENEBILIRLIK.md](10-GOZLEMLENEBILIRLIK.md) | Log, metrik, trace, health |
| 11 | [ASENKRON-KAFKA-TEMPORAL.md](11-ASENKRON-KAFKA-TEMPORAL.md) | Senkron istek yetmediğinde |
| 12 | [TEST.md](12-TEST.md) | Kod yazmadan önce |
| 13 | [DOCKER-DEPLOY.md](13-DOCKER-DEPLOY.md) | Dockerfile, compose, env, deploy |
| 14 | [GIT-CI.md](14-GIT-CI.md) | Branch, commit, PR, pipeline |
| 15 | [YENI-SERVIS-CHECKLIST.md](15-YENI-SERVIS-CHECKLIST.md) | İş bitti demeden önce |
| 16 | [PARA-VE-HASSAS-VERI.md](16-PARA-VE-HASSAS-VERI.md) | **Para/tutar, kişisel veri (KVKK) veya denetim izi olan her projede** |
| 17 | [DOSYA-YUKLEME.md](17-DOSYA-YUKLEME.md) | Dosya yükleme, indirme veya dış URL'den içerik çekme varsa |
| 18 | [ESZAMANLILIK-VE-TURKCE-VERI.md](18-ESZAMANLILIK-VE-TURKCE-VERI.md) | **Türkçe veriyle çalışan her projede.** Ayrıca: aynı kaydı birden fazla kişi düzenleyebiliyorsa |
| 19 | [KIMLIK-VE-OTURUM.md](19-KIMLIK-VE-OTURUM.md) | Parola, giriş, token, oturum yöneten servis (auth) |
| 20 | [ENTEGRASYON-VE-TOPLU-VERI.md](20-ENTEGRASYON-VE-TOPLU-VERI.md) | İçe aktarma, zamanlanmış iş, bildirim, giden webhook, canlı akış |
| EK | [EK-GIS-POSTGIS.md](EK-GIS-POSTGIS.md) | **Sadece** harita/geometri verisi varsa |
| 🧭 | [KURAL-HARITASI.md](KURAL-HARITASI.md) | **Kod yazmadan önce her seferinde.** Önündeki koda bakıp hangi kuralların tetiklendiğini söyler + bilinen kapsam boşlukları |
| 🔧 | [arac/](arac/README.md) | Otomatik denetim: `standart-kontrol.sh` + `golangci.yml`. CI'da koşar, 29 kuralı makineye devreder |
| ADR | [adr/](adr/README.md) | **Bir seçimi tartışmadan önce.** 18 karar kaydı: neyi neden seçtik, alternatifler neydi, kararı ne değiştirir |

---

## Kural formatı

Her kural şu biçimde yazılır ve **ID'si değişmez**:

```
[SEC-04] ZORUNLU: Servis, gateway'in doğruladığı JWT'ye güvenmez; kendi
X-Gateway-Source + X-API-Key kontrolünü yapar.

  Neden: Gateway'i atlayıp iç ağdan servise doğrudan istek atan biri, gateway
  kontrollerinin tamamını atlamış olur. Tek katmanlı savunma yeterli değildir.
```

| Seviye | Anlamı |
|---|---|
| **ZORUNLU** | Uyulmadan kod merge edilmez. Gerekçesiz istisna yok. |
| **YASAK** | Yapılırsa kod merge edilmez. |
| **ÖNERİLEN** | Varsayılan davranış budur. Sapıyorsan kod yorumunda **neden** saptığını yaz. |

**İstisna prosedürü:** ZORUNLU/YASAK bir kuraldan sapmak gerekiyorsa, sapan dosyanın
başına şu yorum konur ve PR açıklamasında gerekçe yazılır:

```go
// STANDART İSTİSNASI [DB-07]: Bu tabloda UUID PK yerine BIGSERIAL kullanıldı çünkü
// saniyede 200k satır yazılıyor ve UUID index şişmesi ölçülerek doğrulandı (bkz. PR #142).
```

Gerekçesiz sapma "istisna" değil, hatadır.

---

## AI ajanı bu seti nasıl kullanır

Bir AI ajanına (Claude Code, Copilot, Cursor vb.) bu standardı uygulatıyorsan:

### 1. Okuma sırası

```
Her görevde:  00-README (bu dosya) → 01-ALTIN-KURALLAR → KURAL-HARITASI (sinyal taraması)
Sonra göreve göre yalnızca ilgili dosyalar:
  "yeni servis aç"        → 02, 03, 13, 15
  "endpoint ekle"         → 04, 05, 12
  "yavaş çalışıyor"       → 09, 07, 08
  "kuyruk/worker lazım"   → 11, 06
  "deploy et"             → 13, 14, 10
  "tutar/ödeme/borç var"  → 16 §1  (ZORUNLU — float ile para en pahalı sessiz hatadır)
  "kişisel veri var"      → 16 §2, §3
  "dosya yükleme var"     → 17
  "Türkçe metin arama"    → 18 §2  (ı/İ sorunu — arama sessizce kayıt bulamaz)
  "aynı kaydı 2 kişi düzenler" → 18 §1  (lost update)
  "parola/giriş/token"    → 19
  "veri aktarımı/cron/bildirim/webhook/canlı akış" → 20
```

Tüm dosyaları birden okuma — context israfıdır ve alakasız kurallar kararı bulandırır.

### 2. Uyulacak protokol

- **[GEN-00a] ZORUNLU:** Kod yazmadan önce [KURAL-HARITASI.md](KURAL-HARITASI.md) §1
  sinyal tablosunu tara: yazacağın kodda geçen her sinyal bir kural tetikler. §4'teki
  **bilinen boşluklardan** birine giriyorsan kullanıcıyı uyar.
- **[GEN-00] ZORUNLU:** Kod yazmadan önce ilgili standart dosyasını oku. Hafızandan
  hatırladığını sandığın sürüm/kural ile yazma; dosyada ne yazıyorsa o.
- **[GEN-00b] ZORUNLU:** Bir sürüm seçmen gerekiyorsa `02-TEKNOLOJI-SURUMLERI.md`
  tablosuna bak. Tabloda olmayan bir bağımlılık eklemek **onay gerektirir** — kullanıcıya
  sor, kendi başına ekleme.
- **[GEN-00c] ZORUNLU:** İş bitti demeden önce `arac/standart-kontrol.sh` çalıştır, sonra
  `15-YENI-SERVIS-CHECKLIST.md`'yi madde madde geç ve hangi maddenin neden atlandığını
  açıkça söyle. **Denetimin temiz geçmesi yeterli değildir** — araçlar kuralların ~%9'unu
  görür ([ARAC-04]).
- **[GEN-00d] ZORUNLU:** Standart ile mevcut kod çelişiyorsa **standart kazanır** —
  ama mevcut çalışan koda dokunma; yeni kodu standarda göre yaz ve çelişkiyi rapor et.
  Repoda eski framework'le yazılmış servisler görsen bile **yeni servisi Gin ile yaz**
  ([VER-17]); komşu servisten kopyalama, [03](03-PROJE-YAPISI.md)'teki iskeletten başla.
- **[GEN-00e] YASAK:** "Bu küçük bir değişiklik, standarda bakmama gerek yok" demek.
  Standardın delindiği yer hep küçük değişikliktir.
- **[GEN-00f] ZORUNLU:** "Neden X kullanıyoruz, Y daha iyi değil mi?" sorusuna cevap
  vermeden önce [adr/](adr/README.md) altındaki ilgili karar kaydını oku. Karar zaten
  verilmiş ve gerekçelendirilmiştir. Yeni bir bilgin varsa (yeni sürüm, yeni ölçüm,
  değişen lisans) kaydın **"Kararı ne değiştirir"** bölümüne bak — orada yazan durum
  gerçekleştiyse kaydı yeniden açmayı öner, kendi başına değiştirme.

### 3. Ajan için kısa özet promptu

Bir ajana tek satırda bağlam vermek istersen:

```
Bu projede backend-standartlari/ altındaki standarda uyuyoruz. Go 1.25.12 + Gin v1.12 +
pgx/v5 tek stack. Kod yazmadan önce 01-ALTIN-KURALLAR.md'yi ve yaptığın işe karşılık
gelen dosyayı oku. Kod yazmadan önce KURAL-HARITASI.md §1 sinyal tablosunu tara.
Sürüm seçimi 02-TEKNOLOJI-SURUMLERI.md'den; tabloda olmayan bağımlılığı eklemeden önce
bana sor. Bitirmeden önce 15-YENI-SERVIS-CHECKLIST.md'yi geç.
```

---

## Bu standart nasıl güncellenir

- Standardı değiştiren her karar **gerekçesiyle** yazılır. "Böyle daha iyi" gerekçe değil;
  "şu ölçüm/şu olay şunu gösterdi" gerekçedir.
- Gerçekten yaşanmış bir hata kurala dönüştüğünde, kuralın altına **kısa vakayı** yaz.
  Kural neden var bilinmiyorsa ilk fırsatta silinir.
- Sürüm tablosu (`02`) üç ayda bir gözden geçirilir. Gözden geçirme tarihi dosyanın
  başına yazılır — "son kontrol 8 ay önce" bilgisi, yanlış sürümden daha değerlidir.
- Bir kural üç projede üst üste delinmişse kural yanlıştır, ekip değil. Kuralı düzelt.
