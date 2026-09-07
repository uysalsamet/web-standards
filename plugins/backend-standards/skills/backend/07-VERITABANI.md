# 07 — Veritabanı

> Postgres + `pgx/v5`. Migration `goose` ile versiyonlanır. Sorgu elle yazılır, ORM yok
> ([VER-06]). Kod örnekleri `pgxpool` kullanır.

---

## 1. Bağlantı ve havuz

```go
package postgres

func NewPool(ctx context.Context, cfg *config.Config) (*pgxpool.Pool, error) {
	pc, err := pgxpool.ParseConfig(cfg.DSN())   // DSN tek kaynak [YAP-12]
	if err != nil {
		return nil, fmt.Errorf("dsn ayrıştırılamadı: %w", err)
	}

	pc.MaxConns = cfg.DBMaxConns                 // varsayılan 10
	pc.MinConns = 2                              // ilk isteğin bağlantı kurmasını beklememesi için
	// NAT/pgbouncer arkasında bağlantı sessizce ölür; süreli yenile.
	pc.MaxConnLifetime = 30 * time.Minute
	pc.MaxConnIdleTime = 5 * time.Minute
	pc.HealthCheckPeriod = 1 * time.Minute

	pool, err := pgxpool.NewWithConfig(ctx, pc)
	if err != nil {
		return nil, fmt.Errorf("havuz oluşturulamadı: %w", err)
	}
	// Ping ZORUNLU: pgxpool.New tembeldir, yanlış şifreyle bile hata vermeden döner
	// ve sorun ilk istekte, üretimde ortaya çıkar.
	if err := pool.Ping(ctx); err != nil {
		pool.Close()
		return nil, fmt.Errorf("veritabanına ulaşılamıyor: %w", err)
	}
	return pool, nil
}
```

**[DB-01] ZORUNLU:** Havuz ayarları açıkça verilir; varsayılana bırakılmaz.

**[DB-02] ZORUNLU:** `Ping` başarısızsa servis ayağa kalkmaz.

**[DB-03] ZORUNLU — Havuz bütçesi:** `servis sayısı × MaxConns × replika < Postgres max_connections`.
> Postgres varsayılanı **100**'dür. 30 servis × 10 bağlantı = 300 → Postgres bağlantı
> reddeder ve hata "veritabanı çöktü" gibi görünür. Çok servisli kurulumda **PgBouncer
> zorunludur** (transaction pooling modu).

**[DB-04] ZORUNLU:** PgBouncer transaction pooling kullanılıyorsa prepared statement
önbelleği kapatılır: `pc.ConnConfig.DefaultQueryExecMode = pgx.QueryExecModeSimpleProtocol`
ya da PgBouncer'da `max_prepared_statements` ayarlanır. Aksi hâlde rastgele
"prepared statement does not exist" hataları alınır.

---

## 2. Şema kuralları

```sql
-- +goose Up
CREATE TABLE IF NOT EXISTS parkings (
    id            UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    original_id   INT UNIQUE,                     -- kaynak veri no, yalnızca izlenebilirlik
    name          VARCHAR(255) NOT NULL,
    neighborhood  VARCHAR(100),
    -- NULL = bilinmiyor. DEFAULT KONMAZ: kaynakta gerçek 0 değerleri de var,
    -- ikisi karışırsa "kapasitesi 0 olan otopark" ile "kapasitesi bilinmeyen" ayrılamaz.
    floor_count   INT,
    total_capacity    INT NOT NULL,
    occupied_capacity INT NOT NULL DEFAULT 0,
    -- TÜRETİLMİŞ: istemci yazamaz, kaynaklar değişince otomatik güncellenir.
    empty_capacity INT GENERATED ALWAYS AS (total_capacity - occupied_capacity) STORED,
    created_at    TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at    TIMESTAMPTZ NOT NULL DEFAULT now(),

    -- İş kuralı şemada da durur: uygulama kontrolü atlanabilir, bu atlanamaz.
    CONSTRAINT parkings_capacity_valid
        CHECK (total_capacity >= 0 AND occupied_capacity BETWEEN 0 AND total_capacity)
);

CREATE INDEX IF NOT EXISTS idx_parkings_neighborhood ON parkings (neighborhood);
CREATE INDEX IF NOT EXISTS idx_parkings_created_id   ON parkings (created_at DESC, id ASC);

-- +goose Down
DROP TABLE IF EXISTS parkings;
```

**[DB-05] ZORUNLU:** PK her zaman `UUID DEFAULT gen_random_uuid()`. Ardışık int PK yasaktır
([API-02] — IDOR).

**[DB-06] ZORUNLU:** Her tabloda `created_at` ve `updated_at`, tipi **`TIMESTAMPTZ`**.
`TIMESTAMP` (tz'siz) kullanılmaz — sunucu saat dilimi değiştiğinde veri sessizce kayar.

**[DB-07] ZORUNLU:** Zorunlu ilişkide FK **`NOT NULL`**.
> **Vaka:** `stall_debts.stall_id` nullable olduğu için hiçbir tezgaha bağlı olmayan borç
> kayıtları oluşabiliyordu; hangi esnafa ait olduğu belirsizdi ve raporlarda boşta kalıyordu.
> Uygulama katmanında zorunlu kılmak yetmez — doğrudan SQL ile bozulabilir.

**[DB-08] ZORUNLU:** İş kuralı `CHECK`/`UNIQUE`/`NOT NULL` ile de yazılır ([GEN-22]).

**[DB-09] ZORUNLU:** Türetilebilen değer `GENERATED ALWAYS AS ... STORED` olur ya da
sunucuda hesaplanır; **istemciden alınmaz** ([API-08]).

**[DB-10] ZORUNLU:** Kararlar yorumla gerekçelendirilir: neden DEFAULT yok, neden NULL
serbest, neden UNIQUE. Şema, en uzun ömürlü belgedir.

### Denormalizasyon

**[DB-11] ÖNERİLEN:** Aynı bilgiyi iki tabloda tutma. Tutuyorsan kopyanın **yazılabilir
olmadığından** emin ol — kaynaktan türet:

```sql
-- Kopya alanlar istemciden ALINMAZ, kaynaktan türetilir.
-- Tezgah yoksa 0 satır eklenir -> handler 404 döner.
INSERT INTO stall_debts (stall_id, market_place_id, market_name, debt_amount)
SELECT s.id, s.market_place_id, s.market_name, $2
FROM market_stalls s WHERE s.id = $1;
```
> **Vaka:** `market_place_id` ve `market_name` hem borçta hem tezgahta vardı ve istemci
> ikisini farklı gönderebiliyordu — borç kaydı "A pazarındaki tezgaha bağlı" deyip
> "B pazar yeri" yazabiliyordu. Hangisinin doğru olduğu belirsizdi.

---

## 3. Migration

**[DB-12] ZORUNLU:** Migration `goose` ile yapılır, versiyonlanır ve **`Down` bloğu içerir**.
Glob ile `*.sql` çalıştıran el yapımı migration kullanılmaz.
> **Neden:** `CREATE TABLE IF NOT EXISTS` tabanlı glob yaklaşımı mevcut tabloya kolon
> ekleyemez ve geri alınamaz. İlk şema değişikliğinde elle müdahale gerekir.

```
internal/repository/postgres/migrations/
├── 00001_create_parkings.sql
├── 00002_add_parkings_operator_column.sql
└── 00003_backfill_operator.sql
```

**[DB-13] ZORUNLU:** Migration **ileriye uyumlu** yazılır. Kolon silme/yeniden adlandırma
tek adımda yapılmaz:
```
1. Yeni kolonu ekle (nullable)          → eski kod çalışmaya devam eder
2. Kodu iki kolonu da yazacak hâle getir, deploy et
3. Eski veriyi taşı (backfill)
4. Kodu yalnızca yeni kolonu kullanacak hâle getir, deploy et
5. Eski kolonu sil
```
> **Neden:** Rolling deploy sırasında eski ve yeni kod **aynı anda** çalışır. Tek adımda
> kolon silen migration, eski replikaları anında bozar.

**[DB-14] ZORUNLU:** Uzun süren migration'lar üretimde tabloyu kilitlemez:
- Index `CREATE INDEX CONCURRENTLY` ile eklenir (transaction dışında — goose'da
  `-- +goose NO TRANSACTION`).
- `NOT NULL` kolon eklenirken önce nullable ekle + backfill + sonra `SET NOT NULL`.
- Büyük backfill **parti parti** yapılır, tek `UPDATE` ile değil.

**[DB-15] ZORUNLU:** Migration servis açılışında koşar ve **hatası fatal**dir. Seed/örnek
veri yüklemesi ayrıdır ve **idempotent**tir; hatası uyarıdır.

**[DB-16] ZORUNLU:** Migration ve seed **aynı sonucu** üretmelidir. İki kurulum yolu
(sıfırdan seed vs. mevcut DB'ye migrate) farklı veri üretirse aynı sürüm iki farklı
sistem demektir.

---

## 4. Sorgu yazımı

```go
// Kolon listesi TEK yerde: SELECT / INSERT RETURNING / UPDATE RETURNING aynısını kullanır.
// Böylece kolon eklendiğinde üçü birden güncellenir, biri unutulmaz.
const parkingColumns = `
	id, original_id, name,
	COALESCE(neighborhood, '') AS neighborhood,
	floor_count,
	total_capacity, occupied_capacity, empty_capacity,
	created_at, updated_at`

func (r *parkingRepository) GetByID(ctx context.Context, id string) (*dto.Parking, error) {
	row := r.pool.QueryRow(ctx,
		`SELECT `+parkingColumns+` FROM parkings WHERE id = $1`, id)

	p, err := scanParking(row)
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return nil, ErrNotFound
		}
		pkg.Log.Error("parking okunamadı", "id", id, "err", err)
		return nil, fmt.Errorf("%w: kayıt okunamadı", ErrInternal)
	}
	return &p, nil
}
```

**[DB-17] ZORUNLU:** Nullable metin kolonları `COALESCE`'lanır — yoksa `string`'e scan
patlar. **Bilinçli olarak COALESCE'lanmayanlar**, `NULL`'ın "bilinmiyor" demek olduğu
alanlardır ve bu yoruma yazılır.

**[DB-18] ZORUNLU:** `SELECT *` kullanılmaz. Kolon eklendiğinde scan sırası kayar ve hata
çalışma anında çıkar.

**[DB-19] ZORUNLU:** Sayfalı sorguda `ORDER BY` **benzersiz tie-break** içerir ([API-27]):
```sql
-- YANLIŞ: seed tüm satırları aynı anda yazdıysa created_at eşittir, sıra kararsızdır.
ORDER BY created_at DESC
-- DOĞRU
ORDER BY created_at DESC, id ASC
```
`NULL` olabilen kolona göre sıralıyorsan `NULLS LAST` ekle.

### Kısmi güncelleme

```sql
UPDATE parkings SET
	name         = COALESCE($1, name),
	neighborhood = COALESCE($2, neighborhood),
	floor_count  = COALESCE($3, floor_count),
	updated_at   = now()
WHERE id = $4
RETURNING <kolonlar>;
```
> `COALESCE` yalnızca "gönderilmedi → koru" içindir. Alanı **NULL'a çekmek** de gerekiyorsa
> üç durumlu tip kullan ([API-11]) ve `CASE WHEN $n_set THEN $n_val ELSE kolon END` yaz.

---

## 5. Hata çevirimi (pgx)

`internal/repository/postgres/errors.go`:

```go
const (
	pgUniqueViolation     = "23505" // kayıt zaten var        -> 409
	pgForeignKeyViolation = "23503" // olmayan kayda referans  -> 404
	pgNotNullViolation    = "23502" // NOT NULL kolona NULL    -> 400
	pgCheckViolation      = "23514" // CHECK dışı değer        -> 400
	pgStringTruncated     = "22001" // VARCHAR sınırı aşıldı   -> 400
	pgInvalidTextRepr     = "22P02" // UUID/sayı biçimi bozuk  -> 400
	pgInvalidDatetime     = "22008" // geçersiz tarih          -> 400
	pgNumericOutOfRange   = "22003" // sayı aralık dışı        -> 400
)

// Constraint adı -> istemciye gösterilecek mesaj. Ham hata ASLA dışarı verilmez [SEC-17].
var constraintMessages = map[string]string{
	"parkings_original_id_key":  "bu original_id ile kayıtlı bir kayıt zaten var",
	"parkings_capacity_valid":   "dolu kapasite, toplam kapasiteden büyük olamaz",
	"stall_debts_stall_id_fkey": "tezgah bulunamadı",
}

func translate(err error) error {
	var pgErr *pgconn.PgError
	if !errors.As(err, &pgErr) {
		return err
	}
	if msg, ok := constraintMessages[pgErr.ConstraintName]; ok {
		switch pgErr.Code {
		case pgUniqueViolation:
			return fmt.Errorf("%w: %s", ErrConflict, msg)
		case pgForeignKeyViolation:
			return fmt.Errorf("%w: %s", ErrNotFound, msg)
		default:
			return fmt.Errorf("%w: %s", ErrInvalidInput, msg)
		}
	}
	switch pgErr.Code {
	case pgUniqueViolation:
		return fmt.Errorf("%w: kayıt zaten mevcut", ErrConflict)
	case pgForeignKeyViolation:
		return fmt.Errorf("%w: ilişkili kayıt bulunamadı", ErrNotFound)
	case pgNotNullViolation, pgCheckViolation, pgStringTruncated,
		pgInvalidTextRepr, pgInvalidDatetime, pgNumericOutOfRange:
		return fmt.Errorf("%w: gönderilen veri geçersiz", ErrInvalidInput)
	}
	// Bilinmeyen kod: iç hata say, TAM hâliyle logla, istemciye maskele.
	pkg.Log.Error("beklenmeyen postgres hatası", "code", pgErr.Code, "err", pgErr)
	return ErrInternal
}
```

**[DB-20] ZORUNLU:** Yukarıdaki **sekiz kodun hepsi** çevrilir.
> **Ölçüm:** Beş serviste yalnızca `23503` ve `23514` çevrilmişti; bu yüzden aynı
> `original_id` ile ikinci POST ve 300 karakterlik ad **500** dönüyordu. İkisi de
> istemci hatasıdır.

**[DB-21] ZORUNLU:** Sentinel hatalar (`ErrNotFound`, `ErrConflict`, `ErrInvalidInput`,
`ErrInternal`) dışa açılır; handler `errors.Is` ile eşler ([API-22]).

---

## 6. Transaction

**[DB-22] ZORUNLU:** Birden fazla tabloyu değiştiren iş **tek transaction**'da yapılır:

```go
func (r *repo) TransferStall(ctx context.Context, from, to string) error {
	tx, err := r.pool.Begin(ctx)
	if err != nil {
		return fmt.Errorf("%w: transaction açılamadı", ErrInternal)
	}
	// Rollback ZORUNLU defer: erken return veya panic'te açık transaction kalmasın.
	// Commit sonrası Rollback no-op'tur, güvenlidir.
	defer tx.Rollback(ctx)

	if _, err := tx.Exec(ctx, `UPDATE ... WHERE id = $1`, from); err != nil {
		return translate(err)
	}
	if _, err := tx.Exec(ctx, `UPDATE ... WHERE id = $1`, to); err != nil {
		return translate(err)
	}
	return tx.Commit(ctx)
}
```

**[DB-23] ZORUNLU:** Transaction **kısa** tutulur. İçinde HTTP çağrısı, dosya IO, uzun
hesap yapılmaz.
> **Neden:** Açık transaction satır kilidi tutar ve `VACUUM`'u engeller. Bir HTTP çağrısı
> 5 sn sürerse o kilit 5 sn boyunca başka istekleri bekletir.

**[DB-24] ZORUNLU:** Transaction'ın `context`'i vardır ve timeout'u üst katmandan gelir.

**[DB-25] ÖNERİLEN:** Deadlock riski olan yerlerde kilit sırasını sabitle — kayıtları
her zaman aynı sırada (örn. `id ASC`) kilitle.

---

## 7. Index ve sorgu performansı

**[DB-26] ZORUNLU:** Sık filtrelenen kolona index konur. `WHERE` ve `ORDER BY`'da geçen
kolon kombinasyonu için **bileşik index** kurulur (`(created_at DESC, id ASC)`).

**[DB-27] ZORUNLU:** Yeni ya da değiştirilen liste sorgusu `EXPLAIN (ANALYZE, BUFFERS)`
ile kontrol edilir. `Seq Scan` büyük tabloda kabul edilmez.

**[DB-28] YASAK:** N+1 sorgu. Listedeki her kayıt için ayrı sorgu atma; `JOIN` ya da
`WHERE id = ANY($1)` kullan.
```go
// YANLIŞ: 50 kayıt = 51 sorgu
for _, p := range parkings { p.Owner, _ = r.GetOwner(ctx, p.OwnerID) }

// DOĞRU: 2 sorgu
owners, _ := r.GetOwnersByIDs(ctx, ownerIDs)   // WHERE id = ANY($1)
```

**[DB-29] ÖNERİLEN:** Toplu ekleme `pgx.CopyFrom` ile yapılır — tek tek `INSERT`'ten
kat kat hızlıdır. Orta ölçekte `pgx.Batch` yeterlidir.

**[DB-30] ÖNERİLEN:** Index sayısını abartma. Her index yazma maliyetini artırır ve disk
tüketir. Kullanılmayan index'leri `pg_stat_user_indexes` ile bul ve sil.

**[DB-31] ZORUNLU:** Yavaş sorgu logu açıktır (`log_min_duration_statement = 500ms`) ve
çıktısı düzenli okunur. Ölçülmeyen yavaşlık, kullanıcı şikâyetiyle öğrenilir.

---

## 8. Yedekleme ve veri güvenliği

**[DB-32] ZORUNLU:** Üretim veritabanının otomatik yedeği vardır ve **geri yükleme
denenmiştir**. Denenmemiş yedek, yedek değildir.

**[DB-33] ZORUNLU:** Silme işlemleri geri alınamaz kabul edilir. Kritik tablolarda
**soft delete** (`deleted_at TIMESTAMPTZ`) kullan ve tüm sorgulara `WHERE deleted_at IS NULL`
ekle — bu filtreyi unutmak en sık yapılan hatadır, ortak `WHERE` sabitine koy.

**[DB-34] ZORUNLU:** Üretimde toplu `UPDATE`/`DELETE` çalıştırmak onay gerektirir. Önce
aynı `WHERE` ile `SELECT COUNT(*)` çek ve sayıyı doğrula.

---

## 9. ASLA YAPMA — veritabanı

- ❌ Handler'dan doğrudan SQL çalıştırmak
- ❌ Repository'de iş kuralı
- ❌ Başka servisin tablosuna doğrudan sorgu
- ❌ `SELECT *`
- ❌ Ardışık int PK
- ❌ `TIMESTAMP` (tz'siz) kullanmak
- ❌ Tie-break'siz `ORDER BY` ile sayfalama
- ❌ Nullable FK ile zorunlu ilişki kurmak
- ❌ Kopya/türetilmiş alanı istemciden yazdırmak
- ❌ "Bilinmiyor" için `0` / `""` kullanmak
- ❌ `GENERATED` kolonu Request DTO'suna koymak
- ❌ Geri alınamayan, `Down` bloğu olmayan migration
- ❌ Tek adımda kolon silen/yeniden adlandıran migration
- ❌ Üretimde `CREATE INDEX` (CONCURRENTLY olmadan)
- ❌ Transaction içinde HTTP çağrısı
- ❌ `defer tx.Rollback(ctx)` yazmamak
- ❌ N+1 sorgu
- ❌ Havuz bütçesini aşmak (servis × MaxConns > max_connections)
- ❌ Sekiz hata kodundan bir kısmını çevirip gerisini 500'e bırakmak
