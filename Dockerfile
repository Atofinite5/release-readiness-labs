FROM node:24-alpine

# Build metadata. CI passes the release version and the commit being built so every
# image can be traced back to exactly one version and one commit.
ARG VERSION=dev
ARG GIT_SHA=unknown

LABEL org.opencontainers.image.title="orderflow" \
      org.opencontainers.image.version="${VERSION}" \
      org.opencontainers.image.revision="${GIT_SHA}" \
      org.opencontainers.image.source="https://github.com/kalviumcommunity/release-readiness-labs"

ENV NODE_ENV=production \
    GIT_SHA=${GIT_SHA}

WORKDIR /app

# Reproducible, production-only install from the committed lockfile.
COPY app/package.json app/package-lock.json ./
RUN npm ci --omit=dev && npm cache clean --force

COPY app/server.js ./

# Never run the service as root.
USER node

EXPOSE 3000

HEALTHCHECK --interval=30s --timeout=3s --start-period=10s --retries=3 \
  CMD wget -qO- "http://127.0.0.1:${PORT:-3000}/health" || exit 1

# Exec form, no npm wrapper: node is PID 1 and receives SIGTERM directly.
CMD ["node", "server.js"]
