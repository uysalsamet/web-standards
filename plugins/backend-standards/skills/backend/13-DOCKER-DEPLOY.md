# 13 — Docker ve Deploy

---

## 1. Dockerfile

**[OPS-01] ZORUNLU:** Multi-stage build. Nihai imajda derleyici, kaynak kod ve git yoktur.

```dockerfile
# ---------- build ----------
FROM golang:1.25-alpine AS builder

WORKDIR /app

# Bağımlılıklar ayrı katmanda: kaynak değişince go mod download tekrar koşmasın.
COPY services/<isim>-service/go.mod services/<isim>-service/go.sum ./
RUN go mod download

COPY services/<isim>-service/cmd ./cmd
COPY services/<isim>-service/internal ./internal
COPY services/<isim>-service/pkg ./pkg

# CGO_ENABLED=0: statik binary, alpine'da glibc bağımlılığı olmaz.
# -s -w: sembol ve debug bilgisini at, imaj ~%30 küçülür.
# Sürüm bilgisi binary'ye gömülür; /version ucu bunu döner [OBS-19].
ARG VERSION=dev
ARG COMMIT=unknown
RUN CGO_ENABLED=0 GOOS=linux go build \
    -trimpath \
    -ldflags="-s -w -X main.version=${VERSION} -X main.commit=${COMMIT}" \
    -o /app/service ./cmd/main.go

# ---------- runtime ----------
FROM alpine:3.24

# ca-certificates: HTTPS upstream çağrıları için. wget: HEALTHCHECK için.
RUN apk add --no-cache ca-certificates wget tzdata \
 && adduser -D -u 10001 appuser

WORKDIR /app

COPY --from=builder --chown=appuser:appuser /app/service ./service
# Migration SQL dosyaları imaja GİRMELİ, yoksa servis şemayı kuramaz.
COPY --from=builder --chown=appuser:appuser /app/internal/repository/postgres/migrations ./migrations

USER appuser
EXPOSE 3300

HEALTHCHECK --interval=30s --timeout=3s --start-period=10s --retries=3 \
  CMD wget -qO- http://localhost:3300/health || exit 1

CMD ["./service"]
```

**[OPS-02] ZORUNLU:** Base imajlar pinlenir ([VER-09]); `latest` yasaktır.

**[OPS-03] ZORUNLU:** Konteyner **non-root** çalışır (`USER appuser`).
> **Neden:** Konteyner kaçışı açıkları root ile çalışan konteynerlerde host'a erişim
> verir. Non-root, en ucuz ve en etkili konteyner sertleştirmesidir.

**[OPS-04] ZORUNLU:** `HEALTHCHECK` tanımlıdır ve `/health` ucunu çağırır. `start-period`
verilir; aksi hâlde yavaş açılan servis daha ayağa kalkmadan "unhealthy" damgası yer.

**[OPS-05] ZORUNLU:** `EXPOSE` değeri servisin **gerçek** portudur. Kopyala-yapıştır
sırasında güncellenmeyen port kimseyi bozmaz ama okuyanı yanıltır.

**[OPS-06] ZORUNLU:** `.dockerignore` bulunur:
```
.git
.env*
**/*_test.go
docs/
*.md
```
> Build context ne kadar küçükse build o kadar hızlı; ayrıca `.env` dosyasının yanlışlıkla
> imaja girmesi engellenir.

**[OPS-07] YASAK:** İmaja sır kopyalamak. `ARG` ile geçirilen sır bile **imaj katmanlarında
kalır** ve `docker history` ile okunur.

**[OPS-08] ÖNERİLEN:** Nihai imaj hedefi **< 30 MB**. Çok büyükse muhtemelen kaynak kod
veya gereksiz paketler girmiştir.

---

## 2. Compose

```yaml
services:
  <isim>-service:
    build:
      context: ../
      dockerfile: services/<isim>-service/deployments/Dockerfile
      args:
        VERSION: ${VERSION:-dev}
        COMMIT: ${COMMIT:-unknown}
    container_name: app-<isim>-service
    restart: unless-stopped
    # ports DEĞİL expose: servis dışarı açılmaz, yalnızca iç ağdan erişilir [SEC-01].
    expose:
      - "${<ISIM>_SERVICE_PORT:-3300}"
    environment:
      SERVICE_NAME: <isim>-service
      <ISIM>_SERVICE_PORT: ${<ISIM>_SERVICE_PORT:-3300}
      DB_HOST: ${DB_HOST}
      DB_PORT: ${DB_PORT}
      DB_USER: ${DB_USER}
      DB_PASSWORD: ${DB_PASSWORD}        # değer YOK, referans VAR [SEC-18]
      DB_NAME: ${DB_NAME}
      DB_MAX_CONNS: ${DB_MAX_CONNS:-10}
      API_SECURITY_KEY: ${API_SECURITY_KEY}
      LOG_LEVEL: ${LOG_LEVEL:-info}
      GOMEMLIMIT: 200MiB                 # limitin ~%80'i [PERF-06]
    depends_on:
      postgres:
        condition: service_healthy       # sadece "başladı" değil, "hazır"
    deploy:
      resources:
        limits:
          memory: 256M
          cpus: "0.5"
        reservations:
          memory: 128M
    logging:
      driver: json-file
      options:
        max-size: "10m"                  # disk dolmasın
        max-file: "3"
    networks:
      - app_network

networks:
  app_network:
    driver: bridge
```

**[OPS-09] ZORUNLU:** Yalnızca gateway `ports:` açar. Diğer tüm servisler `expose:` kullanır.

**[OPS-10] ZORUNLU:** `depends_on` **`condition: service_healthy`** ile kullanılır. Düz
`depends_on` yalnızca "konteyner başladı" der; Postgres henüz bağlantı kabul etmiyor olabilir.

**[OPS-11] ZORUNLU:** Her servise bellek/CPU limiti verilir ([PERF-04]).

**[OPS-12] ZORUNLU:** Log rotasyonu tanımlanır (`max-size`, `max-file`). Tanımsız bırakılan
json-file log driver'ı diski doldurur ve **tüm host'u** durdurur.

**[OPS-13] ÖNERİLEN:** Ağır bağımlılıklar (Postgres, Kafka, Temporal, Grafana) ayrı compose
dosyasında tutulur; geliştirici yalnızca ihtiyacı olanı ayağa kaldırır.

---

## 3. Env yönetimi

**[OPS-14] ZORUNLU — Katmanlar:**

| Katman | Yer | Ne için |
|---|---|---|
| Kod içi varsayılan | `config.go` → `getEnv(key, default)` | **Sadece yerel geliştirme** |
| Compose değişkeni | `docker-compose.yml` → `${VAR}` | Container'a hangi env geçecek |
| Gerçek değer | `.env.local` / `.env.prod` | Çalıştırma anında dışarıdan gelir |
| Compose kimliği | `deployments/.env` | Yalnızca `COMPOSE_PROJECT_NAME` |

```bash
# Geliştirme
docker compose --env-file .env.local -f docker-compose.yml up -d --build
# Production
docker compose --env-file .env.prod  -f docker-compose.yml up -d --build
```

**[OPS-15] ZORUNLU:** Yeni servis eklerken **hem** `.env.local` **hem** `.env.prod` **hem**
`.env.example` içine iki satır girer:
```bash
<ISIM>_SERVICE_PORT=3300                                  # repo genelinde BENZERSİZ
<ISIM>_SERVICE_URL=http://app-<isim>-service:3300         # gateway'in ulaşacağı iç URL
```

**[OPS-16] ZORUNLU:** Port çakışması yasaktır. Yeni servis, mevcut `.env.local` kontrol
edilerek bir sonraki boş aralığı alır. Kullanılan portların listesi `docs/README.md`'de tutulur.

**[OPS-17] ZORUNLU:** `.env*` git'e girmez ([SEC-20]); `.env.example` girer ([SEC-21]).

---

## 4. Gateway entegrasyonu

Servis tek başına işe yaramaz. Gateway'de **iki katman** vardır ve ikisi de gereklidir:

**[OPS-18] ZORUNLU — Adım 1:** Gateway config'ine servis URL alanı eklenir
(`XServiceURL`, env: `X_SERVICE_URL`).

**[OPS-19] ZORUNLU — Adım 2:** Proxy hedefi tanımlanır (route tablosu). Spesifik
pattern'ler wildcard'dan **önce** gelir — eşleştirme ilk eşleşeni döner.

**[OPS-20] ZORUNLU — Adım 3:** Gateway router'ına yol kaydedilir
(`r.Any("/x-items/*path", gatewayService.Proxy())`).
> **Sık yapılan hata:** Yalnızca Adım 2 yapılırsa istek gateway'e **hiç ulaşmaz** ve
> **404** alınır — ama env doğru, route tanımı binary'de, servis ayakta olduğu için
> teşhis uzun sürer. Yeni serviste 404 görüyorsan **önce Adım 3'ü kontrol et**.

**[OPS-21] ZORUNLU — Adım 4:** Yetki tanımları eklenir: modül başına en az dört kayıt
(`view`, `create`, `update`, `delete`) ve admin rolünün modül listesine yeni modül eklenir.
Anahtarlar servisteki `RequirePermission` çağrılarıyla **birebir** aynıdır ([SEC-06]).
Yükleme **DB'den sorgulanarak** doğrulanır ([TEST-22]).

**[OPS-22] ZORUNLU:** Health ucu gateway'de **auth'suz** ve rewrite'lı tanımlanır
(`/x-items/health` → `/health`).

---

## 5. Deploy

**[OPS-23] ZORUNLU:** Deploy edilen artefakt **imajdır**, kaynak kod değil. Sunucuda
`git pull && go build` yapılmaz.
> **Neden:** Test edilen ile çalışan aynı şey olmalıdır. Sunucuda derleme, farklı Go
> sürümü/farklı bağımlılık ile farklı bir binary üretebilir.

**[OPS-24] ZORUNLU:** İmaj etiketi **immutable**dır: `<servis>:<commit-sha>`. Aynı etiketi
farklı içerikle yeniden yayınlamak yasaktır; `latest`'e deploy edilmez.

**[OPS-25] ZORUNLU:** Rolling deploy sırasında eski ve yeni sürüm **aynı anda** çalışır.
Bu yüzden:
- Migration'lar ileriye uyumludur ([DB-13])
- API değişiklikleri kırıcı değildir ([API-29])
- Kuyruk mesaj şeması geriye uyumludur ([ASYNC-06])

**[OPS-26] ZORUNLU:** Geri alma (rollback) planı vardır ve **denenmiştir**: önceki imaj
etiketine dönmek yeterli olmalıdır. Migration geri alınamıyorsa deploy iki aşamaya bölünür.

**[OPS-27] ZORUNLU:** Deploy sonrası doğrulama yapılır: `/health`, `/ready`, hata oranı
ve p95 metriği ilk 15 dakika izlenir ([OBS-21]).

**[OPS-28] ÖNERİLEN:** Cuma öğleden sonra ve tatil öncesi üretim deploy'u yapılmaz —
hata çıkarsa müdahale edecek kimse olmaz.

---

## 6. ASLA YAPMA — docker & deploy

- ❌ Tek aşamalı (multi-stage olmayan) Dockerfile
- ❌ `latest` imaj etiketi
- ❌ root olarak çalışan konteyner
- ❌ `HEALTHCHECK`'siz imaj
- ❌ İmaja sır / `.env` kopyalamak
- ❌ İş servisinde `ports:` açmak
- ❌ Kaynak limiti olmayan konteyner
- ❌ Log rotasyonu tanımlamamak
- ❌ `condition: service_healthy` olmadan `depends_on`
- ❌ Migration SQL dosyalarını imaja koymayı unutmak
- ❌ Port çakıştırmak
- ❌ Sunucuda derleyip deploy etmek
- ❌ Aynı imaj etiketini farklı içerikle yeniden yayınlamak
- ❌ Gateway'de yalnız route tablosunu güncelleyip router kaydını unutmak
- ❌ Servisi yazıp gateway/yetki/env entegrasyonunu yapmamak
