# 19 — Kimlik, Parola ve Oturum

> Bu dosya **auth servisi** içindir. Diğer servisler kimlik doğrulamaz; gateway'in
> verdiği bilgiyle çalışır ([SEC-03], [ADR-0018](adr/0018-kimlik-dogrulama.md)).
>
> Buradaki hataların ortak özelliği: **saldırı olana kadar görünmezler.** Zayıf hash
> algoritması, sızıntı gününe kadar hiçbir belirti vermez.

---

## 1. Parola saklama

**[AUTH-01] ZORUNLU — Parolalar `argon2id` ile hash'lenir.**

```go
import "golang.org/x/crypto/argon2"

// OWASP'ın pratik önerisi (2026): m=64 MiB, t=3, p=1 → modern bir çekirdekte ~100 ms.
// OWASP mutlak alt sınır: m=19 MiB, t=2, p=1. Bunun ALTINA İNİLMEZ.
// Süre hedefi ~100 ms: kullanıcıyı bekletmeyecek kadar kısa, saldırganı
// yavaşlatacak kadar uzun. Donanım hızlandıkça parametreler ARTIRILIR.
const (
	argonMemory  = 64 * 1024 // KiB → 64 MiB
	argonTime    = 3
	argonThreads = 1
	argonKeyLen  = 32
	saltLen      = 16
)

func HashPassword(plain string) (string, error) {
	salt := make([]byte, saltLen)
	if _, err := rand.Read(salt); err != nil {   // crypto/rand — math/rand DEĞİL
		return "", fmt.Errorf("salt üretilemedi: %w", err)
	}
	key := argon2.IDKey([]byte(plain), salt, argonTime, argonMemory, argonThreads, argonKeyLen)

	// PHC string formatı: algoritma ve parametreler hash'in İÇİNDE saklanır [AUTH-02].
	return fmt.Sprintf("$argon2id$v=%d$m=%d,t=%d,p=%d$%s$%s",
		argon2.Version, argonMemory, argonTime, argonThreads,
		base64.RawStdEncoding.EncodeToString(salt),
		base64.RawStdEncoding.EncodeToString(key)), nil
}
```

**[AUTH-02] ZORUNLU:** Hash, kullanılan **algoritma ve parametreleri kendi içinde** taşır
(PHC string formatı).
> **Neden:** Parametreleri ileride artıracaksın. Hash'te yazmıyorsa eski kayıtları
> doğrulayamazsın ve tüm kullanıcıları parola sıfırlamaya zorlamak zorunda kalırsın.

**[AUTH-03] ZORUNLU:** Girişte hash'in parametreleri güncelin altındaysa, **doğrulama
başarılıysa** parola yeniden hash'lenip kaydedilir (rehash on login). Böylece kullanıcı
tabanı zamanla kendiliğinden güçlenir.

**[AUTH-04] ZORUNLU:** Doğrulama **sabit zamanlı** karşılaştırma ile yapılır
(`subtle.ConstantTimeCompare`) — `==` ile bayt karşılaştırması zamanlama sızdırır.

**[AUTH-05] YASAK:** MD5, SHA-1, düz SHA-256/512, `crypt`, kendi yazdığın hash, tuzsuz
hash, tüm kullanıcılar için ortak tuz.
> Hızlı hash fonksiyonları parola için **yanlış araçtır** — hızlı olmaları, saldırganın
> saniyede milyarlarca deneme yapabilmesi demektir.

**[AUTH-06] ÖNERİLEN:** `bcrypt` yalnızca mevcut sistemle uyumluluk gerekiyorsa ve
**cost ≥ 12** ile kullanılır. Yeni sistemde argon2id tercih edilir. bcrypt'in 72 baytlık
parola sınırı unutulmaz — uzun parolalar sessizce kırpılır.

**[AUTH-07] ZORUNLU:** Parola politikası **uzunluk** üzerine kurulur, karmaşıklık dayatması
üzerine değil:
- En az **12 karakter** (yönetici hesapları için 14)
- Üst sınır en az 64 karakter — kısa üst sınır koyma
- Karmaşıklık kuralı (büyük/küçük/rakam/sembol zorunluluğu) **dayatılmaz**: kullanıcıyı
  `Parola123!` gibi tahmin edilebilir kalıplara iter
- Bilinen sızmış parola listesi kontrol edilir (öneri)
- Parola alanı `[]rune` ile değil **bayt** ile sınırlanır ve hash'e ham geçirilir

**[AUTH-08] ZORUNLU:** Parola, hash'i, sıfırlama token'ı **hiçbir koşulda loglanmaz**
([SEC-25]) ve hata mesajında yer almaz.

**[AUTH-09] ZORUNLU:** Parola değiştiğinde **tüm aktif oturumlar sonlandırılır** (mevcut
oturum hariç, tercihe bağlı). Parola değiştirmenin amacı budur.

---

## 2. Giriş akışı

**[AUTH-10] ZORUNLU — Kullanıcı sayımı (enumeration) engellenir.** Başarısız giriş her
zaman aynı mesajı döner:
```json
{ "error": true, "message": "Kullanıcı adı veya parola hatalı" }
```
"Böyle bir kullanıcı yok" demek, saldırgana geçerli hesap listesi çıkarmasını sağlar.

**[AUTH-11] ZORUNLU:** Kullanıcı bulunamasa bile **sahte bir hash doğrulaması çalıştırılır**:
```go
// Kullanıcı yoksa da argon2 maliyetini öde: aksi hâlde yanıt süresi farkı
// "bu kullanıcı var mı" sorusunu cevaplar (timing enumeration).
if user == nil {
    _ = VerifyPassword(dummyHash, plain)
    return ErrInvalidCredentials
}
```

**[AUTH-12] ZORUNLU — Hesap kilitleme.** Rate limit ([RES-01]: 5 istek / 15 dk) IP
bazlıdır ve yeterli değildir; dağıtık bir saldırı IP değiştirir. Ek olarak **hesap bazında**:

| Ardışık başarısız deneme | Sonuç |
|---|---|
| 5 | 1 dakika bekleme |
| 10 | 15 dakika kilit |
| 20 | Hesap kilitli — sıfırlama/yönetici müdahalesi gerekir |

- Sayaç **başarılı girişte sıfırlanır**
- Kilitlenme kullanıcıya bildirilir (e-posta) — hesabına saldırıldığını bilmeli
- Kilitlenme ve açılma **denetim izine** yazılır ([AUDIT-01])

> **Dikkat — DoS riski:** Hesap kilitleme, saldırganın başkasının hesabını **kasten
> kilitlemesine** izin verir. Bu yüzden kalıcı kilit yerine artan bekleme süresi tercih
> edilir ve 20 denemeden sonraki kalıcı kilit için ek sinyal (aynı IP, bilinen kötü ağ)
> aranır.

**[AUTH-13] ZORUNLU:** Başarılı ve başarısız girişler denetim izine yazılır: kullanıcı,
IP, zaman, sonuç, `user_agent` ([AUDIT-02]).

---

## 3. Token ve oturum

**[AUTH-14] ZORUNLU — İki token:**

| Token | Ömür | Nerede saklanır | Ne yapar |
|---|---|---|---|
| **Access** | **15 dakika** | Bellek / `Authorization` header | Her isteği yetkilendirir |
| **Refresh** | **7 gün** (mobilde 30) | `HttpOnly` + `Secure` + `SameSite=Strict` cookie ya da güvenli depo | Yeni access üretir |

> Kısa access ömrü, JWT'nin iptal edilememesi problemini yönetilebilir kılar ([ADR-0018]):
> yetkisi alınan kullanıcı en fazla 15 dakika içinde erişimini kaybeder.

**[AUTH-15] ZORUNLU — Refresh token rotasyonu.** Her kullanımda **yeni** refresh token
üretilir ve eskisi geçersiz kılınır:

```
İstemci refresh_1 ile yeniler → refresh_2 verilir, refresh_1 İPTAL
İstemci refresh_2 ile yeniler → refresh_3 verilir, refresh_2 İPTAL
```

**[AUTH-16] ZORUNLU — Yeniden kullanım tespiti.** İptal edilmiş bir refresh token tekrar
kullanılırsa, bu **token çalınmış** demektir: o kullanıcının **tüm token ailesi** iptal
edilir ve kullanıcı bilgilendirilir.
> **Neden:** Saldırgan token'ı çaldıysa ikisi de kullanmaya çalışır; biri eski token'ı
> kullandığında yakalanır. Rotasyon olmadan çalıntı token ömrü boyunca sessizce çalışır.

**[AUTH-17] ZORUNLU:** Refresh token'lar veritabanında **hash'lenmiş** saklanır (SHA-256
yeterli — yüksek entropili rastgele değer olduğu için argon2 gerekmez). DB sızarsa düz
token'lar ele geçmemelidir.

**[AUTH-18] ZORUNLU:** Refresh kaydında bulunur: `user_id`, `token_hash`, `family_id`,
`expires_at`, `revoked_at`, `created_ip`, `user_agent`. Süresi geçmiş kayıtlar düzenli
temizlenir.

**[AUTH-19] ZORUNLU — JWT kuralları** (yalnızca gateway ve auth servisi):
- `alg` **sabittir** ve doğrulamada beklenen algoritma açıkça belirtilir; `none` reddedilir
- Zorunlu claim'ler: `sub`, `exp`, `iat`, `jti`
- `exp` kontrolü saat kayması toleransıyla ([ZAM-05])
- İmzalama anahtarı env'den gelir ([GEN-13]), en az 32 rastgele bayt
- Anahtar rotasyonu için `kid` claim'i kullanılır

**[AUTH-20] ZORUNLU:** Çıkış (`logout`) refresh token'ı iptal eder. Access token süresi
dolana kadar geçerli kalır — bu **bilinçli bir kabuldür**; anında iptal gerekiyorsa
`jti` tabanlı iptal listesi (Redis, access ömrü kadar TTL) tutulur.

**[AUTH-21] ÖNERİLEN:** Kullanıcı aktif oturumlarını görebilmeli ve tek tek
sonlandırabilmeli.

---

## 4. Parola sıfırlama ve doğrulama

**[AUTH-22] ZORUNLU — Sıfırlama token'ı:**
- Kriptografik olarak rastgele (`crypto/rand`), en az 32 bayt
- DB'de **hash'lenmiş** saklanır
- Ömür **en fazla 1 saat**
- **Tek kullanımlık** — kullanılınca iptal
- Kullanıldığında tüm oturumlar sonlandırılır ([AUTH-09])

**[AUTH-23] ZORUNLU:** Sıfırlama isteği **her zaman aynı yanıtı** döner, e-posta kayıtlı
olsun ya da olmasın ([AUTH-10] ile aynı gerekçe):
```json
{ "message": "Eğer bu e-posta kayıtlıysa, sıfırlama bağlantısı gönderildi." }
```

**[AUTH-24] ZORUNLU:** Sıfırlama bağlantısı e-posta ile gönderilir; SMS/e-posta gönderimi
[20](20-ENTEGRASYON-VE-TOPLU-VERI.md) §3 kurallarına tabidir (idempotency, rate limit).

**[AUTH-25] ZORUNLU:** E-posta veya telefon **değiştirilirken** yeni adres doğrulanır ve
**eski adrese bildirim gider** — hesap ele geçirme girişimini kullanıcı fark etmelidir.

**[AUTH-26] ÖNERİLEN:** Yönetici ve yüksek yetkili hesaplarda **çok faktörlü doğrulama
(MFA)** zorunlu tutulur (TOTP yeterli). Yedek kodlar da hash'lenerek saklanır.

---

## 5. Test

**[AUTH-27] ZORUNLU:**
```
□ Parola hash'i argon2id ve parametreler beklenen değerlerde
□ Aynı parola iki kez hash'lenince FARKLI çıktı (tuz çalışıyor)
□ Yanlış parola → doğrulama başarısız
□ Eski parametreli hash → giriş başarılı VE yeniden hash'lenmiş
□ Var olmayan kullanıcı ile giriş → aynı mesaj, benzer yanıt süresi
□ N başarısız deneme → kilit; başarılı giriş → sayaç sıfır
□ Refresh rotasyonu: eski refresh ikinci kez kullanılınca tüm aile iptal
□ Süresi geçmiş refresh → 401
□ alg=none JWT → reddedilir
□ Parola değişince eski access/refresh geçersiz
□ Sıfırlama token'ı ikinci kez kullanılınca → reddedilir
□ Loglarda parola/hash/token geçmiyor
```

---

## 6. ASLA YAPMA

- ❌ MD5/SHA-1/düz SHA-256 ile parola hash'lemek
- ❌ Tuzsuz veya ortak tuzlu hash
- ❌ `math/rand` ile tuz/token üretmek
- ❌ Argon2id parametrelerini OWASP alt sınırının altına indirmek
- ❌ Hash'in içinde algoritma/parametre saklamamak
- ❌ Parolayı, hash'i, token'ı loglamak
- ❌ "Böyle bir kullanıcı yok" demek
- ❌ Kullanıcı yokken hash doğrulamasını atlamak (timing sızıntısı)
- ❌ Yalnızca IP bazlı brute force koruması
- ❌ Sonsuz ömürlü ya da rotasyonsuz refresh token
- ❌ Refresh token'ı DB'de düz saklamak
- ❌ Yeniden kullanılan refresh token'ı sessizce kabul etmek
- ❌ `alg` doğrulamasız JWT
- ❌ Parola değişince oturumları açık bırakmak
- ❌ Çok kullanımlık veya uzun ömürlü sıfırlama token'ı
- ❌ E-posta değişikliğini eski adrese bildirmemek
- ❌ Karmaşıklık dayatıp uzunluk sınırını düşük tutmak
