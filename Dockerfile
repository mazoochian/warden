# syntax=docker/dockerfile:1

# ---------------------------------------------------------------------------
# Stage 1: build the warden binary with Zig, statically against musl so it
# runs on any x86_64 Linux (including the Alpine base of the final stage).
# ---------------------------------------------------------------------------
FROM alpine:3.22 AS zig-build
ARG ZIG_VERSION=0.16.0
# The retry loop and curl --retry exist because builds run on networks with
# transient DNS/connection failures; downloading to a file (rather than
# piping into tar) keeps a mid-stream retry from corrupting the extraction.
RUN for i in 1 2 3 4 5; do apk add --no-cache curl xz postgresql-dev && break || { [ "$i" = 5 ] && exit 1; sleep 5; }; done \
    && curl -fSL --retry 5 --retry-delay 2 --retry-all-errors -o /tmp/zig.tar.xz \
       "https://ziglang.org/download/${ZIG_VERSION}/zig-x86_64-linux-${ZIG_VERSION}.tar.xz" \
    && tar -xJf /tmp/zig.tar.xz -C /opt \
    && rm /tmp/zig.tar.xz \
    && mv "/opt/zig-x86_64-linux-${ZIG_VERSION}" /opt/zig
ENV PATH="/opt/zig:${PATH}"

WORKDIR /build
COPY build.zig build.zig.zon ./
COPY third_party ./third_party
COPY src ./src
RUN --mount=type=cache,target=/root/.cache/zig \
    zig build -Doptimize=ReleaseSafe -Dtarget=x86_64-linux-musl

# ---------------------------------------------------------------------------
# Stage 2: install the Node tool dependencies *inside* the target platform.
# The host node_modules are excluded via .dockerignore on purpose:
# @napi-rs/canvas ships a native binary per platform/libc, so a glibc
# desktop install would not work on the Alpine (musl) image.
# Puppeteer's bundled Chromium download is skipped; the final stage uses
# the distro Chromium instead.
# ---------------------------------------------------------------------------
FROM node:22-alpine AS node-deps
ENV PUPPETEER_SKIP_DOWNLOAD=true \
    PUPPETEER_SKIP_CHROMIUM_DOWNLOAD=true
WORKDIR /deps
COPY tools/diagram/package.json tools/diagram/package-lock.json ./diagram/
RUN cd diagram && npm ci --omit=dev
COPY tools/wordcloud/package.json tools/wordcloud/package-lock.json ./wordcloud/
RUN cd wordcloud && npm ci --omit=dev

# ---------------------------------------------------------------------------
# Final image: node runtime + system Chromium for mermaid-cli.
# ---------------------------------------------------------------------------
FROM node:22-alpine
RUN for i in 1 2 3 4 5; do apk add --no-cache chromium font-noto font-noto-arabic fontconfig ca-certificates tzdata libpq && break || { [ "$i" = 5 ] && exit 1; sleep 5; }; done \
    && test -x /usr/bin/chromium-browser
ENV PUPPETEER_EXECUTABLE_PATH=/usr/bin/chromium-browser \
    PUPPETEER_SKIP_DOWNLOAD=true

WORKDIR /app
COPY --from=zig-build /build/zig-out/bin/warden ./warden
COPY tools/diagram/puppeteer-config.json ./tools/diagram/puppeteer-config.json
COPY --from=node-deps /deps/diagram/node_modules ./tools/diagram/node_modules
COPY tools/wordcloud/render.mjs ./tools/wordcloud/render.mjs
COPY tools/wordcloud/fonts ./tools/wordcloud/fonts
COPY --from=node-deps /deps/wordcloud/node_modules ./tools/wordcloud/node_modules
COPY docker-entrypoint.sh ./docker-entrypoint.sh
# Chat/message data lives in Postgres now (WARDEN_POSTGRES_DSN) — /app/data
# only holds WARDEN_TMP_DIR's throwaway scratch files (wordcloud/diagram
# rendering), not persistent state.
RUN chmod +x ./docker-entrypoint.sh && mkdir -p /app/data

ENTRYPOINT ["/app/docker-entrypoint.sh"]
