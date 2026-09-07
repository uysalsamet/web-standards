# Başlangıç — Bu standardı bir projeye nasıl bağlarsın

> Üç adım. Beşinci dakikada çalışır durumda olur.

---

## Adım 1 — Klasörü projeye kopyala

```
<proje-kökü>/
├── backend-standartlari/     ← bu klasörün tamamı buraya
├── services/
├── deployments/
└── AGENTS.md                 ← Adım 2 (sablon/ içinden gelir)
```

`arac/golangci.yml`'i de her servisin köküne `.golangci.yml` olarak kopyala.

---

## Adım 2 — `sablon/` içindekileri proje köküne kopyala

**Tek kaynak `AGENTS.md`'dir.** Aralık 2025'ten beri Linux Foundation'ın Agentic AI
Foundation'ı altında ortak standart; 28+ araç ve 60.000+ repo kullanıyor. Araca özel
dosyalar ona **işaret eder**, içerik tekrarlanmaz — kural tek yerde yaşar, tek yerde
güncellenir.

```bash
cp -r backend-standartlari/sablon/. .
```

| Dosya | Hangi araç okur |
|---|---|
| **`AGENTS.md`** | **Ortak kaynak.** Cursor · Antigravity · Copilot · Windsurf · Zed · Aider · Codex · VS Code · JetBrains Junie · Claude Code |
| `CLAUDE.md` | Claude Code (AGENTS.md'yi de okur; bu onun zengin yerel formatı) |
| `GEMINI.md` | Google Antigravity (hiyerarşide AGENTS.md'den önce gelir) |
| `.cursor/rules/backend-standardi.mdc` | Cursor |
| `.github/copilot-instructions.md` | GitHub Copilot |
| `.windsurfrules` | Windsurf |

Kullanmadığın araçların dosyalarını silebilirsin; `AGENTS.md` kalsın.

> **Cursor uyarısı:** Eski `.cursorrules` dosyası **Agent modunda sessizce yok sayılıyor.**
> Bu yüzden şablonda `.cursor/rules/*.mdc` biçimi var — `alwaysApply: true` ile her
> istekte yükleniyor. Kuralların çalışmıyorsa ilk buraya bak.

> **Neden içerik tek dosyada:** Aynı kuralı 6 dosyaya kopyalarsan, biri güncellenip
> diğerleri kalır ve hangisinin doğru olduğu belirsizleşir. Bu, standardın kendi
> [DB-11] (denormalizasyon) kuralının aynısıdır.

## Adım 3 — Sohbete tek satırlık giriş (dosya koyamadığın durumda)

Dosya koyamadığın durumlarda (hızlı bir soru, desteklemeyen bir araç) bunu yapıştır:

```
Bu projede backend-standartlari/ altındaki standart bağlayıcıdır.
Go 1.25.12 + Gin v1.12 + pgx/v5 tek stack.

Kod yazmadan önce: 01-ALTIN-KURALLAR.md'yi ve KURAL-HARITASI.md §1 sinyal tablosunu
oku — yazacağın kodda geçen her sinyal bir kural tetikler, o kuralı dosyadan oku.
Sürüm/bağımlılık seçimi 02-TEKNOLOJI-SURUMLERI.md'den; tabloda olmayan paketi
eklemeden önce bana sor. "Neden X?" sorularının cevabı adr/ altında.

Bitirmeden önce: arac/standart-kontrol.sh çalıştır (exit 0 olmalı) ve
15-YENI-SERVIS-CHECKLIST.md'yi madde madde geç. Atladığın maddeyi açıkça söyle.
```

---

## Göreve özel açılışlar

Daha dar bir iş için ilk mesaja bunu ekle — AI hangi dosyaları okuyacağını bilir:

| Ne yapacaksan | Ekleyeceğin cümle |
|---|---|
| Yeni servis | `Yeni servis açıyorum. 02, 03, 13 ve 15'i oku, iskeleti 03 §4'teki main.go'dan başlat.` |
| Endpoint | `Endpoint ekliyorum. 04 ve 05'i oku, KURAL-HARITASI §1.3'ü tara.` |
| Para/borç/ödeme | `Para işi var. 16 §1 ZORUNLU — float ile para yasak, Money tipi kullanılacak.` |
| Türkçe arama/sıralama | `Türkçe metin araması var. 18 §2 ZORUNLU — ı/İ sorunu.` |
| Dosya yükleme | `Dosya yükleme var. 17 ZORUNLU.` |
| Kimlik/parola | `Auth servisi. 19 ZORUNLU.` |
| Veri aktarımı/cron | `Toplu içe aktarma var. 20 §1-2 ZORUNLU.` |
| Yavaşlık | `Performans sorunu. 09 §5'teki sırayı izle: metrik → trace → EXPLAIN → pprof.` |
| Şema değişikliği | `Şema değiştiriyorum. 07'yi oku, migration goose ile ve ileriye uyumlu olacak.` |

---

## Mevcut (legacy) repoda kullanım

Fiber v2 gibi eski bir framework'le yazılmış bir repoda:

- **Dokümanların tamamı geçerlidir** — API sözleşmesi, güvenlik, veritabanı, test,
  gözlemlenebilirlik. Sadece HTTP katmanı sözdizimi farklıdır ([VER-20]).
- **Yeni servisler Gin ile yazılır** ([VER-17]), mevcutlara dokunulmaz ([VER-18]).
- **`arac/standart-kontrol.sh` şimdilik bilgi amaçlı çalıştırılır**, CI'ı kırmasın:
  eski framework/bağımlılık bulguları (VER-01, VER-05, OBS-01) beklenen sonuçtur.
  Muafiyet mekanizması eklenene kadar çıktıyı elle süz:
  ```bash
  bash backend-standartlari/arac/standart-kontrol.sh services/x-service \
    | grep -vE 'VER-01|VER-05|OBS-01'
  ```

`AGENTS.md`'ye şu satırı da ekle:
```
Bu repo <framework> ile yazılmıştır (legacy). Yeni servisler Gin ile açılır [VER-17];
mevcut servislere standarda uydurmak için dokunulmaz [VER-18].
```

---

## Kontrol: doğru bağlandı mı?

İlk oturumda AI'a şunu sor:

> "backend-standartlari'na göre bu projede para alanını nasıl tutmam gerekiyor ve neden?"

**Doğru cevap:** şemada `NUMERIC(14,2)`, Go'da `Money` (int64 kuruş), JSON'da **string** —
ve gerekçesi `0.1 + 0.2 != 0.3`, [PARA-01]…[PARA-04].

Bu cevabı veremiyorsa standart okunmuyordur. Sırayla kontrol et:
`AGENTS.md` proje **kökünde** mi · `backend-standartlari/` klasör adı doğru mu ·
Cursor kullanıyorsan `.cursor/rules/*.mdc` var mı (`.cursorrules` Agent modunda çalışmaz).
