# ADR-0002 — Go sürüm hattı: 1.25.12

- **Durum:** Kabul edildi
- **Tarih:** 2026-08-12
- **İlgili kurallar:** [VER-01], [VER-03]

## Bağlam

Go, "son iki major sürüm desteklenir" politikası uygular. 2026-08 itibarıyla desteklenen
hatlar **1.26** (güncel) ve **1.25**. Tüm servisler aynı sürümde olmalı ([GEN-02]).

## Seçenekler

### A) Go 1.25.12 (SEÇİLDİ)
**Güçlü:** Bir önceki hat, olgunlaşmış. Gin v1.12'nin `go 1.25.0` şartını karşılıyor.
Ekosistemin tamamı bu sürümü çoktan destekliyor.
**Zayıf:** 1.27 çıktığında (≈ Şubat 2027) destek dışına düşer — yani ~6 ay içinde
yükseltme planlanmalı.

### B) Go 1.26.5
**Güçlü:** Güncel hat; güvenlik yamalarını en uzun süre alır, yükseltme baskısı yok.
**Zayıf:** Yeni major hatlarda bazı kütüphaneler birkaç ay geriden gelir.

## Karar

**1.25.12.** Proje sahibinin tercihi; muhafazakâr ve tamamen savunulabilir. Go'nun
geriye uyumluluk garantisi sayesinde iki hat arasındaki pratik fark küçüktür.

## Kabul ettiğimiz maliyetler

- ~6 ay içinde (1.27 çıkışında) sürüm yükseltmesi zorunlu hâle gelecek. Üç aylık
  gözden geçirmede ([02](../02-TEKNOLOJI-SURUMLERI.md)) takip edilir.
- 1.26 ile gelen yenilikler kullanılamaz.

## Kararı ne değiştirir

- Go 1.27 çıktığı anda 1.25 destek dışına düşer → **o an yükseltme zorunludur**.
- Bir bağımlılık 1.26+ isterse hemen yükseltilir.
