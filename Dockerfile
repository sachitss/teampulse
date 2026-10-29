# TeamPulse web app — one image for the Synology NAS (Container Manager) or any Docker host.
# Built by GitHub Actions and published to ghcr.io/sachitss/teampulse (linux/amd64; DS918+ is x86-64).
#   docker build -t teampulse .
# The same image runs the web app (default) and the database manager:
#   node db/manage.mjs migrate | create-admin | reset-link | reset-mfa | status

FROM node:22-bookworm-slim AS build
WORKDIR /src
ENV NEXT_TELEMETRY_DISABLED=1
COPY package.json package-lock.json ./
COPY packages/bs-calendar/package.json packages/bs-calendar/
COPY web/package.json web/
RUN npm ci --no-audit --no-fund
COPY packages packages
COPY web web
RUN npm run build --workspace @teampulse/web

FROM node:22-bookworm-slim
ENV NODE_ENV=production NEXT_TELEMETRY_DISABLED=1 PORT=3000 HOSTNAME=0.0.0.0 TZ=UTC
WORKDIR /app
COPY --from=build --chown=node:node /src/web/.next/standalone ./
COPY --from=build --chown=node:node /src/web/.next/static ./web/.next/static
COPY --from=build --chown=node:node /src/web/public ./web/public
COPY --chown=node:node db/migrations db/migrations
COPY --chown=node:node db/seed db/seed
COPY --chown=node:node db/demo db/demo
COPY --chown=node:node db/manage.mjs db/manage.mjs
RUN mkdir -p /data/files && chown node:node /data/files
USER node
EXPOSE 3000
HEALTHCHECK --interval=30s --timeout=5s --start-period=30s --retries=3 \
  CMD node -e "fetch('http://127.0.0.1:3000/sign-in').then(r=>process.exit(r.ok?0:1)).catch(()=>process.exit(1))"
CMD ["node", "web/server.js"]
