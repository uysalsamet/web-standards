# 09 — Performans ve Maliyet

> İki ilke: **Ölçmeden optimize etme. Ölçmeden "hızlı" da deme.**
> Bu dosyadaki hedefler bağlayıcıdır; tutulmuyorsa ya kod düzeltilir ya hedef gerekçeyle
> değiştirilir — sessizce görmezden gelinmez.

---

## 1. Hedefler (SLO)

**[PERF-01] ZORUNLU — Varsayılan hedefler:**

| Ölçüt | Hedef | Neden bu |
|---|---|---|
| Basit okuma (tek kayıt) p95 | **< 100 ms** | Kullanıcı anlık algılar |
| Liste/sayfa p95 | **< 200 ms** | 200 ms'i aşan liste "yavaş" hissedilir |
| Yazma p95 | **< 300 ms** | Doğrulama + transaction payı dâhil |
| Ağır rapor/export p95 | **< 3 sn** | Üstündeyse asenkron olmalı ([ASYNC-02]) |
| Hata oranı (5xx) | **< %0,1** | 1.000 istekte 1'den fazla iç hata kabul edilmez |
| Kullanılabilirlik | **%99,9** | Ayda ~43 dk kesinti bütçesi |

**[PERF-02] ZORUNLU:** Ölçüm **p50 değil p95/p99** üzerinden yapılır. Ortalama, en kötü
deneyimi gizler; kullanıcı ortalamayı değil kendi isteğini yaşar.

**[PERF-03] ZORUNLU:** Hedefler metrikle izlenir ([OBS-10]) ve aşıldığında alarm üretir.
İzlenmeyen hedef, hedef değildir.

---

## 2. Kaynak bütçesi

**[PERF-04] ZORUNLU — Servis başına varsayılan konteyner limitleri:**

| Kaynak | Reservation (istek) | Limit | Not |
|---|---|---|---|
| RAM | 128 MB | **256 MB** | Tipik Go CRUD servisi 30–80 MB kullanır |
| CPU | 0.1 | **0.5** | |
| DB bağlantısı | — | **10** | `MaxConns` ([DB-01]) |

Ağır servisler (tile, export, görüntü işleme) kendi limitini alır ve **compose'da
gerekçesiyle** yazılır.

**[PERF-05] ZORUNLU:** Her konteynerin bellek limiti vardır.
> **Neden:** Limitsiz konteyner sızıntı durumunda host'un tüm belleğini yer ve **diğer
> tüm servisleri** öldürür. Limitli olan yalnızca kendisi ölür ve yeniden başlar.

**[PERF-06] ZORUNLU:** Go 1.19+ ile `GOMEMLIMIT` konteyner limitinin **%80'ine** ayarlanır:
```yaml
environment:
  GOMEMLIMIT: 200MiB      # limit 256 MB
  GOGC: 100
```
> **Neden:** Go GC varsayılan olarak konteyner limitini bilmez; limite dayanmadan
> toplamayı geciktirir ve OOM-kill yer. `GOMEMLIMIT` GC'yi limitten önce sıkıştırır.

**[PERF-07] ZORUNLU:** OOM-kill ve restart sayısı izlenir. "Servis kendini toparlıyor"
bir çözüm değil, gizlenmiş bir hatadır.

---

## 3. Payload ve ağ

**[PERF-08] ZORUNLU:** Yanıt gövdesi gereksiz veri taşımaz. Liste ucu, detay ucunun tüm
alanlarını döndürmek zorunda değildir.

**[PERF-09] ZORUNLU:** Aynı bilgi yanıtta **iki kez** bulunmaz.
> **Vaka:** GeoJSON yanıtlarında konum hem `geometry`'de hem `properties.latitude/longitude`
> içinde vardı. Payload şişiyordu ve iki kaynak zamanla birbirinden sapıyordu.

**[PERF-10] ZORUNLU:** Gateway'de gzip/br sıkıştırma açıktır. JSON sıkıştırmada %70–90
kazanç verir; bu en ucuz performans iyileştirmesidir.

**[PERF-11] ÖNERİLEN:** Değişmeyen kaynaklarda `ETag` / `If-None-Match` desteği ver;
304 yanıtı gövde taşımaz.

**[PERF-12] ZORUNLU:** Sayfa boyutu üst sınırı 200'dür ([API-18]). "Tümünü getir" ucu
yoktur; toplu veri gerekiyorsa export ucu asenkron çalışır.

---

## 4. Go tarafında maliyet

**[PERF-13] ZORUNLU:** Sıcak yolda (her istekte çalışan kod) allocation azaltılır:
- Uzunluğu bilinen slice/map `make([]T, 0, n)` ile ön tahsis edilir.
- String birleştirme döngüde `+` ile değil `strings.Builder` ile yapılır.
- Tekrar kullanılan büyük buffer'lar için `sync.Pool` değerlendirilir (**ölçtükten sonra**).

**[PERF-14] ZORUNLU:** Paylaşılan istemciler (HTTP, DB, Redis) **bir kez** oluşturulur ve
yeniden kullanılır. İstek başına `http.Client` yaratmak bağlantı havuzunu etkisizleştirir.

**[PERF-15] ZORUNLU:** Bilinen ölçekte döngüsel `defer` kullanma:
```go
// YANLIŞ: defer fonksiyon bitene kadar birikir, 10.000 satırda 10.000 açık kaynak
for _, f := range files { fh, _ := os.Open(f); defer fh.Close() }

// DOĞRU: kapsamı fonksiyona al
for _, f := range files {
	func() { fh, _ := os.Open(f); defer fh.Close(); process(fh) }()
}
```

**[PERF-16] ZORUNLU:** `rows.Close()` ve `defer` ile kaynak bırakma atlanmaz. `pgx`'te
`rows` kapatılmazsa bağlantı havuza dönmez ve havuz sessizce tükenir.

**[PERF-17] YASAK:** Erken optimizasyon. Okunabilirliği bozan her optimizasyon bir
**ölçüm çıktısıyla** gerekçelendirilir; gerekçe kod yorumuna yazılır:
```go
// pprof: bu döngü toplam CPU'nun %38'iydi (PR #211). Ön tahsis ile %6'ya indi.
buf := make([]byte, 0, 4096)
```

---

## 5. Profiling — nasıl ölçülür

**[PERF-18] ZORUNLU:** Yavaşlık şikâyeti **tahminle** değil profille çözülür. Sıra:

```
1. Metriklere bak      → hangi endpoint, hangi saat, ne kadar yavaş? [OBS-10]
2. Trace'e bak         → süre nerede geçiyor: DB mi, upstream mi, kendi kodumuz mu?
3. DB ise              → EXPLAIN (ANALYZE, BUFFERS), yavaş sorgu logu [DB-27]
4. Kendi kodumuz ise   → pprof (CPU + heap)
5. Düzelt, TEKRAR ÖLÇ  → iyileşmediyse değişikliği geri al
```

**[PERF-19] ÖNERİLEN:** `net/http/pprof` yalnızca **iç ağda** ve ayrı bir portta açılır,
gateway üzerinden dışarı verilmez.
> **Neden:** pprof uçları bellek içeriğini ve goroutine yığınlarını dışarı verir; ayrıca
> profil almak CPU tüketir — dışarıdan tetiklenebilir bir DoS vektörüdür.

**[PERF-20] ÖNERİLEN:** Kritik yollarda benchmark yaz ve regresyonu ölç:
```bash
go test -bench=. -benchmem -count=5 ./internal/service/...
```

**[PERF-21] ZORUNLU:** Yük testi olmadan "şu kadar isteği kaldırır" denmez. Basit bir
`k6`/`vegeta` senaryosu yeterlidir; hiç ölçmemekten kat kat iyidir.

---

## 6. Maliyet

**[PERF-22] ZORUNLU:** En ucuz iş, **yapılmayan iştir**. Sırayla:
1. İsteği hiç yapma (cache, ETag, gereksiz polling'i kaldır)
2. Daha az veri taşı (alan seçimi, sayfalama, sıkıştırma)
3. Daha az sorgu at (N+1'i kaldır, batch'le)
4. Sonra donanım büyüt

**[PERF-23] ZORUNLU:** Polling yerine event/webhook tercih edilir. 5 saniyede bir soran
100 istemci, günde 1,7 milyon boş istek üretir.

**[PERF-24] ÖNERİLEN:** Ağır ve seyrek işler (rapor, export, toplu import) asenkron
kuyruğa alınır ([11-ASENKRON-KAFKA-TEMPORAL.md](11-ASENKRON-KAFKA-TEMPORAL.md)); API
sürecini meşgul etmez ve API'nin ölçeklenmesini bu işler belirlemez.

**[PERF-25] ZORUNLU:** Log seviyesi üretimde `info`'dur. `debug` log hem disk hem CPU
hem para harcar; ihtiyaç anında env ile açılır ([OBS-03]).

**[PERF-26] ZORUNLU:** Log ve metrik saklama süresi tanımlıdır (örn. log 14 gün, metrik
90 gün). Sınırsız saklama, zamanla en büyük altyapı kalemine dönüşür.

**[PERF-27] ÖNERİLEN:** Docker imajı küçük tutulur (multi-stage + alpine, ~20 MB).
Küçük imaj = hızlı deploy, hızlı ölçekleme, düşük registry maliyeti, küçük saldırı yüzeyi.

**[PERF-28] ÖNERİLEN:** Kullanılmayanı kapat. Ölü servis, kullanılmayan index, boşta duran
replika, kimsenin bakmadığı dashboard — hepsi para. Üç ayda bir gözden geçir.

---

## 7. Ölçeklendirme

**[PERF-29] ZORUNLU:** Servisler **stateless**tir. Oturum, sayaç, geçici dosya süreç
belleğinde tutulmaz; Redis/DB/nesne deposunda tutulur.
> **Neden:** Bellekte durum tutan servis yatay ölçeklenemez — ikinci replika birincinin
> verisini görmez ve hata "bazen oluyor" şeklinde ortaya çıkar.

**[PERF-30] ZORUNLU:** Önce **dikey**, sonra **yatay** ölçekle. Tek servis 256 MB'ı
tıkıyorsa önce sızıntı/gereksiz allocation ara; replika eklemek sorunu gizler ve
maliyeti çarpar.

**[PERF-31] ZORUNLU:** Yatay ölçeklemede DB **bir kere** ölçeklenmez — 10 replika × 10
bağlantı = 100 bağlantı ([DB-03]). PgBouncer olmadan yatay ölçekleme DB'yi düşürür.

---

## 8. ASLA YAPMA — performans

- ❌ Ölçmeden optimize etmek
- ❌ Ölçmeden "hızlı/yavaş" demek
- ❌ Bellek limiti olmayan konteyner
- ❌ `GOMEMLIMIT` ayarlamadan sıkı bellek limiti vermek
- ❌ Sayfalamasız / sınırsız liste ucu
- ❌ Aynı veriyi yanıtta iki kez taşımak
- ❌ İstek başına yeni `http.Client` yaratmak
- ❌ `rows.Close()` / `defer` ile kaynak bırakmayı atlamak
- ❌ Döngü içinde biriken `defer`
- ❌ pprof'u dışarı açmak
- ❌ Üretimde `debug` log seviyesi
- ❌ Süreç belleğinde durum tutup yatay ölçeklemek
- ❌ Gerekçesiz, ölçümsüz "iyileştirme" commit'i
