# 19 — Identity, Password, and Session

> This file is for the **auth service**. Other services do not authenticate; they work
> with the information the gateway gives them ([SEC-03],
> [ADR-0018](adr/0018-authentication.md)).
>
> The errors in this file share one trait: **they stay invisible until there is an
> attack.** A weak hashing algorithm gives no sign of anything until the day of the
> breach.

---

## 1. Password storage

**[AUTH-01] MUST — passwords are hashed with `argon2id`.**

```go
import "golang.org/x/crypto/argon2"

// OWASP's practical recommendation (2026): m=64 MiB, t=3, p=1 → ~100 ms on a modern
// core.
// OWASP's absolute floor: m=19 MiB, t=2, p=1. Never go BELOW this.
// The ~100 ms target: short enough not to make the user wait, long enough to slow
// an attacker down. As hardware gets faster, the parameters are RAISED.
const (
	argonMemory  = 64 * 1024 // KiB → 64 MiB
	argonTime    = 3
	argonThreads = 1
	argonKeyLen  = 32
	saltLen      = 16
)

func HashPassword(plain string) (string, error) {
	salt := make([]byte, saltLen)
	if _, err := rand.Read(salt); err != nil {   // crypto/rand — NOT math/rand
		return "", fmt.Errorf("failed to generate salt: %w", err)
	}
	key := argon2.IDKey([]byte(plain), salt, argonTime, argonMemory, argonThreads, argonKeyLen)

	// PHC string format: the algorithm and parameters are stored INSIDE the hash [AUTH-02].
	return fmt.Sprintf("$argon2id$v=%d$m=%d,t=%d,p=%d$%s$%s",
		argon2.Version, argonMemory, argonTime, argonThreads,
		base64.RawStdEncoding.EncodeToString(salt),
		base64.RawStdEncoding.EncodeToString(key)), nil
}
```

**[AUTH-02] MUST:** The hash carries the **algorithm and parameters used** within
itself (PHC string format).
> **Why:** you will raise the parameters later. If the hash does not record them, you
> cannot verify old records and you would be forced to make every user reset their
> password.

**[AUTH-03] MUST:** If a hash's parameters are below the current standard at login
and **verification succeeds**, the password is rehashed and saved with the current
parameters (rehash on login). This way the user base strengthens itself over time.

**[AUTH-04] MUST:** Verification uses a **constant-time** comparison
(`subtle.ConstantTimeCompare`) — comparing bytes with `==` leaks timing information.

**[AUTH-05] MUST NOT:** MD5, SHA-1, plain SHA-256/512, `crypt`, a hand-rolled hash, an
unsalted hash, or a salt shared across all users.
> Fast hash functions are the **wrong tool** for passwords — being fast means an
> attacker can try billions of guesses per second.

**[AUTH-06] SHOULD:** `bcrypt` is used only when compatibility with an existing system
requires it, and only with **cost ≥ 12**. New systems prefer argon2id. Do not forget
bcrypt's 72-byte password limit — longer passwords are silently truncated.

**[AUTH-07] MUST:** Password policy is built on **length**, not on imposed complexity:
- At least **12 characters** (14 for administrator accounts)
- Upper bound of at least 64 characters — do not set a short upper bound
- A complexity rule (mandatory upper/lower/digit/symbol) is **not imposed**: it pushes
  users toward guessable patterns like `Password123!`
- A known-breached-password list check is recommended
- The password field is bounded by **bytes**, not `[]rune`, and is passed to the hash
  raw

**[AUTH-08] MUST:** The password, its hash, and reset tokens are **never logged under
any circumstances** ([SEC-25]) and never appear in error messages.

**[AUTH-09] MUST:** When the password changes, **all active sessions are terminated**
(except the current one, optionally). That is the whole point of changing a password.

---

## 2. Login flow

**[AUTH-10] MUST — user enumeration is prevented.** A failed login always returns
the same message:
```json
{ "error": true, "message": "Incorrect username or password" }
```
Saying "no such user" hands an attacker a way to enumerate valid accounts.

**[AUTH-11] MUST:** Even when the user is not found, **a dummy hash verification is
still run**:
```go
// Pay the argon2 cost even if the user does not exist: otherwise the difference in
// response time answers the question "does this user exist" (timing enumeration).
if user == nil {
    _ = VerifyPassword(dummyHash, plain)
    return ErrInvalidCredentials
}
```

**[AUTH-12] MUST — account lockout.** Rate limiting ([RES-01]: 5 requests / 15
min) is IP-based and is not enough by itself; a distributed attack rotates IPs. In
addition, **per account**:

| Consecutive failed attempts | Result |
|---|---|
| 5 | 1-minute wait |
| 10 | 15-minute lock |
| 20 | Account locked — requires reset/admin intervention |

- The counter **resets on a successful login**
- The lockout is reported to the user (email) — they should know their account is
  under attack
- Locking and unlocking are written to the **audit trail** ([AUDIT-01])

> **Caution — DoS risk:** account lockout lets an attacker **deliberately lock**
> someone else's account. For this reason, an increasing wait time is preferred over a
> permanent lock, and a permanent lock after 20 attempts requires an additional signal
> (same IP, known bad network).

**[AUTH-13] MUST:** Successful and failed logins are written to the audit trail: user,
IP, time, result, `user_agent` ([AUDIT-02]).

---

## 3. Tokens and sessions

**[AUTH-14] MUST — two tokens:**

| Token | Lifetime | Stored where | What it does |
|---|---|---|---|
| **Access** | **15 minutes** | Memory / `Authorization` header | Authorises every request |
| **Refresh** | **7 days** (30 on mobile) | `HttpOnly` + `Secure` + `SameSite=Strict` cookie, or secure storage | Issues a new access token |

> The short access lifetime makes the "a JWT cannot be revoked" problem manageable
> ([ADR-0018]): a user whose access is revoked loses access within 15 minutes at the
> most.

**[AUTH-15] MUST — refresh token rotation.** Every use produces a **new** refresh
token and invalidates the old one:

```
Client refreshes with refresh_1 → refresh_2 issued, refresh_1 REVOKED
Client refreshes with refresh_2 → refresh_3 issued, refresh_2 REVOKED
```

**[AUTH-16] MUST — reuse detection.** If a revoked refresh token is used again,
that means the **token was stolen**: the user's **entire token family** is revoked and
the user is notified.
> **Why:** if an attacker stole the token, both parties will eventually try to use it;
> whichever uses the old token first gets caught. Without rotation, a stolen token
> quietly keeps working for its whole lifetime.

**[AUTH-17] MUST:** Refresh tokens are stored in the database **hashed** (SHA-256 is
enough — since it is a high-entropy random value, argon2 is not needed). If the DB
leaks, the raw tokens must not fall into the wrong hands.

**[AUTH-18] MUST:** A refresh record contains: `user_id`, `token_hash`, `family_id`,
`expires_at`, `revoked_at`, `created_ip`, `user_agent`. Expired records are cleaned up
regularly.

**[AUTH-19] MUST — JWT rules** (gateway and auth service only):
- `alg` is **fixed**, and the expected algorithm is stated explicitly during
  verification; `none` is rejected
- Required claims: `sub`, `exp`, `iat`, `jti`
- `exp` is checked with clock-skew tolerance ([TIME-05])
- The signing key comes from env ([GEN-13]), at least 32 random bytes
- The `kid` claim is used for key rotation

**[AUTH-20] MUST:** Logout revokes the refresh token. The access token stays valid
until it expires — this is a **deliberate trade-off**; if immediate revocation is
needed, a `jti`-based revocation list is kept (Redis, TTL equal to the access
lifetime).

**[AUTH-21] SHOULD:** Users can see their active sessions and terminate them
individually.

---

## 4. Password reset and verification

**[AUTH-22] MUST — reset token:**
- Cryptographically random (`crypto/rand`), at least 32 bytes
- Stored **hashed** in the DB
- Lifetime **at most 1 hour**
- **Single use** — revoked once used
- All sessions are terminated once it is used ([AUTH-09])

**[AUTH-23] MUST:** A reset request **always returns the same response**, whether the
email is registered or not (same reasoning as [AUTH-10]):
```json
{ "message": "If this email is registered, a reset link has been sent." }
```

**[AUTH-24] MUST:** The reset link is sent by email; sending an email/SMS is subject to
the rules in [20](20-INTEGRATION-AND-BULK-DATA.md) §3 (idempotency, rate limit).

**[AUTH-25] MUST:** When an email or phone number is **changed**, the new address is
verified and **a notification goes to the old address** — the user must be able to
notice an account takeover attempt.

**[AUTH-26] SHOULD:** **Multi-factor authentication (MFA)** is required for admin and
highly privileged accounts (TOTP is enough). Backup codes are also stored hashed.

---

## 5. Testing

**[AUTH-27] MUST:**
```
□ Password hash is argon2id and parameters match the expected values
□ Hashing the same password twice gives a DIFFERENT output (salt is working)
□ Wrong password → verification fails
□ Hash with old parameters → login succeeds AND is rehashed
□ Login with a non-existent user → same message, similar response time
□ N failed attempts → lockout; successful login → counter resets
□ Refresh rotation: using an old refresh a second time revokes the whole family
□ Expired refresh → 401
□ alg=none JWT → rejected
□ Password change invalidates old access/refresh tokens
□ Reset token used a second time → rejected
□ No password/hash/token appears in logs
```

---

## 6. NEVER DO THIS

- ❌ Hashing a password with MD5/SHA-1/plain SHA-256
- ❌ An unsalted hash, or a salt shared across users
- ❌ Generating a salt/token with `math/rand`
- ❌ Setting the argon2id parameters below the OWASP floor
- ❌ Not storing the algorithm/parameters inside the hash
- ❌ Logging the password, its hash, or a token
- ❌ Saying "no such user"
- ❌ Skipping the hash verification when the user does not exist (timing leak)
- ❌ IP-based brute-force protection alone
- ❌ A refresh token with no lifetime or no rotation
- ❌ Storing a refresh token in the DB in plain form
- ❌ Silently accepting a reused refresh token
- ❌ A JWT with no `alg` validation
- ❌ Leaving sessions open after a password change
- ❌ A multi-use or long-lived reset token
- ❌ Not notifying the old address on an email change
- ❌ Imposing complexity while keeping the length limit low
