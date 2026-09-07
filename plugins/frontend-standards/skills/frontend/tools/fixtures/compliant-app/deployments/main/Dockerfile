# ---------- build ----------
FROM node:24-alpine AS builder
WORKDIR /app
COPY package*.json ./
RUN npm ci
COPY . .
ARG BUILD_ID=dev
ENV BUILD_ID=$BUILD_ID
ARG VITE_BUILD_ID=dev
ENV VITE_BUILD_ID=$VITE_BUILD_ID
RUN npm run build

# ---------- runtime ----------
FROM nginxinc/nginx-unprivileged:1.30-alpine
COPY --from=builder /app/dist /usr/share/nginx/html
COPY deployments/main/nginx/default.conf.template /etc/nginx/templates/default.conf.template
COPY deployments/main/nginx/security-headers.conf /etc/nginx/conf.d/security-headers.conf
EXPOSE 8080
HEALTHCHECK --interval=30s --timeout=3s --start-period=5s --retries=3 \
  CMD wget -qO- http://localhost:8080/healthz || exit 1
