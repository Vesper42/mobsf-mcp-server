# MobSF MCP Server

A Model Context Protocol (MCP) server that provides integration with [Mobile Security Framework (MobSF)](https://github.com/MobSF/Mobile-Security-Framework-MobSF) for automated mobile application security analysis.

![Version](https://img.shields.io/badge/version-2.1.0-blue)
![License](https://img.shields.io/badge/license-MIT-green)
![MCP](https://img.shields.io/badge/MCP-Streamable%20HTTP-purple)

## Features

- 🔍 **Automated APK/IPA Scanning** - Upload and scan Android/iOS applications
- 📊 **Comprehensive Reports** - Get detailed security analysis reports
- 🔐 **AI Agent Compatible** - Base64 file upload support for AI platforms
- 🐳 **Dockerized** - Easy deployment with Docker
- 🔄 **Streamable HTTP** - Modern MCP transport (not SSE)

## Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│                        AI Agent / MCP Client                     │
│                   (VS Code, Claude, Custom Apps)                 │
└──────────────────────────────┬──────────────────────────────────┘
                               │ HTTP (Streamable HTTP Transport)
                               │ POST http://localhost:7567/mcp
                               ▼
┌─────────────────────────────────────────────────────────────────┐
│                      MobSF MCP Server                            │
│                    (Docker: Port 7567)                           │
│  ┌───────────────────────────────────────────────────────────┐  │
│  │  Tools:                                                    │  │
│  │  • scanFile - Scan APK/IPA from file path                 │  │
│  │  • scanFileBase64 - Scan from base64 encoded data         │  │
│  │  • getReport - Get detailed scan report                   │  │
│  │  • listScans - List all recent scans                      │  │
│  │  • deleteScan - Remove scan from MobSF                    │  │
│  └───────────────────────────────────────────────────────────┘  │
└──────────────────────────────┬──────────────────────────────────┘
                               │ HTTP REST API
                               ▼
┌─────────────────────────────────────────────────────────────────┐
│                          MobSF                                   │
│                    (Docker: Port 9000)                           │
│            Mobile Security Analysis Engine                       │
└─────────────────────────────────────────────────────────────────┘
```

## Quick Start

### One-Click Installation

```bash
# Clone the repository
git clone https://github.com/pullkitsan/mobsf-mcp-server.git
cd mobsf-mcp-server

# Run the installer (installs MobSF + MCP Server)
./install.sh
```

The installer will:
1. ✅ Check if services are already running (skips if healthy)
2. ✅ Check prerequisites (Docker, docker-compose)
3. ✅ Pull and start MobSF on port 9000
4. ✅ Extract the API key automatically
5. ✅ Create the `.env` configuration file
6. ✅ Build and start the MCP server on port 7567

### Manual Installation

1. **Start MobSF** (if not already running):
   ```bash
   docker run -d --name mobsf \
     -p 9000:8000 \
     -v mobsf_data:/home/mobsf/.MobSF \
     opensecurity/mobile-security-framework-mobsf:latest
   ```

2. **Get MobSF API Key**:
   ```bash
   docker logs mobsf 2>&1 | grep "REST API Key"
   ```

3. **Configure environment**:
   ```bash
   cp .env.example .env
   # Edit .env with your MOBSF_API_KEY
   ```

4. **Start MCP Server**:
   ```bash
   docker-compose up -d --build
   ```

## Uninstallation

```bash
# Interactive mode
./uninstall.sh

# Remove MCP server only (keep MobSF)
./uninstall.sh --mcp-only

# Full cleanup (remove everything)
./uninstall.sh --full
```

### Restart MCP Server

If you've updated `.env` configuration:

```bash
./install.sh --restart
```

## Configuration

### Environment Variables

| Variable | Description | Default |
|----------|-------------|---------|
| `MOBSF_URL` | MobSF server URL | `http://host.docker.internal:9000` |
| `MOBSF_API_KEY` | MobSF REST API key | Required |
| `MCP_API_KEY` | Bearer token for MCP authentication | Optional (recommended) |
| `PORT` | MCP server port | `7567` |

### Example `.env` file

```env
MOBSF_URL=http://host.docker.internal:9000
MOBSF_API_KEY=your-mobsf-api-key-here
MCP_API_KEY=your-mcp-auth-token-here
```

## Authentication

The MCP server supports optional Bearer token authentication. When `MCP_API_KEY` is configured, all requests to `/mcp` must include an `Authorization` header:

```
Authorization: Bearer <your-mcp-api-key>
```

**Generate a secure token:**
```bash
openssl rand -hex 32
```

The `install.sh` script will automatically offer to generate a secure token for you.

> **Note:** The `/health` and `/` endpoints do not require authentication.

## MCP Client Configuration

### VS Code (GitHub Copilot)

Create or edit `~/.vscode/mcp.json` (or use VS Code's MCP settings):

```json
{
  "servers": {
    "mobsf-mcp-server": {
      "url": "http://127.0.0.1:7567/mcp"
    }
  }
}
```

**With authentication (recommended):**
```json
{
  "servers": {
    "mobsf-mcp-server": {
      "url": "http://127.0.0.1:7567/mcp",
      "headers": {
        "Authorization": "Bearer your-mcp-api-key-here"
      }
    }
  }
}
```
```

### Claude Desktop

Add to `claude_desktop_config.json`:

```json
{
  "mcpServers": {
    "mobsf": {
      "url": "http://localhost:7567/mcp"
    }
  }
}
```

### Generic MCP Client

```javascript
const client = new MCPClient({
  transport: "streamable-http",
  url: "http://localhost:7567/mcp"
});
```

## Available Tools

### `scanFile`

Scan an APK or IPA file from a file path. **Supports automatic path translation** - you can use your host machine paths directly (e.g., `/Users/username/Downloads/app.apk`), and they will be automatically translated to container paths.

**Parameters:**
- `file` (string, required): Path to the APK/IPA file (host or container path)

**Example:**
```json
{
  "tool": "scanFile",
  "arguments": {
    "file": "/Users/username/Downloads/app.apk"
  }
}
```

> **Note:** The Docker container mounts your home directory at `/host_home`, so files anywhere under your home folder are accessible.
```

### `scanFileBase64`

Scan a file uploaded as base64 encoded data. Ideal for AI agents that can't access the filesystem directly.

**Parameters:**
- `filename` (string, required): Name of the file (must end with .apk or .ipa)
- `content` (string, required): Base64 encoded file content
- `contentType` (string, optional): MIME type

**Example:**
```json
{
  "tool": "scanFileBase64",
  "arguments": {
    "filename": "app.apk",
    "content": "base64-encoded-content-here",
    "contentType": "application/vnd.android.package-archive"
  }
}
```

### `getReport`

Get the detailed security analysis report for a scanned file.

**Parameters:**
- `hash` (string, required): The MD5 hash of the scanned file

**Example:**
```json
{
  "tool": "getReport",
  "arguments": {
    "hash": "abc123def456..."
  }
}
```

### `listScans`

List all recent scans in MobSF.

**Parameters:**
- `page` (number, optional): Page number (default: 1)
- `pageSize` (number, optional): Results per page (default: 10)

**Example:**
```json
{
  "tool": "listScans",
  "arguments": {
    "page": 1,
    "pageSize": 20
  }
}
```

### `deleteScan`

Delete a scan from MobSF.

**Parameters:**
- `hash` (string, required): The MD5 hash of the scan to delete

**Example:**
```json
{
  "tool": "deleteScan",
  "arguments": {
    "hash": "abc123def456..."
  }
}
```

## API Endpoints

| Endpoint | Method | Auth Required | Description |
|----------|--------|---------------|-------------|
| `/` | GET | No | Server info and available tools |
| `/mcp` | POST | Yes* | MCP protocol endpoint (Streamable HTTP) |
| `/mcp/` | POST | Yes* | MCP protocol endpoint (alias with trailing slash) |
| `/health` | GET | No | Health check endpoint |

*Auth required only if `MCP_API_KEY` is configured.

## Security Features

This server implements several security best practices:

- 🔐 **Bearer Token Authentication** - Optional but recommended
- ⏱️ **Request Timeouts** - All API calls have timeouts to prevent hanging
- 🔒 **Timing-Safe Comparison** - API key validation uses `crypto.timingSafeEqual`
- 📁 **Filename Sanitization** - Prevents path traversal attacks
- 🚫 **Sensitive Data Masking** - Base64 content and file paths are masked in logs
- 🛑 **Graceful Shutdown** - Proper cleanup of sessions on SIGTERM/SIGINT
- 👤 **Non-root Docker User** - Container runs as unprivileged user

## Development

### Local Development

```bash
# Install dependencies
npm install

# Build
npm run build

# Run locally (requires MobSF running)
npm start
```

### Docker Build

```bash
# Build image
docker-compose build

# Start in foreground (see logs)
docker-compose up

# Start in background
docker-compose up -d

# View logs
docker-compose logs -f

# Restart
docker-compose restart
```

## Troubleshooting

### Connection refused to MobSF

1. Verify MobSF is running:
   ```bash
   docker ps | grep mobsf
   ```

2. Check MobSF logs:
   ```bash
   docker logs mobsf
   ```

3. Verify API key is correct:
   ```bash
   curl -X POST http://localhost:9000/api/v1/scans \
     -H "Authorization: your-api-key"
   ```

### MCP Server not responding

1. Check container status:
   ```bash
   docker-compose ps
   ```

2. Check logs:
   ```bash
   docker-compose logs -f mobsf-mcp-server
   ```

3. Verify health endpoint:
   ```bash
   curl http://localhost:7567/health
   ```

### File upload issues

1. Ensure the file path is accessible from the container
2. For Docker, files must be in mounted volumes
3. Use `scanFileBase64` for AI agents without filesystem access

## License

MIT License - see [LICENSE](LICENSE) file.

## Contributing

1. Fork the repository
2. Create a feature branch
3. Make your changes
4. Submit a pull request

## Credits

- [MobSF](https://github.com/MobSF/Mobile-Security-Framework-MobSF) - The amazing mobile security analysis platform
- [Model Context Protocol](https://modelcontextprotocol.io) - The MCP specification

## Acknowledgments

This project is a modernized version of the original [pullkitsan/mobsf-mcp-server](https://github.com/pullkitsan/mobsf-mcp-server) repository, which was unmaintained for 9+ months.

**Key improvements in this version:**
- ✨ Upgraded from stdio to **Streamable HTTP transport**
- 🐳 Full **Docker support** with multi-stage builds
- 📦 Updated to latest **@modelcontextprotocol/sdk v1.11.0**
- 🔧 Added **install.sh** and **uninstall.sh** for easy setup
- 📤 Added **base64 file upload** support for AI agents
- 🛡️ Enhanced security with non-root Docker user
- 🔐 **Optional Bearer token authentication** for MCP endpoints
- 🔄 **Automatic path translation** - use host paths directly
- ⏱️ **Request timeouts** on all API calls
- 🛑 **Graceful shutdown** handling
- 🔒 **Timing-safe token comparison** to prevent timing attacks

