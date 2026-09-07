# 10 — Gözlemlenebilirlik

> Üç ayak: **log** (ne oldu), **metrik** (ne kadar/ne sıklıkta), **trace** (nerede geçti).
> Üçü de yoksa üretimdeki bir sorunu tahminle çözmeye çalışırsın; tahmin, çözüm değildir.

---

## 1. Loglama

**[OBS-01] ZORUNLU:** Log `log/slog` ile **yapısal (JSON)** yazılır. `fmt.Println`,
`log.Printf` ve serbest metin log yasaktır.
> **Neden:** Düz metin log aranabilir değildir. "Şu kullanıcının dünkü 500'lerini göster"
> sorusu ancak alanlara sahip logda cevaplanır.

```go
package pkg

var Log *slog.Logger

func InitLogger(level, service, version string) *slog.Logger {
	var lv slog.Level
	if err := lv.UnmarshalText([]byte(level)); err != nil {
		lv = slog.LevelInfo
	}
	h := slog.NewJSONHandler(os.Stdout, &slog.HandlerOptions{
		Level: lv,
		// Kaynak konumu yalnızca debug'da: her satırda dosya/satır hesaplamak maliyetli.
		AddSource: lv == slog.LevelDebug,
	})
	Log = slog.New(h).With(
		slog.String("service", service),
		slog.String("version", version),
	)
	slog.SetDefault(Log)
	return Log
}
```

**[OBS-02] ZORUNLU:** Log **stdout**'a yazılır, dosyaya değil. Toplama işi konteyner
runtime'ının ve log toplayıcının işidir.
> **Neden:** Dosyaya yazan konteyner diski doldurur, rotasyon sorunu üretir ve konteyner
> öldüğünde loglar da ölür.

**[OBS-03] ZORUNLU:** Seviye env ile ayarlanır (`LOG_LEVEL`), üretimde **`info`**'dur.

| Seviye | Ne zaman |
|---|---|
| `Debug` | Geliştirme/teşhis. Üretimde kapalı, gerektiğinde açılır |
| `Info` | Normal iş olayları: servis açıldı, iş tamamlandı |
| `Warn` | Beklenmedik ama ele alınmış durum: cache okunamadı, retry yapıldı |
| `Error` | İş başarısız oldu, müdahale gerekebilir |

> **`Fatal` yoktur.** Kapanış kararı `main`'e aittir; kütüphane/handler süreci öldürmez.

**[OBS-04] ZORUNLU:** Her log satırında bulunması gerekenler:

| Alan | Neden |
|---|---|
| `time`, `level`, `msg` | slog otomatik ekler |
| `service`, `version` | Hangi servisin hangi sürümü |
| `request_id` | Aynı isteğin tüm satırlarını birleştirir |
| `user_id` (varsa) | Kullanıcı bazlı teşhis |
| `err` (hata ise) | Hatanın **tam** hâli |

```go
// Her istekte request id üretilir/taşınır ve context'e konur.
import "github.com/gin-contrib/requestid"

r.Use(requestid.New())

// Handler'da:
log := pkg.Log.With("request_id", requestid.Get(c))
log.Info("otopark güncellendi", "parking_id", id)
```

**[OBS-05] ZORUNLU:** Gelen `X-Request-ID` header'ı varsa **korunur**, yoksa üretilir ve
yanıtta geri döner. Üst sistemin id'sini ezmek, iki sistemin logunu birbirine bağlanamaz hâle getirir.

**[OBS-06] ZORUNLU:** Log mesajı **sabit**, değişkenler **alan**dır:
```go
// YANLIŞ: her mesaj benzersiz, gruplanamaz, alarm kurulamaz
Log.Error(fmt.Sprintf("kullanıcı %s için sorgu başarısız: %v", id, err))
// DOĞRU
Log.Error("kullanıcı sorgusu başarısız", "user_id", id, "err", err)
```

**[OBS-07] ZORUNLU:** Loglama kuralları güvenlik bölümüne tabidir: şifre, token, kişisel
veri loglanmaz ([SEC-25]); config `%+v` ile basılmaz ([SEC-26]); hata logu tam, hata
yanıtı maskeli olur ([SEC-28]).

**[OBS-08] ZORUNLU:** Erişim logu (her istek için bir satır) gateway'de üretilir; her
serviste ayrıca üretilmez.
> **Neden:** Aynı istek 2–3 kez loglanır, disk ve maliyet katlanır, sayımlar bozulur.

---

## 2. Metrikler

**[OBS-09] ZORUNLU:** Her servis `/metrics` ucunda Prometheus formatında metrik verir.
Bu uç **dışarı açılmaz**, yalnızca iç ağdan erişilir.

**[OBS-10] ZORUNLU — Her serviste bulunacak metrikler (RED):**

| Metrik | Tip | Etiketler |
|---|---|---|
| `http_requests_total` | counter | `method`, `route`, `status` |
| `http_request_duration_seconds` | histogram | `method`, `route` |
| `http_requests_in_flight` | gauge | — |
| `db_query_duration_seconds` | histogram | `operation` |
| `db_pool_connections` | gauge | `state` (idle/used) |
| `cache_operations_total` | counter | `result` (hit/miss/error) |

**[OBS-11] ZORUNLU:** Etiket değerleri **sınırlı kümedendir**. `route` etiketi **route
şablonu**dur (`/parkings/:id`), gerçek yol değil.
> **Neden:** Her UUID ayrı bir zaman serisi yaratır. 100.000 kayıt = 100.000 seri =
> Prometheus'un çökmesi. Buna "cardinality explosion" denir ve geri dönüşü zordur.
> Aynı sebeple `user_id`, `email`, `ip` **asla** etiket olmaz — bunlar **log** alanıdır.

**[OBS-12] ZORUNLU:** İş metrikleri de tanımlanır: `orders_created_total`,
`import_records_failed_total` gibi. Teknik metrikler "sistem ayakta mı" der, iş metrikleri
"sistem doğru iş yapıyor mu" der. İkincisi olmadan sessiz bozulmalar fark edilmez.

**[OBS-13] ZORUNLU:** Yetki reddi ([SEC-09]), rate limit tetiklenmesi ve retry sayısı
metriktir. Ani artışları alarm üretir.

---

## 3. Trace

**[OBS-14] ÖNERİLEN:** Üç veya daha fazla servisin zincirlendiği akışlarda OpenTelemetry
ile dağıtık trace kurulur.
> **Neden:** "İstek 4 saniye sürdü" bilgisi tek başına işe yaramaz. Trace, sürenin
> hangi serviste ve hangi çağrıda geçtiğini gösterir; onsuz her ekip diğerini suçlar.

**[OBS-15] ZORUNLU:** Trace bağlamı (`traceparent`) servisler arasında **taşınır**.
Gateway başlatır, her servis alır ve upstream çağrılarına ekler. Zincirin bir halkası
taşımazsa trace orada kopar.

**[OBS-16] ZORUNLU:** `request_id` ile `trace_id` **birbirine bağlanır** — log satırında
ikisi de bulunur. Böylece trace'ten log'a, log'dan trace'e geçilebilir.

**[OBS-17] ÖNERİLEN:** Üretimde örnekleme (sampling) kullanılır (%1–10), ancak **hatalı
istekler her zaman** örneklenir. En çok ihtiyaç duyulan trace, hata verendir.

---

## 4. Sağlık ve hazırlık

**[OBS-18] ZORUNLU:** `/health` ve `/ready` uçları [06-RATE-LIMIT-DAYANIKLILIK.md](06-RATE-LIMIT-DAYANIKLILIK.md)
§7'deki sözleşmeye uyar. `/health` bağımlılık kontrol etmez ([RES-29]).

**[OBS-19] ÖNERİLEN:** `/version` ucu build bilgisini döner: commit sha, build zamanı,
Go sürümü. "Üretimde hangi kod koşuyor" sorusunu tahminsiz cevaplar.

---

## 5. Alarmlar

**[OBS-20] ZORUNLU:** Alarm **belirti** üzerine kurulur (kullanıcı ne yaşıyor), neden
üzerine değil. "CPU %90" alarmı gece uyandırır ama kullanıcı etkilenmemiş olabilir.

**[OBS-21] ZORUNLU — Varsayılan alarm eşikleri:**

| Alarm | Eşik | Süre | Aciliyet |
|---|---|---|---|
| 5xx oranı | > %1 | 5 dk | Acil |
| p95 gecikme | > 2 × hedef | 10 dk | Acil |
| `/ready` başarısız | herhangi bir replika | 2 dk | Acil |
| DB havuzu doluluk | > %80 | 10 dk | Uyarı |
| OOM-kill / restart | > 2 kez | 15 dk | Uyarı |
| Kuyruk derinliği | artan trend | 15 dk | Uyarı |
| Disk doluluk | > %80 | — | Uyarı |
| Cache hit rate | < %50 | 30 dk | Bilgi |
| Sertifika bitişi | < 14 gün | — | Uyarı |

**[OBS-22] ZORUNLU:** Her alarmın bir **sahibi** ve bir **runbook**'u vardır: alarm
çaldığında ilk üç adım nedir? Runbook'suz alarm, gece 3'te panik demektir.

**[OBS-23] ZORUNLU:** Yanlış alarm (false positive) düzeltilir ya da silinir.
> **Neden:** Sürekli çalan alarm görmezden gelinmeye başlanır ve gerçek alarm da o gün
> görmezden gelinir. Gürültülü alarm, alarmsızlıktan tehlikelidir.

---

## 6. Ne loglanır, ne loglanmaz

**Loglanır:**
- Servis açılış/kapanış, sürüm, hangi config profili
- İş olayları: kayıt oluşturuldu/güncellendi/silindi (id ile)
- Tüm `Error` ve `Warn` durumları, tam hata zinciriyle (`%w` ile sarılmış)
- Yetki reddi, rate limit, doğrulama reddi (sebebiyle)
- Dış sistem çağrıları: hedef, süre, sonuç kodu

**Loglanmaz:**
- Sır, token, şifre, kişisel veri ([SEC-25])
- Her istek için ayrı ayrı servis logu (gateway zaten yazıyor — [OBS-08])
- Başarılı `GET` gövdeleri
- Döngü içinde satır satır ilerleme (bunun yerine sayaç metriği)
- "buraya geldi", "burada" gibi geliştirme artığı satırlar

---

## 7. ASLA YAPMA — gözlemlenebilirlik

- ❌ `fmt.Println` / `log.Printf` ile loglamak
- ❌ Düz metin (yapısal olmayan) log
- ❌ Dosyaya log yazmak
- ❌ Mesajın içine değişken gömmek (gruplanamaz)
- ❌ `user_id` / `email` / `ip` / UUID'yi metrik **etiketi** yapmak
- ❌ Gerçek yolu (`/parkings/9f3c...`) route etiketi yapmak
- ❌ Sır veya kişisel veri loglamak
- ❌ Trace bağlamını upstream'e taşımamak
- ❌ Runbook'suz alarm kurmak
- ❌ Sürekli çalan yanlış alarmı görmezden gelmek
- ❌ `/metrics` ve `/debug/pprof` uçlarını dışarı açmak
- ❌ İş metriği olmadan "sistem sağlıklı" demek
