# ADR-0017 — Servis sınırları: modüler monolitten başla

- **Durum:** Kabul edildi
- **Tarih:** 2026-08-12
- **İlgili kurallar:** [GEN-06], [YAP-04], [ASYNC-25], [DB-03]

## Bağlam

Bu standart mikroservis mimarisini varsayıyor ([GEN-08] gateway + servisler). Ama
**kaç servis** olacağı ayrı bir sorudur ve en pahalı hatalar burada yapılır: iş alanı
yeterince anlaşılmadan çizilen servis sınırları sonradan düzeltilemez.

## Seçenekler

### A) Yeni projede modüler monolitle başla (SEÇİLDİ)
Tek deploy edilebilir birim, ama içinde net modül sınırları: her modül kendi
`handler → service → repository` zincirine ve kendi tablolarına sahip; modüller
birbirinin repository'sini **çağırmaz**, service arayüzünden geçer.
**Güçlü:** Sınırlar yanlış çizilirse düzeltmek bir refactor'dur, bir migrasyon projesi
değil. Tek deploy, tek log akışı, tek DB bağlantısı ([DB-03] bütçesi rahat), dağıtık
transaction problemi yok, yerel çağrı — ağ hatası ve gecikme yok.
**Zayıf:** Tek hata alanı; bir modülün paniği tümünü etkiler (kısmen [RES-18] ile
sınırlanır). Modüller bağımsız ölçeklenemez. Sınır disiplini **kod incelemesiyle**
korunur; derleyici zorlamaz (Go'da `internal/` ile kısmen zorlanabilir).

### B) Baştan mikroservis
**Güçlü:** Bağımsız deploy ve ölçekleme, teknoloji özgürlüğü, net ekip sahipliği.
**Zayıf:** Sınırlar iş alanı anlaşılmadan çizilir ve **yanlış çizilir**. Sonucu:
her özellik için üç servisi birden değiştirmek, dağıtık transaction, eventual
consistency'nin her yerde ortaya çıkması ([ASYNC-25]), izlemenin trace olmadan
imkânsızlaşması ([OBS-14]), N servis × M bağlantı ile Postgres bağlantı bütçesinin
patlaması ([DB-03]). Bu maliyetler ilk günden, kazanç ise ancak ölçekte gelir.

### C) Alan bazlı, kaba taneli servisler
Örnek: "ulaşım", "altyapı", "sosyal hizmetler" gibi 3–5 servis; her biri kendi içinde
modüler.
**Güçlü:** İki uç arasında makul denge; ekip sahipliğiyle örtüşür.
**Zayıf:** Sınırın nereden geçtiği yine bir tahmindir — sadece daha az sayıda tahmin.

## Karar

**Yeni projede modüler monolitle başla; bir modülü servise ayırmak için somut gerekçe iste.**

Servise ayırmayı haklı çıkaran gerekçeler:
- Modülün **ölçekleme profili** farklı (ör. harita/tile trafiği diğerlerinin 100 katı).
- Modülün **değişim hızı** ve sahibi farklı bir ekip.
- Modülün **hata izolasyonu** kritik (çökmesi diğerlerini etkilememeli).
- Modül farklı bir **çalışma zamanı** gerektiriyor (ör. GPU, farklı dil).

"İleride büyürüz" bu gerekçelerden biri **değildir**.

Bu standardın kuralları her iki durumda da geçerlidir; modüler monolitte "servis" yerine
"modül" okunur. [GEN-06] (kendi şemasının sahibi) modül düzeyinde de uygulanır — böylece
ayırma günü geldiğinde iş mekanik olur.

> **Not:** Mevcut mikroservis repoları bu ADR'nin kapsamı dışındadır. Bu karar
> **yeni projelere** yöneliktir ve çalışan bir sistemi birleştirmek için gerekçe değildir.

## Kabul ettiğimiz maliyetler

- Bağımsız ölçekleme ve bağımsız deploy avantajını başlangıçta almıyoruz.
- Modül sınırlarının korunması disipline bağlı; ihlali derleyici değil, code review
  yakalar ([CI-11] adım 6).
- Ayırma günü geldiğinde bir refactor işi çıkacak — ama sınırlar doğru çizilmiş olacağı
  için bu iş **bilinen** bir iştir.

## Kararı ne değiştirir

- Yukarıdaki dört gerekçeden biri somut olarak ortaya çıkarsa o modül ayrılır.
- Ekip sayısı artıp aynı kod tabanında çakışma gerçek bir yavaşlatıcıya dönüşürse
  alan bazlı ayırma değerlendirilir.
