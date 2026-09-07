# AGENTS.md

> Bu dosya, projede çalışan **tüm AI kodlama ajanları** için bağlayıcı talimattır.
> Cursor, Claude Code, Antigravity, Copilot, Windsurf, Zed, Codex ve diğerleri bunu
> doğrudan okur. Araca özel dosyalar (`CLAUDE.md`, `.cursor/rules/`, `GEMINI.md`)
> bu dosyaya **işaret eder**; kural tek yerde yaşar.

## Backend standardı — BAĞLAYICI

Bu projede `backend-standartlari/` altındaki standart geçerlidir. Tercih değil,
**sözleşmedir**: uyulmadan kod merge edilmez.

**Stack (tartışmaya kapalı):** Go 1.25.12 · Gin v1.12.0 · pgx/v5 · Valkey · goose ·
`log/slog` · Prometheus + OpenTelemetry.
Her seçimin gerekçesi ve elenen alternatifler `backend-standartlari/adr/` altındadır.

---

## Kod yazmadan önce — ZORUNLU sıra

1. **`backend-standartlari/01-ALTIN-KURALLAR.md`** — 24 madde, her görevde okunur.
2. **`backend-standartlari/KURAL-HARITASI.md` §1 — sinyal taraması.**
   Yazacağın kodda geçen her sinyal bir kural tetikler. Örnekler:
   `float64` + tutar · `ORDER BY` + `LIMIT` · `PUT` handler · `http.Client{}` ·
   kullanıcıdan gelen URL · `DELETE` ucu · `strings.ToLower` · cron/`time.Ticker` ·
   dosya yükleme · ad/TCKN/telefon kolonu · `go func(...)` · yeni tablo.
   **Tetiklenen kuralı dosyadan OKU** — hafızandan hatırladığını sandığınla yazma.
3. **Göreve karşılık gelen dosya** — `KURAL-HARITASI.md` §2'deki okuma listesinden.

Tüm dosyaları birden okuma: context israfıdır ve alakasız kurallar kararı bulandırır.

---

## Çalışırken

- **Sürüm ve bağımlılık:** `backend-standartlari/02-TEKNOLOJI-SURUMLERI.md` tablosundan.
  Tabloda olmayan bir paketi **ekleme — kullanıcıya sor.**
- **"Neden X kullanıyoruz, Y daha iyi değil mi?"** sorusuna cevap vermeden önce
  `backend-standartlari/adr/` altındaki ilgili karar kaydını oku. Karar zaten verilmiş
  ve gerekçelendirilmiştir; "Kararı ne değiştirir" bölümündeki koşul gerçekleşmediyse
  kararı yeniden açma.
- **Standart ile mevcut kod çelişiyorsa:** standart kazanır — ama **çalışan koda dokunma.**
  Yeni kodu standarda göre yaz, çelişkiyi kullanıcıya bildir.
- **Eski framework'le yazılmış servisler görsen bile yeni servisi Gin ile yaz**
  ([VER-17]). Komşu servisten kopyalama; `03-PROJE-YAPISI.md` §4'teki iskeletten başla.
- **`KURAL-HARITASI.md` §4'teki bilinen boşluklardan** birine giriyorsan: kullanıcıyı
  **uyar**, kendi kararını gerekçesiyle koda yaz.

---

## Bitirmeden önce — ZORUNLU

```bash
bash backend-standartlari/arac/standart-kontrol.sh .   # çıkış kodu 0 olmalı
golangci-lint run                                       # temiz olmalı
```

Sonra `backend-standartlari/15-YENI-SERVIS-CHECKLIST.md` madde madde geçilir.
Atlanan madde **açıkça söylenir**, sessizce geçilmez.

> **Otomatik denetimin temiz geçmesi "standarda uygun" demek DEĞİLDİR.**
> Araçlar 590 kuralın ~%9'unu görür ([ARAC-04]). Kalanı senin sorumluluğunda.

---

## Asla

- ❌ Test yazmadan "çalışıyor" demek
- ❌ Onaysız bağımlılık eklemek
- ❌ "Bu küçük bir değişiklik, standarda bakmaya gerek yok" demek —
  standardın delindiği yer **hep** küçük değişikliktir
- ❌ Doğrulamadan "tamamlandı" demek

---

## Git

Bu projede AI, git'te **yalnızca salt-okunur** komut çalıştırır
(`status`, `diff`, `log`, `show`, `branch`, `blame`).
`commit`, `push`, `reset`, `checkout`, `stash`, branch/tag oluşturma-silme **yasaktır** —
bunları kullanıcı kendi yapar.
