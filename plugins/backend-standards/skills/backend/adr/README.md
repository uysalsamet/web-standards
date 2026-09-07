# Karar Kayıtları (ADR)

> **ADR = Architecture Decision Record.** Her önemli teknik seçim için: neyi seçtik,
> alternatifler neydi, her birinin güçlü/zayıf yanı ne, neden bunu seçtik, ve **kararı
> ne değiştirir**.
>
> **Neden var:** Gerekçesiz bir kural, onu sevmeyen ilk kişi tarafından silinir. "Neden
> Gin, Fiber olsaydı?" sorusu her yeni geliştiriciyle yeniden sorulur. Buradaki kayıtlar
> o tartışmayı bir kez yapıp kapatmak içindir — ve kararın **yanlış olduğu anlaşılırsa**
> nereye bakılacağını söylemek için.

---

## Nasıl okunur

- Bir seçimi tartışmadan önce ilgili ADR'yi oku. Muhtemelen zaten tartışılmıştır.
- ADR'de listelenmemiş yeni bir bilgin varsa — yeni sürüm, yeni ölçüm, değişen lisans —
  o zaman kararı yeniden aç. "Bence şu daha iyi" tek başına yeterli değildir.
- Her ADR'nin sonunda **"Kararı ne değiştirir"** bölümü var. Orada yazan şey gerçekleştiyse
  kararı gözden geçirme zamanı gelmiştir.

## Durum etiketleri

| Durum | Anlamı |
|---|---|
| **Kabul edildi** | Yürürlükte. Standartta uygulanıyor. |
| **Gözden geçiriliyor** | Yeni bilgi çıktı, karar yeniden değerlendiriliyor. |
| **Değiştirildi** | Yerini başka bir ADR aldı; hangisi olduğu yazılır. |
| **Reddedildi** | Değerlendirildi, uygulanmadı. Neden uygulanmadığı kayıtta durur. |

Bir ADR **silinmez**. Yanlış çıktıysa durumu "Değiştirildi" yapılır ve yenisi yazılır —
yanlış kararın kaydı, doğru kararın kaydı kadar değerlidir.

---

## Kayıtlar

### Dil ve HTTP katmanı
| # | Karar | Seçilen | Durum |
|---|---|---|---|
| [0001](0001-http-framework.md) | HTTP framework | **Gin** | Kabul edildi |
| [0002](0002-go-surumu.md) | Go sürüm hattı | **1.25.12** | Kabul edildi |
| [0013](0013-api-protokolu.md) | API protokolü | **REST/JSON** | Kabul edildi |
| [0014](0014-gateway.md) | Gateway | **Kendi Go gateway'imiz** | Kabul edildi |

### Veri
| # | Karar | Seçilen | Durum |
|---|---|---|---|
| [0003](0003-postgres-surucu.md) | Postgres sürücü / ORM | **pgx v5, ORM yok** | Kabul edildi |
| [0004](0004-migration-araci.md) | Migration aracı | **goose** | Kabul edildi |
| [0009](0009-cache-motoru.md) | Cache motoru | **Valkey** | Kabul edildi |
| [0016](0016-veritabani.md) | Birincil veritabanı | **PostgreSQL** | Kabul edildi |

### Uygulama katmanı
| # | Karar | Seçilen | Durum |
|---|---|---|---|
| [0005](0005-loglama.md) | Loglama | **log/slog** | Kabul edildi |
| [0006](0006-konfigurasyon.md) | Konfigürasyon | **os.LookupEnv** | Kabul edildi |
| [0007](0007-girdi-dogrulama.md) | Girdi doğrulama | **Elle, handler'da** | Kabul edildi |
| [0011](0011-test-yaklasimi.md) | Test yaklaşımı | **stdlib + stub + testcontainers** | Kabul edildi |
| [0012](0012-metrik-ve-trace.md) | Metrik ve trace | **Prometheus + OTel** | Kabul edildi |
| [0018](0018-kimlik-dogrulama.md) | Kimlik doğrulama | **Gateway'de JWT** | Kabul edildi |

### Asenkron ve işletme
| # | Karar | Seçilen | Durum |
|---|---|---|---|
| [0008](0008-mesajlasma-altyapisi.md) | Mesajlaşma | **Postgres kuyruğu → Kafka (franz-go)** | Kabul edildi |
| [0010](0010-workflow-motoru.md) | Workflow motoru | **Temporal (yalnız gerektiğinde)** | Kabul edildi |
| [0015](0015-orkestrasyon.md) | Orkestrasyon | **Docker Compose** | Kabul edildi |
| [0017](0017-servis-sinirlari.md) | Servis sınırları | **Modüler monolitten başla** | Kabul edildi |

---

## Yeni ADR yazarken

Dosya adı: `NNNN-kisa-konu.md` (numara artan, asla yeniden kullanılmaz).

```markdown
# ADR-NNNN — <Konu>: <Seçilen>

- **Durum:** Kabul edildi
- **Tarih:** YYYY-AA-GG
- **İlgili kurallar:** [XXX-NN], [YYY-NN]

## Bağlam
Hangi problemi çözüyoruz? Karar vermek zorunda kalmamızın sebebi ne?

## Seçenekler

### A) <Seçenek>
**Güçlü:** …
**Zayıf:** …

### B) <Seçenek>
…

## Karar
Neyi seçtik ve **neden**. Gerekçe ölçüme, kısıta veya somut bir riske dayanmalı;
"daha modern", "herkes bunu kullanıyor" gerekçe değildir.

## Kabul ettiğimiz maliyetler
Bu seçimin bize neye mal olduğu. Her karar bir şeyden vazgeçmektir; vazgeçilen
yazılmazsa karar dürüst değildir.

## Kararı ne değiştirir
Hangi somut gelişme olursa bu kaydı yeniden açarız?
```

**Kural:** "Kabul ettiğimiz maliyetler" bölümü boş bırakılamaz. Hiçbir maliyeti olmayan
bir karar yazdıysan, ya alternatifleri yeterince incelemedin ya da karar zaten
tartışmalı değildi — ikinci durumda ADR'ye gerek yok.
