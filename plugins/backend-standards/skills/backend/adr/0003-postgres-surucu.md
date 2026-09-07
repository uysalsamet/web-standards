# ADR-0003 — Postgres erişimi: pgx v5, ORM yok

- **Durum:** Kabul edildi
- **Tarih:** 2026-08-12
- **İlgili kurallar:** [VER-05], [VER-06], [DB-01], [DB-18], [DB-20]

## Bağlam

İki ayrı karar: (1) hangi sürücü, (2) sorguları elle mi yazacağız yoksa bir soyutlama mı
kullanacağız.

## Seçenekler — sürücü

### A) pgx v5.10.0 (SEÇİLDİ)
**Güçlü:** `lib/pq` bakım moduna alındığından beri fiilî standart. Native connection pool
(`pgxpool`), context desteği, `CopyFrom` ile hızlı toplu yükleme, `Batch`, Postgres'e
özgü tiplerin (jsonb, array, geometry) doğru işlenmesi, büyük sonuç kümelerinde belirgin
hız avantajı. Hata nesnesi `*pgconn.PgError` ile SQLSTATE koduna **ve constraint adına**
erişim verir — [DB-20]'deki hata çevirimi tam olarak bunun üzerine kurulu.
**Zayıf:** `database/sql` arayüzünden farklı bir API; `lib/pq` kodu birebir taşınmaz.

### B) lib/pq v1.10.9
**Güçlü:** `database/sql` uyumlu, herkesin bildiği, mevcut legacy kodda zaten var.
**Zayıf:** **Bakım modunda** — yeni özellik gelmiyor. Kendi pool'u yok. Büyük sonuç
kümelerinde daha yavaş.

### C) sqlx
**Güçlü:** `database/sql` üzerine ince katman; struct'a scan etmeyi kolaylaştırır.
**Zayıf:** Sürücü değil, sarmalayıcı — altında yine bir sürücü lazım. Kazandırdığı şeyi
zaten kolon sabiti + ortak `scanX` yardımcısıyla elde ediyoruz.

## Seçenekler — soyutlama

### D) Elle SQL (SEÇİLDİ)
**Güçlü:** Üretilen SQL ne ise odur; `EXPLAIN`'lenebilir, okunabilir, index'e göre
ayarlanabilir. N+1 ve tie-break'siz sıralama gibi problemler **gözle görülür**.
**Zayıf:** Tekrar eden scan/kolon kodu. Sınırlama: kolon sabiti + `scanX` ([DB-17]).

### E) GORM
**Güçlü:** Hızlı başlangıç, otomatik migration, ilişki yönetimi.
**Zayıf:** Ürettiği SQL'i gizler ve N+1'i **kolaylaştırır**. Performans sorunları üretim
yükünde ortaya çıkar; teşhis ORM'in içine bakmayı gerektirir. Otomatik migration üretimde
tehlikelidir. "Yardımcı" davranışları (soft delete gibi) sessizce sorguya karışır.

### F) sqlc
**Güçlü:** SQL yazarsın, tip-güvenli Go kodu üretir. Elle SQL'in kontrolü + kod üretiminin
rahatlığı. **Gerçekten iyi bir seçenek** ve elenmesi yakın oldu.
**Zayıf:** Build akışına kod üretimi ekler. Dinamik sorgular (opsiyonel filtre, dinamik
`WHERE`) için yine elle yazmak gerekir — bizim liste uçlarımızın çoğu dinamik filtreli.

### G) ent
**Güçlü:** Şema-önce, güçlü tip güvenliği, graf sorguları.
**Zayıf:** Kendi dünyası; öğrenme eğrisi dik, çıkış maliyeti yüksek.

## Karar

**pgx v5 + elle yazılmış SQL.**

Sürücüde pgx, `lib/pq` bakım modunda olduğu için tek makul seçim.

Soyutlamada elle SQL, çünkü bu standardın veritabanı kurallarının çoğu — [DB-19]
tie-break, [DB-28] N+1 yasağı, [DB-27] `EXPLAIN` zorunluluğu — **üretilen SQL'i
görebilmeyi** varsayar. ORM bu görünürlüğü kapatır ve kuralları uygulanamaz hâle getirir.

## Kabul ettiğimiz maliyetler

- Her modülde scan/kolon kodu tekrarı; sınırlandırılıyor ama sıfırlanmıyor.
- Tip güvenliği derleyiciden değil testten geliyor → repository entegrasyon testi
  **zorunlu** ([TEST-12]).
- `lib/pq` ile yazılmış legacy kod bu standarda taşınırken elle çevrilmeli.

## Kararı ne değiştirir

- Dinamik filtre ihtiyacı azalır ve sorgular sabitlenirse **sqlc** yeniden değerlendirilir.
- pgx'in bakımı durursa (12 ay+ commit yokluğu) sürücü kararı yeniden açılır.
- Repository tekrarı ölçülebilir bir bakım yüküne dönüşürse sqlc geçişi için ayrı ADR yazılır.
