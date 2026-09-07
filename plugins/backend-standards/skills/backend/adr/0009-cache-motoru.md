# ADR-0009 — Cache motoru: Valkey

- **Durum:** Kabul edildi
- **Tarih:** 2026-08-12
- **İlgili kurallar:** [VER-10], [VER-12], [CACHE-01], [CACHE-23]

## Bağlam

Cache, dağıtık kilit ve rate limit sayacı için bellek-içi bir veri deposuna ihtiyaç var
([08](../08-CACHE-REDIS.md)).

Bu, saf teknik bir karar değil — **lisans** kararı. Kısa tarihçe:

- 2024 Mart: Redis, yıllardır kullandığı BSD lisansından ayrıldı (RSALv2 + SSPLv1).
- Buna tepki olarak Linux Foundation çatısı altında **Valkey** fork'u doğdu; Redis
  7.2.4'ten (son BSD sürümü) devam etti ve **BSD-3**'te kaldı.
- Redis 8 ile üçüncü seçenek olarak **AGPLv3** eklendi.

Standardımızın kendi kuralı ([02](../02-TEKNOLOJI-SURUMLERI.md) §4) GPL/AGPL lisanslı
bağımlılıkların **onay gerektirdiğini** söylüyor — yani bu kararı atlamak mümkün değildi.

## Seçenekler

### A) Valkey 9.1.1 (SEÇİLDİ)
**Güçlü:**
- **BSD-3** — permissive; hukuki inceleme, açıklama veya istisna gerektirmez.
- **Linux Foundation yönetişimi** — tek bir şirketin lisans kararına bağımlılık yok.
  Bu problemi bir kez yaşadık; ikinci kez yaşamamak somut bir kazanç.
- **Wire-compatible**: `go-redis` aynen çalışır. Komutlar, Lua script'leri, `SETNX`+TTL
  kilit deseni ([CACHE-19]), `INCR`+`EXPIRE` sayacı ([RES-04]) — hepsi aynı.
  **Geçiş maliyeti pratikte imaj adını değiştirmek.**
- Büyük Linux dağıtımlarında varsayılan cache paketi; AWS ElastiCache/MemoryDB'de
  varsayılan ve Redis OSS'ten ucuz. Yayınlanan karşılaştırmalarda daha iyi ops/sn,
  daha düşük p99 ve daha az bellek kullanımı bildiriliyor.

**Zayıf:**
- Marka tanınırlığı Redis kadar değil; "Redis" refleksi ekipte yerleşik.
- Redis Stack modülleri (RedisJSON, RediSearch, TimeSeries) yok — Valkey'in kendi
  modül ekosistemi ayrı gelişiyor.

### B) Redis 8.x
**Güçlü:** En yaygın, en çok örnek, en büyük mindshare. `go-redis` resmî istemcisi.
Redis Stack modülleri mevcut.
**Zayıf:** **AGPLv3.** İçeride cache olarak çalıştırmak çoğu yorumda sorun yaratmaz
(dağıtım ya da servis olarak sunum yok), ancak birçok kurumsal hukuk departmanı AGPL'i
kategorik olarak yasaklar ve denetimde açıklama gerektirir. **"Muhtemelen sorun değil"
bir lisans stratejisi değildir.**

### C) Dragonfly
**Güçlü:** Redis uyumlu, çok çekirdekli mimari, tek düğümde çok yüksek verim.
**Zayıf:** Genç; kaynak-erişilebilir lisans (BSL) — yine hukuki inceleme. Çözdüğü problem
(tek düğüm verim tavanı) bizde yok.

### D) memcached
**Güçlü:** Basit, hızlı, permissive lisans.
**Zayıf:** Yalnızca düz key-value. Atomik kilit ([CACHE-19], [CACHE-20]) ve rate limit
sayacı ([RES-04]) için gereken `SETNX`/Lua/`INCR` semantiği yok.

### E) Süreç-içi cache (ristretto vb.)
**Güçlü:** Ağ turu yok, en hızlısı, bağımlılık yok.
**Zayıf:** Replikalar arası paylaşılmaz — rate limit sayacını 3 replikada 3 katına
çıkarır ([RES-04]) ve dağıtık kilit imkânsızdır. Ancak gerçekten değişmeyen referans
verisi için **ek** bir katman olarak düşünülebilir.

## Karar

**Valkey 9.1.1** (`valkey/valkey:9.1.1-alpine`), istemci `go-redis v9`.

Teknik olarak Redis ile Valkey arasında bizim kullanımımız için **fark yok** — wire
uyumlu oldukları için tek satır kod değişmiyor. Fark tamamen lisans ve yönetişimde,
ve orada Valkey açık ara önde:

- BSD-3, standardın kendi lisans kuralıyla uyumlu; onay/istisna süreci gerekmiyor.
- Vakıf yönetişimi, tek şirketin lisans kararına bağımlılığı kaldırıyor.
- Geçiş maliyeti sıfıra yakın olduğu için "Redis'te kalıp sonra bakarız" demenin
  bir kazancı yoktu.

## Kabul ettiğimiz maliyetler

- Redis Stack modülleri (RedisJSON/RediSearch) kapanıyor. Şu an kullanılmıyor; arama
  ihtiyacı ayrı bir bileşenle karşılanıyor. İleride gerekirse bu karar yeniden açılır.
- Ekipte "Redis" refleksinin "Valkey" olarak öğrenilmesi gerekiyor. Kod ve komutlar aynı
  olduğu için maliyet düşük; dokümantasyonda `Redis` geçen yerler **protokolü** kastediyor
  ([08](../08-CACHE-REDIS.md) başlığında belirtildi).
- Redis'in devasa örnek/StackOverflow havuzu birebir geçerli olsa da, Valkey'e özgü
  sorunlarda kaynak daha az.

## Kararı ne değiştirir

- **RedisJSON/RediSearch gibi bir modüle gerçek ihtiyaç doğarsa** Redis lehine ağırlık
  kayar (ya da Valkey'in modül ekosistemi değerlendirilir).
- Redis lisansını tekrar permissive yaparsa karar konusuz kalır; o durumda "yaygınlık"
  gerekçesiyle geri dönüş tartışılabilir.
- Valkey'in geliştirmesi durur veya yönetişimi değişirse karar yeniden açılır.
