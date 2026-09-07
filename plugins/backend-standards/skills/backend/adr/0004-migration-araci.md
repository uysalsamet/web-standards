# ADR-0004 — Migration aracı: goose

- **Durum:** Kabul edildi
- **Tarih:** 2026-08-12
- **İlgili kurallar:** [DB-12], [DB-13], [DB-14], [DB-15]

## Bağlam

Şema değişiklikleri versiyonlanmalı, sırayla uygulanmalı, geri alınabilmeli ve rolling
deploy sırasında eski kodu bozmamalı ([DB-13]).

Başlangıç noktamız kötüydü: bazı mevcut servisler `tables/*.sql` dosyalarını glob ile
okuyup `CREATE TABLE IF NOT EXISTS` çalıştırıyordu. Bu yaklaşım **mevcut tabloya kolon
ekleyemez** ve geri alınamaz — ilk şema değişikliğinde elle müdahale gerektirir.

## Seçenekler

### A) goose v3.27.3 (SEÇİLDİ)
**Güçlü:** `-- +goose Up` / `-- +goose Down` blokları **aynı dosyada** — biri yazılıp
diğeri unutulması zorlaşır. Go kütüphanesi olarak **binary'ye gömülebilir**: servis
açılışta kendi migration'ını koşar, deploy akışına ayrı konteyner/adım girmez ([DB-15]).
`-- +goose NO TRANSACTION` ile `CREATE INDEX CONCURRENTLY` desteklenir ([DB-14]).
Veri dönüşümleri için Go ile migration da yazılabilir.
**Zayıf:** Şemanın "olması gereken hâlini" değil adım adım değişimi tarif eder; şema
sürüklenmesini (drift) kendi başına tespit etmez.

### B) golang-migrate v4.19.1
**Güçlü:** Çok yaygın, çok veritabanı destekli, CLI olgun.
**Zayıf:** Up/down **ayrı dosyalarda** — biri güncellenip diğeri unutulabilir. Son sürümü
Kasım 2025; geliştirme hızı goose'a göre yavaş.

### C) Atlas
**Güçlü:** **Deklaratif** — istediğin şemayı yazarsın, farkı o hesaplar. Drift tespiti,
tehlikeli migration lint'i, CI entegrasyonu. Teknik olarak en gelişmiş seçenek.
**Zayıf:** Ayrı araç, ayrı zihinsel model; bazı özellikleri ticari. Küçük/orta ekipte
kurulum ve öğrenme maliyeti kazanımı aşıyor.

### D) Elle glob + `CREATE TABLE IF NOT EXISTS` (legacy durum)
**Güçlü:** Sıfır bağımlılık.
**Zayıf:** Versiyonlanmamış, geri alınamaz, kolon ekleyemez, sırayı garanti etmez.
**Bu bir çözüm değil, ertelenmiş bir borçtur.**

## Karar

**goose.** Belirleyici olan **Go kütüphanesi olarak gömülebilmesi**: servis kendi
migration'ını açılışta koşar, deploy akışı sadeleşir. Up/Down'ın aynı dosyada olması da
pratikte "down'ı yazmayı unutma" hatasını azaltıyor.

## Kabul ettiğimiz maliyetler

- Atlas'ın drift tespiti ve migration lint'inden vazgeçtik. Karşılığında tehlikeli
  migration'ları elle kurala bağladık ([DB-13], [DB-14]) ve entegrasyon testinde
  koşturuyoruz ([TEST-14]).
- Glob tabanlı legacy servislerin migration'ları taşınmalı — ayrı bir iştir.

## Kararı ne değiştirir

- Servis sayısı artıp şema sürüklenmesi gerçek bir probleme dönüşürse Atlas yeniden
  değerlendirilir.
- goose'un bakımı durursa golang-migrate'e geçilir (dosya formatı dönüşümü mekaniktir).
