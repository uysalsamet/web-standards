# 16 — Para, Kişisel Veri ve Denetim İzi

> Bu dosyadaki hataların ortak özelliği: **sessizce** olurlar ve aylar sonra fark edilir.
> Yanlış yuvarlanan kuruş, mutabakat gününe kadar görünmez. Silinmesi gereken kişisel veri,
> denetim gelene kadar sorun çıkarmaz. Eksik denetim izi, "bu kaydı kim sildi" sorusu
> sorulana kadar kimsenin dikkatini çekmez.
>
> **Hukuki uyarı:** §2'deki KVKK maddeleri **teknik uygulama kurallarıdır, hukuki
> danışmanlık değildir.** Saklama süreleri, hukuki dayanaklar ve aydınlatma metinleri
> kurumunun hukuk birimi tarafından belirlenir; buradaki kurallar o kararların **teknik
> olarak uygulanabilir** olmasını sağlar.

---

# 1. Para ve ondalık sayı

## 1.1 Temel kural

**[PARA-01] YASAK — Parayı `float32`/`float64` ile tutmak, taşımak veya hesaplamak.**

> **Neden:** IEEE-754 ikili kayan nokta, `0.1` gibi ondalık değerleri **tam olarak**
> gösteremez. Sonuçları:
> ```go
> 0.1 + 0.2 == 0.3        // false
> var t float64
> for i := 0; i < 10; i++ { t += 0.1 }
> t == 1.0                // false → 0.9999999999999999
> ```
> Gerçek etkisi: 1.245 borç kaydını toplayan bir rapor, mutabakatta birkaç kuruş
> tutmaz. Tutmayan kuruş, "hangi kayıt yanlış" sorusuna dönüşür ve cevabı yoktur —
> çünkü hiçbiri tek başına yanlış değildir, toplama sırası bile sonucu değiştirir.
> Bu hata **hiçbir uyarı üretmez**; yalnızca sayılar tutmaz.

**[PARA-02] ZORUNLU — Şemada `NUMERIC`, asla `REAL`/`DOUBLE PRECISION`/`MONEY`:**

```sql
debt_amount  NUMERIC(14,2) NOT NULL,
paid_amount  NUMERIC(14,2) NOT NULL DEFAULT 0,

-- İş kuralı şemada da durur [DB-08]: ödenen negatif olamaz ve borcu AŞAMAZ.
CONSTRAINT debts_paid_valid CHECK (paid_amount >= 0 AND paid_amount <= debt_amount)
```

> `NUMERIC` **tam** ondalık aritmetik yapar; `SUM()` sonucu kuruşuna kadar doğrudur.
> Postgres'in `MONEY` tipi kullanılmaz: para birimi ve ondalık ayarı sunucu `lc_monetary`
> ayarına bağlıdır, yani veritabanı ayarı değişince değerlerin anlamı kayar.

`NUMERIC(14,2)` = en fazla 12 basamak tam kısım + 2 kuruş. Daha büyük tutar gerekiyorsa
ölçeği artır, **ondalık basamağı değil** — kuruş sayısı iş kuralıdır, teknik detay değil.

## 1.2 Go tarafı — `Money` tipi

**[PARA-03] ZORUNLU — Go'da para `int64` kuruş olarak tutulur**, ayrı bir tiple:

```go
package money

// Money — KURUŞ cinsinden tamsayı. 1234.56 TL -> Money(123456).
// Para asla float ile taşınmaz [PARA-01]; tamsayı toplama/çıkarma tam sonuç verir.
type Money int64

const subunits = 100 // 1 TL = 100 kuruş

// DB'den METİN olarak okunur: NUMERIC -> float dönüşümü hassasiyet kaybeder.
// Sorguda kolon açıkça ::text ile seçilir [PARA-06].
func (m *Money) Scan(src any) error {
	var s string
	switch v := src.(type) {
	case nil:
		return errors.New("money: NULL değeri Money'e okunamaz, *Money kullan")
	case string:
		s = v
	case []byte:
		s = string(v)
	default:
		// float64 buraya DÜŞMEMELİ. Düşüyorsa sorgu ::text ile seçmiyordur.
		return fmt.Errorf("money: beklenmeyen tip %T (sorguda ::text kullanıldı mı?)", src)
	}
	parsed, err := Parse(s)
	if err != nil {
		return err
	}
	*m = parsed
	return nil
}

func (m Money) Value() (driver.Value, error) { return m.String(), nil }

// String — "1234.56". Negatif değerlerde işaret başta.
func (m Money) String() string {
	neg := m < 0
	v := int64(m)
	if neg {
		v = -v
	}
	s := fmt.Sprintf("%d.%02d", v/subunits, v%subunits)
	if neg {
		return "-" + s
	}
	return s
}

// JSON'a STRING olarak yazılır [PARA-04].
func (m Money) MarshalJSON() ([]byte, error) { return json.Marshal(m.String()) }

// JSON'dan yalnızca string kabul edilir. Sayı gelirse HATA — sessizce kabul edip
// float'a düşürmek, bu tipin var olma sebebini ortadan kaldırır.
func (m *Money) UnmarshalJSON(b []byte) error {
	var s string
	if err := json.Unmarshal(b, &s); err != nil {
		return errors.New(`money: tutar string olmalı, örn "1234.56"`)
	}
	parsed, err := Parse(s)
	if err != nil {
		return err
	}
	*m = parsed
	return nil
}
```

**[PARA-04] ZORUNLU — JSON'da para **string**'dir, sayı değil.**

> **Neden:** JavaScript'te `JSON.parse` tüm sayıları `float64`e çevirir — yani frontend,
> backend ne kadar dikkatli olursa olsun tutarı bozar. `{"debt": 1234.56}` gönderirsen
> tarayıcıda `1234.5600000000001` olabilir ve kullanıcı bunu ekranda görür.
> `{"debt": "1234.56"}` gönderirsen tutar aynen kalır.
>
> Frontend'e bunu **bir kez** anlatmak, her raporda kuruş aramaktan ucuzdur.

**[PARA-05] ZORUNLU:** `Money` alanı "bilinmiyor" olabiliyorsa `*Money` (pointer) kullanılır
— [GEN-20] ve [API-07] burada da geçerlidir. `0` ile "tutar girilmemiş" karışmaz.

**[PARA-06] ZORUNLU:** Para kolonları sorguda **açıkça `::text`** ile seçilir:

```sql
SELECT id, name, debt_amount::text, paid_amount::text FROM stall_debts WHERE id = $1;
```
> **Neden:** Sürücünün `NUMERIC`'i hangi Go tipine vereceğine güvenmek yerine, metin
> üzerinden okumak dönüşümü **tek ve öngörülebilir** kılar. Bir sürücü yükseltmesi
> davranışı sessizce değiştiremez.

## 1.3 Aritmetik ve yuvarlama

**[PARA-07] ZORUNLU:** Toplama ve çıkarma `Money` (tamsayı) üzerinde yapılır — sonuç tamdır.

**[PARA-08] ZORUNLU:** Çarpma ve bölme (oran, KDV, taksit) **açık yuvarlama** ile yapılır
ve yuvarlama yönü **tek yerde** tanımlanır:

```go
// KDV gibi oransal hesaplarda yuvarlama KURALI açık olmalı: burada yarımı yukarı
// (half-up) yuvarlıyoruz — Türkiye'de fatura pratiği bu yöndedir.
// Yuvarlama YÖNÜ ve ANI iş kararıdır; koda gömülü ve yorumlu olmalıdır.
func (m Money) MulRate(numerator, denominator int64) Money {
	if denominator == 0 {
		panic("money: sıfıra bölme")
	}
	v := int64(m) * numerator
	half := denominator / 2
	if v >= 0 {
		return Money((v + half) / denominator)
	}
	return Money((v - half) / denominator)
}

// %20 KDV: total.MulRate(20, 100)
```

**[PARA-09] ZORUNLU:** Taksit/paylaştırma yapılıyorsa **kalan kuruş kaybolmaz**. 100,00 TL'yi
3'e bölünce 33,33 + 33,33 + 33,33 = 99,99 eder; eksik 1 kuruş bir taksite eklenir:

```go
// Kalan kuruşlar ilk parçalara birer birer dağıtılır:
// parçaların toplamı HER ZAMAN toplama eşittir.
func Split(total Money, parts int) []Money {
	out := make([]Money, parts)
	base := int64(total) / int64(parts)
	rem := int64(total) % int64(parts)
	for i := range out {
		out[i] = Money(base)
		if int64(i) < rem {
			out[i]++
		}
	}
	return out
}
```
> **Testi zorunlu:** her tutar ve parça sayısı için `sum(Split(t,n)) == t`.
> Aşağıdaki tablo testi bu dosyayla birlikte doğrulanmıştır (35 kombinasyon):
> ```go
> for _, total := range []int64{10000, 10001, 9999, 1, 123457} {
>     for parts := 1; parts <= 7; parts++ {
>         var sum Money
>         for _, p := range Split(Money(total), parts) { sum += p }
>         if int64(sum) != total { t.Fatalf("total=%d parts=%d", total, parts) }
>     }
> }
> ```

### `Parse` — metinden Money'e

`Scan` ve `UnmarshalJSON` bunu kullanır; kopyalarken **atlama**:

```go
func Parse(s string) (Money, error) {
	s = strings.TrimSpace(s)
	neg := strings.HasPrefix(s, "-")
	s = strings.TrimPrefix(s, "-")

	parts := strings.SplitN(s, ".", 2)
	whole, err := strconv.ParseInt(parts[0], 10, 64)
	if err != nil {
		return 0, fmt.Errorf("money: geçersiz tutar %q", s)
	}
	var frac int64
	if len(parts) == 2 {
		// "5" -> "50" (5 kuruş değil 50 kuruş), "567" -> "56" (fazlası kırpılır)
		f := (parts[1] + "00")[:2]
		if frac, err = strconv.ParseInt(f, 10, 64); err != nil {
			return 0, fmt.Errorf("money: geçersiz kuruş %q", s)
		}
	}
	v := whole*subunits + frac
	if neg {
		v = -v
	}
	return Money(v), nil
}
```

> **Not:** Bu dosyadaki `Money` tipi, `Parse`, `Split` ve `MulRate` **derlenip test
> edilmiştir** (`go vet` temiz, 5 test geçiyor). Buradan kopyalanan kod çalışır durumdadır.

**[PARA-10] ZORUNLU:** Yuvarlama **son anda bir kez** yapılır. Ara sonuçları yuvarlayıp
üst üste toplamak, hatayı biriktirir.

## 1.4 Para birimi ve bütünlük

**[PARA-11] ZORUNLU:** Tek para birimi kullanılsa bile bu **açıkça** belirtilir — şema
yorumu ya da `currency CHAR(3) NOT NULL DEFAULT 'TRY'` kolonu:
```sql
-- Tüm tutarlar TRY. Çoklu para birimi ihtiyacı doğarsa currency kolonu eklenir;
-- o güne kadar varsayımı yazılı tutuyoruz ki kimse tahmin etmesin.
debt_amount NUMERIC(14,2) NOT NULL,
```
> Farklı para birimlerindeki tutarları **toplamak** en pahalı sessiz hatadır.

**[PARA-12] ZORUNLU:** Para değiştiren işlem **transaction** içindedir ([DB-22]) ve
tekrarlanamaz olması gerekiyorsa `Idempotency-Key` ile korunur ([API-25]).
> Ağ hatası sonrası istemci retry eder; korunmazsa **çift tahsilat** olur ve bunu
> müşteri fark eder, sen değil.

**[PARA-13] ZORUNLU:** Para değiştiren her işlem **denetim izi** üretir (§3).

**[PARA-14] ZORUNLU:** Bakiye gibi türetilebilir değerler ya `GENERATED` ([DB-09]) ya da
hareketlerden hesaplanır — iki yerde ayrı tutulup elle senkronlanmaz.

## 1.5 `shopspring/decimal` ne zaman?

**[PARA-15] ÖNERİLEN:** Tamsayı kuruş, toplama/çıkarma ve basit oranlar için **yeterlidir**
ve sıfır bağımlılık gerektirir. Gerçek ondalık matematik gerekiyorsa (bileşik faiz,
çok basamaklı kur çevrimi, finansal formüller) `shopspring/decimal` değerlendirilir —
ancak:
- **Bir ADR yazılması gerekir** ([02](02-TEKNOLOJI-SURUMLERI.md) §4).
- Son sürümü **v1.4.0 (Nisan 2024)** — bu, kendi [VER-07] kuralımızdaki "son sürüm
  12 aydan eskiyse terk edilmiş say" eşiğini aşıyor. Kütüphane olgun ve stabil olabilir
  ("bitmiş" olabilir), ama bu **açıkça gerekçelendirilmesi gereken bir istisnadır**.

## 1.6 Mevcut `float` kolonlarını taşıma

**[PARA-16] ZORUNLU:** Şu an `REAL`/`DOUBLE PRECISION` ile tutulan para kolonları varsa
migration ileriye uyumlu adımlarla yapılır ([DB-13]):

```sql
-- +goose Up
-- 1) Yeni kolon (nullable), 2) backfill, 3) NOT NULL, 4) eski kolonu ayrı migration'da sil.
ALTER TABLE stall_debts ADD COLUMN debt_amount_num NUMERIC(14,2);
UPDATE stall_debts SET debt_amount_num = ROUND(debt_amount::numeric, 2);
```
> **Uyarı:** `float`'tan `NUMERIC`'e dönüşüm, zaten bozulmuş değerleri **düzeltmez** —
> yalnızca bozulmayı durdurur. Taşımadan önce toplamları kaydet, sonra karşılaştır;
> fark varsa bu, hatanın ne kadar sürdüğünün ölçüsüdür.

---

# 2. Kişisel veri ve KVKK

> 6698 sayılı KVKK kapsamında **veri sorumlusu** kurumdur. Aşağıdakiler, o sorumluluğun
> teknik olarak yerine getirilebilmesi için gereken kurallardır.

## 2.1 Envanter ve minimizasyon

**[KVKK-01] ZORUNLU:** Hangi tabloda hangi kişisel veri olduğu **yazılıdır**. Şemada
etiketlenir:

```sql
CREATE TABLE stall_owners (
    id           UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    full_name    VARCHAR(255) NOT NULL,   -- KİŞİSEL VERİ
    national_id  CHAR(11),                -- KİŞİSEL VERİ · özel özen: TCKN
    phone        VARCHAR(20),             -- KİŞİSEL VERİ
    stall_id     UUID NOT NULL REFERENCES market_stalls(id),
    ...
);
COMMENT ON TABLE stall_owners IS
  'Kişisel veri içerir. Saklama süresi: sözleşme bitiminden itibaren 10 yıl (KVKK-03).';
```
> **Neden:** Silme talebi geldiğinde ya da ihlal bildirimi yapılacağında "hangi veriler
> etkilendi" sorusunun cevabı **dakikalar içinde** verilebilmelidir. Envanter yoksa
> cevap yoktur.

**[KVKK-02] ZORUNLU — Veri minimizasyonu:** İhtiyacın olmayan kişisel veriyi **toplama**.
"İleride lazım olur" gerekçesi geçersizdir ([GIS-22] ile aynı mantık). Her kişisel veri
alanı için "bu olmadan hangi iş yapılamıyor" sorusunun cevabı olmalı.

**[KVKK-03] ZORUNLU:** Her kişisel veri kategorisi için **saklama süresi** tanımlıdır ve
süre dolduğunda silme/anonimleştirme **otomatik** çalışır. Elle yapılan temizlik yapılmaz.

## 2.2 Silme ve anonimleştirme

**[KVKK-04] ZORUNLU:** İlgili kişinin silme talebi **teknik olarak uygulanabilir** olmalıdır.
Silmenin ne anlama geldiği önceden kararlaştırılır:

| Yaklaşım | Ne zaman |
|---|---|
| **Hard delete** | Kaydın tümü kişisel veri ve iş kaydı olarak tutulması gerekmiyorsa |
| **Anonimleştirme** | İstatistik/mali kayıt korunmalı ama kişi belirlenemez olmalı: ad/TCKN/telefon `NULL` ya da sabit değer, ilişki kırılır |

**[KVKK-05] ZORUNLU — Soft delete kişisel veri için silme sayılmaz.** [DB-33]'teki
`deleted_at` deseni operasyonel bir işarettir; kişisel veri **fiilen** silinmeli ya da
anonimleştirilmelidir. İkisi karıştırılırsa "sildik" denen veri yerinde durur.

**[KVKK-06] ZORUNLU:** Silme talebi **yedekleri de** kapsar. Yedekten geri dönüldüğünde
silinmiş verinin geri gelmemesi için: yedek saklama süresi tanımlı olmalı ve geri yükleme
sonrası silme listesinin yeniden uygulanması **prosedüre** yazılmalıdır.

## 2.3 Erişim, şifreleme, sızıntı

**[KVKK-07] ZORUNLU — Özel nitelikli veriler** (sağlık, biyometrik, din, ceza mahkûmiyeti,
sendika üyeliği vb.) daha sıkı korunur: ayrı yetki ([SEC-05]), şifreli saklama, ve
**her erişim denetim izine yazılır** ([AUDIT-01]).

**[KVKK-08] ZORUNLU:** Kişisel veri aktarımda (TLS) ve diskte (disk/DB şifreleme) şifrelenir.
Yedekler de şifrelenir — şifresiz yedek, en kolay sızıntı yoludur.

**[KVKK-09] ZORUNLU:** Loglarda kişisel veri bulunmaz ([SEC-25], [SEC-27]). `user_id`
(UUID) loglanır; ad, TCKN, telefon, tam e-posta loglanmaz. Log saklama süresi tanımlıdır
([PERF-26]).

**[KVKK-10] ZORUNLU — Test/geliştirme ortamına gerçek kişisel veri kopyalanmaz.**
Üretim yedeğini local'e açmak yaygın ve ciddi bir ihlaldir. Seed verisi üretilir ya da
maskelenir.
> Bu kural [GEN-09]'un ("%100 gerçek veri") **istisnasıdır** ve öyle olmalıdır: gerçek
> olması gereken belediye açık verisidir, vatandaşın kimlik bilgisi değil.

**[KVKK-11] ZORUNLU — İhlal bildirimi 72 saat.** Kişisel veriler hukuka aykırı şekilde
başkaları tarafından elde edilirse, veri sorumlusu bunu öğrendiği andan itibaren
**gecikmeksizin ve en geç 72 saat içinde** Kişisel Verileri Koruma Kurulu'na bildirir
(6698 s.K. m.12/5; Kurul'un 24.01.2019 tarih ve 2019/10 sayılı kararı). Süre **ihlalin
olduğu an değil, öğrenildiği an** başlar.

**Bunun teknik karşılığı — bildirim yapabilmek için şunlar zaten kurulu olmalı:**
- Hangi verinin etkilendiğini söyleyebilmek → **veri envanteri** ([KVKK-01])
- Kimin eriştiğini söyleyebilmek → **denetim izi** (§3)
- Ne zaman olduğunu söyleyebilmek → **log saklama süresi** yeterli olmalı
- Kaç kişinin etkilendiğini söyleyebilmek → sorgulanabilir kayıtlar

> Bu dördü olmadan 72 saat içinde söylenebilecek tek şey "bilmiyoruz"dur — ve bu,
> ihlalin kendisinden daha ağır sonuç doğurur.

**[KVKK-12] ZORUNLU:** Kişisel verinin üçüncü taraflara (harici servis, analitik, bulut,
yurt dışı) aktarıldığı her yer **yazılıdır**. Bir servise eklenen yeni bir dış çağrı,
farkında olmadan veri aktarımı yaratabilir.

---

# 3. Denetim izi (audit log)

## 3.1 Uygulama logundan farkı

| | Uygulama logu ([10](10-GOZLEMLENEBILIRLIK.md)) | Denetim izi |
|---|---|---|
| Amaç | Teşhis, operasyon | Hesap verebilirlik, hukuki kayıt |
| Okuyucu | Geliştirici | Denetçi, hukuk, yönetim |
| Saklama | 14 gün | Yıllar (mevzuata göre) |
| Değiştirilebilir mi | Evet (rotasyon) | **Hayır** |
| Nerede | stdout → toplayıcı | **Veritabanı tablosu** |

**[AUDIT-07] ZORUNLU:** İkisi karıştırılmaz. Denetim izi `slog` ile stdout'a yazılmaz —
kalıcı, sorgulanabilir ve değiştirilemez bir yerde durur.

## 3.2 Ne kaydedilir

**[AUDIT-01] ZORUNLU — Denetim izi üretmesi zorunlu işlemler:**
- **Para hareketleri** — borç oluşturma/silme, tahsilat, tutar değişikliği ([PARA-13])
- **Kişisel veri** okuma (özel nitelikliyse), değiştirme, silme, dışa aktarma
- **Yetki ve kimlik** değişiklikleri — rol atama, yetki verme/alma, kullanıcı açma/kapatma
- **Silme işlemleri** — her türlü kalıcı silme
- **Toplu işlemler** — import, export, toplu güncelleme
- **Yetki reddi** ([SEC-09]) ve başarısız giriş denemeleri
- **Yapılandırma değişiklikleri**

**[AUDIT-02] ZORUNLU — Her kayıtta bulunacaklar:**

```sql
CREATE TABLE audit_log (
    id           BIGSERIAL PRIMARY KEY,     -- append-only; sıra önemli, IDOR riski yok
    occurred_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
    actor_id     UUID,                      -- kim (NULL = sistem)
    actor_ip     INET,                      -- nereden
    request_id   TEXT,                      -- uygulama loguyla eşleştirmek için [OBS-04]
    action       TEXT NOT NULL,             -- 'stall_debt.delete', 'user.role_granted'
    entity_type  TEXT NOT NULL,             -- 'stall_debt'
    entity_id    UUID,                      -- hangi kayıt
    before       JSONB,                     -- değişen alanların ÖNCEKİ değeri
    after        JSONB,                     -- değişen alanların SONRAKİ değeri
    reason       TEXT                       -- varsa gerekçe (toplu işlem, düzeltme)
);

CREATE INDEX idx_audit_entity   ON audit_log (entity_type, entity_id, occurred_at DESC);
CREATE INDEX idx_audit_actor    ON audit_log (actor_id, occurred_at DESC);
CREATE INDEX idx_audit_occurred ON audit_log (occurred_at DESC);
```

**[AUDIT-03] ZORUNLU — Append-only.** Uygulamanın kullandığı DB kullanıcısının bu tabloda
`UPDATE` ve `DELETE` yetkisi **yoktur**:

```sql
REVOKE UPDATE, DELETE ON audit_log FROM app_user;
GRANT INSERT, SELECT ON audit_log TO app_user;
```
> **Neden:** Değiştirilebilen bir denetim izi, denetim izi değildir. Sisteme giren
> saldırganın ilk yapacağı şey izini silmektir; en azından bunu uygulama kullanıcısıyla
> yapamamalıdır.

**[AUDIT-04] ZORUNLU:** Denetim kaydı, işin kendisiyle **aynı transaction'da** yazılır:
```go
tx, _ := pool.Begin(ctx)
defer tx.Rollback(ctx)
// ... asıl iş
if err := audit.Write(ctx, tx, entry); err != nil { return err }
return tx.Commit(ctx)
```
> Ayrı yazılırsa iş başarılı olup iz yazılmayabilir — ve bu, tam olarak izin en çok
> gerektiği durumda (hata anında) olur.

**[AUDIT-05] ZORUNLU:** `before`/`after` yalnızca **değişen alanları** taşır, tüm kaydı değil.
Kişisel veri içeren alanlarda değerin kendisi yerine "değişti" bilgisi tutulabilir —
aksi hâlde denetim izi, silinmesi gereken kişisel verinin ikinci bir kopyası hâline gelir
([KVKK-04] ile çelişir). Bu ayrım tabloya göre kararlaştırılır ve yorumla yazılır.

**[AUDIT-06] ZORUNLU:** Denetim izini **okumak da bir yetkidir** (`audit.view`) ve bu
yetkiye sahip olmak, ilgili kayıtlara erişim demektir — dikkatli dağıtılır. Denetim izini
okuma işlemi de loglanır.

**[AUDIT-08] ZORUNLU:** Silinen kaydın izi kalır. Bir kayıt kalıcı olarak silindiğinde
denetim izinde `entity_id` ve `before` bilgisi durur — "böyle bir kayıt hiç var olmadı"
durumu oluşmaz.

**[AUDIT-09] ZORUNLU:** Saklama süresi tanımlıdır ve mevzuattan gelir (mali kayıtlar için
tipik olarak 10 yıl). Denetim izi [PERF-26]'daki genel log saklama süresine **tabi değildir**.

---

## 4. ASLA YAPMA

**Para**
- ❌ `float32`/`float64` ile para tutmak, taşımak, hesaplamak
- ❌ Şemada `REAL`/`DOUBLE PRECISION`/`MONEY` kullanmak
- ❌ JSON'da parayı **sayı** olarak göndermek
- ❌ Ara sonuçları yuvarlayıp üst üste toplamak
- ❌ Yuvarlama yönünü yazmadan bırakmak
- ❌ Taksit bölerken kalan kuruşu kaybetmek
- ❌ Farklı para birimindeki tutarları toplamak
- ❌ Para işlemini transaction dışında yapmak
- ❌ Para işlemini idempotency korumasız `POST` ile açmak

**Kişisel veri**
- ❌ Kişisel veri envanteri tutmamak
- ❌ Saklama süresi tanımsız kişisel veri
- ❌ Soft delete'i kişisel veri silme sayması
- ❌ Üretim verisini test/geliştirme ortamına kopyalamak
- ❌ Şifresiz yedek
- ❌ Loglarda ad/TCKN/telefon/e-posta
- ❌ Dış servise veri aktarımını kayıt altına almamak
- ❌ 72 saatlik bildirimi karşılayacak envanter/iz olmadan üretime çıkmak

**Denetim izi**
- ❌ Denetim izini uygulama logu ile karıştırmak
- ❌ `UPDATE`/`DELETE` yetkisi olan audit tablosu
- ❌ Denetim kaydını işten ayrı transaction'da yazmak
- ❌ Para/yetki/silme işlemini izsiz bırakmak
- ❌ Denetim izine tüm kaydı (kişisel veri dâhil) kopyalamak
- ❌ Denetim izini okumayı yetkisiz bırakmak
