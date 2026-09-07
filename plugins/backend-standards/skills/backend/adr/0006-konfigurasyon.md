# ADR-0006 — Konfigürasyon: os.LookupEnv

- **Durum:** Kabul edildi
- **Tarih:** 2026-08-12
- **İlgili kurallar:** [VER-08], [YAP-15], [YAP-16], [OPS-14]

## Bağlam

Config env'den gelir ([GEN-13]), koda gömülmez. Soru: env okumak için kütüphane
kullanacak mıyız?

## Seçenekler

### A) os.LookupEnv + elle `getEnv` yardımcısı (SEÇİLDİ)
**Güçlü:** Sıfır bağımlılık. Config yükleme akışı **okunarak** anlaşılır — hangi değişken
nereden geliyor, varsayılanı ne, hepsi tek dosyada görünür. Bozuk değerde ne olacağına
biz karar veririz ([YAP-15]'teki açık `panic` gibi).
**Zayıf:** Her alan için bir satır; alan sayısı arttıkça tekrar.

### B) viper
**Güçlü:** Env + dosya (yaml/toml/json) + flag + uzak config'i birleştirir, canlı yeniden
yükleme yapar.
**Zayıf:** Ağır bağımlılık ve geniş bağımlılık ağacı. Öncelik sırası (env mi, dosya mı,
flag mi kazanır) sihirlidir ve hata ayıklaması zordur. Bize bu özelliklerin **hiçbiri**
lazım değil: 12-factor uygulamada tek kaynak env'dir.

### C) kelseyhightower/envconfig veya caarlos0/env
**Güçlü:** Struct tag ile deklaratif (`env:"DB_HOST"`), daha az tekrar kod.
**Zayıf:** Yine bir bağımlılık; kazancı ~20 satır. Reflection ile çalıştığı için hata
mesajları daha az açık.

### D) koanf
**Güçlü:** viper'ın hafif ve modüler alternatifi.
**Zayıf:** Yine bize gerekmeyen bir problemi (çok kaynaklı config) çözüyor.

## Karar

**os.LookupEnv.** Config kaynağımız tek: **env**. Dosya, uzak sunucu, canlı yeniden
yükleme ihtiyacımız yok — ve olmaması bilinçli: çalışan bir sürecin konfigürasyonunun
altından değişmesi, teşhisi zor bir hata sınıfıdır. Yeniden yapılandırma = yeniden deploy.

## Kabul ettiğimiz maliyetler

- Config alanı başına bir satır tekrar kod.
- Deklaratif tag'lerin okunabilirlik avantajından vazgeçtik.

## Kararı ne değiştirir

- Bir serviste config alan sayısı 30'u aşarsa `caarlos0/env` değerlendirilir.
- Gerçek bir dinamik yapılandırma ihtiyacı doğarsa (ör. özellik bayrakları) bu **config
  değil, ayrı bir problemdir** ve kendi ADR'sini alır.
