# ADR-0016 — Birincil veritabanı: PostgreSQL

- **Durum:** Kabul edildi
- **Tarih:** 2026-08-12
- **İlgili kurallar:** [DB-05], [DB-08], [GEN-06], [ASYNC-03]

## Bağlam

Servislerin kalıcı veri deposu. [GEN-06] gereği her servis kendi şemasının sahibi;
ancak fiziksel olarak aynı Postgres örneğini (farklı şema/veritabanı ile) paylaşabilirler.

## Seçenekler

### A) PostgreSQL 18 (SEÇİLDİ)
**Güçlü:** İlişkisel bütünlük ([DB-07] FK, [DB-08] CHECK) — standardın "iş kuralı şemada
da olsun" ilkesi buna dayanıyor. `jsonb` ile yarı-yapılandırılmış veri, `GENERATED`
kolonlar ([DB-09]), CTE, pencere fonksiyonları, `FOR UPDATE SKIP LOCKED` ile iş kuyruğu
([ASYNC-03]), tam metin arama, ve **PostGIS** ile birinci sınıf coğrafi veri
([EK-GIS](../EK-GIS-POSTGIS.md)). Permissive lisans. Olgun ekosistem.
**Zayıf:** Yatay yazma ölçeklemesi yerleşik değil. Bağlantı başına süreç modeli, çok
servisli kurulumda PgBouncer'ı zorunlu kılar ([DB-03]).

### B) MySQL / MariaDB
**Güçlü:** Çok yaygın, basit replikasyon.
**Zayıf:** Coğrafi destek PostGIS seviyesinde değil. `jsonb` karşılığı zayıf. CHECK
constraint desteği tarihsel olarak sorunlu. Bizim kural setimizin dayandığı özelliklerin
birçoğu ya yok ya zayıf.

### C) MongoDB
**Güçlü:** Şemasız esneklik, kolay yatay ölçekleme.
**Zayıf:** Bu standardın **temel varsayımıyla çelişir**: [GEN-22] "iş kuralı şemada da
olsun". Şema zorlaması olmayan bir sistemde `NOT NULL`, `CHECK`, FK yoktur; veri
tutarlılığı tamamen uygulama katmanına kalır — ve [DB-07] vakası tam olarak bunun neden
yetmediğini gösteriyor.

### D) CockroachDB
**Güçlü:** Postgres uyumlu, dağıtık, otomatik yatay ölçekleme.
**Zayıf:** Ölçeğimiz bunu gerektirmiyor. Bazı Postgres özellikleri (PostGIS dâhil) tam
desteklenmiyor. İşletme karmaşıklığı yüksek.

### E) ClickHouse — **analitik için ek olarak**
**Güçlü:** Sütun tabanlı; büyük hacimli zaman serisi/telemetri sorgularında Postgres'ten
kat kat hızlı.
**Zayıf:** Transaction/tekil güncelleme için uygun değil. **Postgres'in yerine geçmez,
yanına gelir.**

## Karar

**PostgreSQL 18, birincil veri deposu olarak.**

Standardın veritabanı kurallarının çoğu ([DB-05]…[DB-09]) Postgres'in sunduğu bütünlük
mekanizmalarına dayanıyor. Ayrıca Postgres, üç ayrı ihtiyacı tek bileşende karşılıyor:
ilişkisel veri, coğrafi veri (PostGIS) ve iş kuyruğu ([ASYNC-03]) — bu, işletilecek
bileşen sayısını azaltan somut bir kazanç.

**ClickHouse ek olarak**, yalnızca gerçekten analitik yük varsa (yüksek hacimli sensör/
telemetri verisi üzerinde toplulaştırma) ve o zaman da Postgres'in yerine değil yanına.

## Kabul ettiğimiz maliyetler

- Yatay yazma ölçeklemesi yok; sınıra gelinirse okuma replikası, partitioning veya
  sharding elle planlanır.
- Çok servisli kurulumda **PgBouncer zorunlu** ([DB-03]) — işletilecek bir bileşen daha.
- Analitik yük gelirse ikinci bir veri deposu (ClickHouse) ve veri akışı gerekecek.

## Kararı ne değiştirir

- Tek Postgres örneği yazma yükünü kaldıramazsa: önce dikey büyütme + okuma replikası,
  sonra partitioning, en son sharding/CockroachDB.
- Zaman serisi hacmi Postgres'i zorlarsa **ClickHouse** (veya TimescaleDB uzantısı)
  ayrı bir ADR ile eklenir.
