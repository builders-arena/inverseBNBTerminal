# Multi-purpose image: build once, run any service via $SERVICE (api|indexer|keeper|relayer|warmer).
FROM node:20-alpine AS build
WORKDIR /app
COPY package.json package-lock.json* ./
RUN npm ci
COPY prisma ./prisma
RUN npx prisma generate
COPY tsconfig.json ./
COPY src ./src
RUN npm run build

FROM node:20-alpine AS runtime
WORKDIR /app
ENV NODE_ENV=production
COPY package.json package-lock.json* ./
RUN npm ci --omit=dev
COPY prisma ./prisma
RUN npx prisma generate
COPY --from=build /app/dist ./dist
# SERVICE selects the entrypoint; defaults to api.
ENV SERVICE=api
CMD ["sh", "-c", "node dist/services/${SERVICE}.js"]
