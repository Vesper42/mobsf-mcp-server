# Build stage
FROM node:20-alpine AS builder

WORKDIR /app

# Copy package files
COPY package*.json ./

# Install all dependencies (including dev)
RUN npm ci

# Copy source files
COPY tsconfig.json ./
COPY server.ts ./

# Build TypeScript
RUN npm run build

# Production stage
FROM node:20-alpine AS production

WORKDIR /app

# Copy package files
COPY package*.json ./

# Install only production dependencies
RUN npm ci --only=production && npm cache clean --force

# Copy built files from builder stage
COPY --from=builder /app/dist ./dist

# Create non-root user for security
RUN addgroup -g 1001 -S nodejs && \
    adduser -S mcp -u 1001 -G nodejs

# Create uploads directory with proper permissions
RUN mkdir -p /app/uploads && chown -R mcp:nodejs /app/uploads

USER mcp

# Expose the MCP server port
EXPOSE 7567

# Environment variables with defaults
ENV PORT=7567 \
    MOBSF_URL=http://host.docker.internal:9000 \
    NODE_ENV=production \
    UPLOAD_DIR=/app/uploads

# Health check (use 127.0.0.1 to avoid IPv6 issues)
HEALTHCHECK --interval=30s --timeout=10s --start-period=5s --retries=3 \
    CMD wget --no-verbose --tries=1 --spider http://127.0.0.1:7567/health || exit 1

# Start the server
CMD ["node", "dist/server.js"]
