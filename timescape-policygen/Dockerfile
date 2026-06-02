# Multi-stage build. Toolchain base images are pulled through the lab Nexus
# (the cluster/bastion IDMS/ITMS already mirror docker.io → artifactory…:8443),
# so build with:
#   podman build -t artifactory.ocp-migrate.md.prglab.local:8443/timescape-policygen:0.1 .
# then push to the lab registry the cluster can pull from.

# ---- frontend build ----
FROM docker.io/library/node:20-alpine AS fe
ARG HTTPS_PROXY
ARG NO_PROXY
WORKDIR /fe
COPY frontend/package.json ./
# npm needs a scheme-qualified proxy URL; the lab profile exports a bare host:port,
# so normalize it here. If HTTPS_PROXY is empty (Nexus npm mirror in use), npm goes
# direct. (npm registry reachability is a build prerequisite — see README.md.)
RUN if [ -n "$HTTPS_PROXY" ]; then \
      npm config set proxy "http://$HTTPS_PROXY" && \
      npm config set https-proxy "http://$HTTPS_PROXY" && \
      npm config set noproxy "$NO_PROXY"; \
    fi && \
    npm install --no-audit --no-fund
COPY frontend/ ./
RUN npm run build      # → /fe/dist

# ---- backend build ----
FROM docker.io/library/golang:1.22-alpine AS be
ARG HTTPS_PROXY
ARG NO_PROXY
WORKDIR /src
COPY backend/go.mod backend/go.sum ./
# Scheme-qualify the proxy for Go's module fetch (same bare host:port issue as npm).
RUN if [ -n "$HTTPS_PROXY" ]; then \
      export HTTPS_PROXY="http://$HTTPS_PROXY" HTTP_PROXY="http://$HTTPS_PROXY" NO_PROXY="$NO_PROXY"; \
    fi && go mod download
COPY backend/ ./
RUN CGO_ENABLED=0 GOOS=linux go build -trimpath -ldflags="-s -w" -o /policygen .

# ---- runtime ----
FROM docker.io/library/alpine:3.20
RUN adduser -D -u 10001 app
WORKDIR /app
COPY --from=be /policygen /app/policygen
COPY --from=fe /fe/dist /app/static
ENV STATIC_DIR=/app/static LISTEN_ADDR=:8080
USER 10001
EXPOSE 8080
ENTRYPOINT ["/app/policygen"]
