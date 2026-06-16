# ============================================
# Stage 1: Install dependencies
# ============================================
FROM node:22-alpine AS deps

RUN apk add --no-cache \
    python3 \
    make \
    g++ \
    pkgconf \
    cairo-dev \
    pango-dev \
    libjpeg-turbo-dev \
    giflib-dev \
    librsvg-dev \
    pixman-dev

RUN corepack enable && corepack prepare pnpm@9.15.9 --activate

WORKDIR /app

COPY package.json pnpm-lock.yaml ./

RUN pnpm install --frozen-lockfile


# ============================================
# Stage 2: Build the application
# ============================================
FROM node:22-alpine AS build

RUN apk add --no-cache \
    python3 \
    make \
    g++ \
    pkgconf \
    cairo-dev \
    pango-dev \
    libjpeg-turbo-dev \
    giflib-dev \
    librsvg-dev \
    pixman-dev

RUN corepack enable && corepack prepare pnpm@9.15.9 --activate

WORKDIR /app

COPY --from=deps /app/node_modules ./node_modules
COPY . .

# Dummy env vars for build-time validation.
# Real values are injected at runtime via docker-compose / Coolify.
ENV DATABASE_URL="postgresql://placeholder:placeholder@placeholder:5432/placeholder"
ENV INNGEST_ID="nextcrm-build"
ENV INNGEST_APP_NAME="NextCRM-Build"
ENV INNGEST_EVENT_KEY="build-placeholder"
ENV INNGEST_SIGNING_KEY="build-placeholder"
ENV BETTER_AUTH_SECRET="build-time-placeholder-secret-replace-at-runtime"
ENV BETTER_AUTH_URL="http://localhost:3000"
ENV MINIO_ENDPOINT="http://placeholder:9000"
ENV MINIO_PORT="9000"
ENV MINIO_BUCKET="placeholder"
ENV MINIO_USE_SSL="false"
ENV MINIO_ACCESS_KEY="placeholder"
ENV MINIO_SECRET_KEY="placeholder"
ENV NEXT_PUBLIC_MINIO_ENDPOINT="http://placeholder:9000"
ENV NEXT_PUBLIC_APP_NAME="NextCRM"
ENV NEXT_PUBLIC_APP_URL="http://localhost:3000"
ENV EMAIL_ENCRYPTION_KEY="0000000000000000000000000000000000000000000000000000000000000000"
ENV OPENAI_API_KEY="sk-placeholder-for-build"
ENV RESEND_API_KEY="re_placeholder_for_build"
ENV RESEND_FROM_EMAIL="noreply@example.com"
ENV GOOGLE_ID=""
ENV GOOGLE_SECRET=""
ENV FIRECRAWL_API_KEY=""
ENV E2B_API_KEY=""
ENV SKIP_ENV_VALIDATION=1

ENV NODE_OPTIONS="--max-old-space-size=4096"
ENV NEXT_TELEMETRY_DISABLED=1

RUN pnpm prisma generate
RUN pnpm next build --webpack


# ============================================
# Stage 3: Production runner
# ============================================
FROM node:22-alpine AS runner

RUN apk add --no-cache \
    curl \
    postgresql-client \
    cairo \
    pango \
    libjpeg-turbo \
    giflib \
    librsvg \
    pixman

# Install Prisma CLI + tsx + dotenv into a separate /opt/tools directory.
# This avoids conflicts with Next.js standalone node_modules.
WORKDIR /opt/tools

RUN printf '{"name":"nextcrm-tools","version":"0.0.0","private":true}\n' > package.json && \
    npm install --no-audit --no-fund \
    prisma@7.6.0 \
    @prisma/client@7.6.0 \
    @prisma/adapter-pg@7.6.0 \
    pg@8.18.0 \
    tsx@4.21.0 \
    dotenv@17.3.1 \
    typescript@5.9.3

WORKDIR /app

ENV NODE_ENV=production
ENV NEXT_TELEMETRY_DISABLED=1

# Create non-root user
RUN addgroup --system --gid 1001 nodejs && \
    adduser --system --uid 1001 nextjs

# Copy standalone build output
COPY --from=build /app/.next/standalone ./
COPY --from=build /app/.next/static ./.next/static
COPY --from=build /app/public ./public

# Copy Prisma schema + migrations + seeds for runtime migrate deploy / seed
COPY --from=build /app/prisma ./prisma

# Write Docker-specific Prisma config
RUN printf '%s\n' \
    'import { defineConfig, env } from "prisma/config";' \
    '' \
    'export default defineConfig({' \
    '  datasource: {' \
    '    url: env("DATABASE_URL"),' \
    '  },' \
    '  migrations: {' \
    '    seed: "tsx prisma/seeds/seed.ts",' \
    '  },' \
    '});' \
    > /app/prisma.config.ts

# Merge required runtime packages into /app/node_modules
RUN mkdir -p /app/node_modules/@prisma && \
    cp -rn /opt/tools/node_modules/@prisma/adapter-pg /app/node_modules/@prisma/ 2>/dev/null || true && \
    cp -rn /opt/tools/node_modules/pg-cloudflare /app/node_modules/ 2>/dev/null || true

# Copy entrypoint
COPY docker-entrypoint.sh ./docker-entrypoint.sh
RUN chmod +x docker-entrypoint.sh

# Set ownership
RUN chown -R nextjs:nodejs /app /opt/tools

USER nextjs

EXPOSE 3000

ENV PORT=3000
ENV HOSTNAME="0.0.0.0"
ENV PATH="/opt/tools/node_modules/.bin:$PATH"
ENV NODE_PATH="/opt/tools/node_modules"

ENTRYPOINT ["./docker-entrypoint.sh"]
