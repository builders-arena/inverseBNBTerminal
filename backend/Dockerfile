# Multi-purpose image: build once, run any service via $SERVICE (api|indexer|keeper|relayer|warmer).
# Debian slim (not alpine): Prisma's query/schema engines need OpenSSL, which alpine lacks — on alpine
# Prisma misdetects libssl, downloads the wrong engine, and `db push` fails to load it.
FROM node:20-slim AS build
WORKDIR /app
RUN apt-get update && apt-get install -y --no-install-recommends openssl ca-certificates \
  && rm -rf /var/lib/apt/lists/*
COPY package.json package-lock.json* ./
RUN npm ci
COPY prisma ./prisma
RUN npx prisma generate
COPY tsconfig.json ./
COPY src ./src
RUN npm run build

FROM node:20-slim AS runtime
WORKDIR /app
ENV NODE_ENV=production
RUN apt-get update && apt-get install -y --no-install-recommends openssl ca-certificates \
  && rm -rf /var/lib/apt/lists/*
COPY package.json package-lock.json* ./
# --omit=dev drops the prisma CLI (a devDependency); re-add it (not persisted to the lockfile) so the
# generated client and the release-time `prisma db push` both work in the runtime image.
RUN npm ci --omit=dev && npm install --no-save prisma@5.22.0
COPY prisma ./prisma
RUN npx prisma generate
COPY --from=build /app/dist ./dist
# SERVICE selects the entrypoint; defaults to api. (Fly overrides this per process group.)
ENV SERVICE=api
CMD ["sh", "-c", "node dist/services/${SERVICE}.js"]
