#!/usr/bin/env node
/**
 * MobSF MCP Server v2.1.0
 * 
 * A Model Context Protocol server that integrates with MobSF (Mobile Security Framework)
 * for scanning APK and IPA files. Supports both file path and base64 encoded file uploads.
 * 
 * Designed to work with AI Agent platforms via Streamable HTTP transport.
 */

import { Server } from "@modelcontextprotocol/sdk/server/index.js";
import { StreamableHTTPServerTransport } from "@modelcontextprotocol/sdk/server/streamableHttp.js";
import {
  CallToolRequestSchema,
  ListToolsRequestSchema,
} from "@modelcontextprotocol/sdk/types.js";
import express, { Request, Response } from "express";
import axios from "axios";
import dotenv from "dotenv";
import { z } from "zod";
import { zodToJsonSchema } from "zod-to-json-schema";
import fs from "fs";
import path from "path";
import os from "os";
import FormData from "form-data";
import { URLSearchParams } from "url";
import { fileURLToPath } from "url";
import { randomUUID, timingSafeEqual } from "crypto";

// ESM compatibility
const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);

// Load environment variables
dotenv.config({ path: path.resolve(__dirname, ".env") });

// Configuration
const MOBSF_URL = process.env.MOBSF_URL || "http://localhost:8000";
const MOBSF_API_KEY = process.env.MOBSF_API_KEY || "";
const MCP_API_KEY = process.env.MCP_API_KEY || ""; // Optional: Bearer token for MCP authentication
const PORT = parseInt(process.env.PORT || "7567", 10);
const UPLOAD_DIR = process.env.UPLOAD_DIR || path.join(os.tmpdir(), "mobsf-uploads");
const LOG_FILE = path.join(os.tmpdir(), "mcp-mobsf.log");

// Ensure upload directory exists
try {
  if (!fs.existsSync(UPLOAD_DIR)) {
    fs.mkdirSync(UPLOAD_DIR, { recursive: true });
  }
} catch (err) {
  console.error(`Warning: Could not create upload directory at ${UPLOAD_DIR}: ${err}`);
}

// Validate required configuration
if (!MOBSF_API_KEY) {
  console.warn("⚠️  WARNING: MOBSF_API_KEY is not configured. API calls to MobSF will fail.");
}

if (!MCP_API_KEY) {
  console.warn("⚠️  WARNING: MCP_API_KEY is not configured. MCP server is running WITHOUT authentication!");
} else {
  console.log("🔐 MCP authentication enabled (Bearer token required)");
}

/**
 * Logging utility
 */
function log(msg: string): void {
  const entry = `[${new Date().toISOString()}] ${msg}\n`;
  fs.appendFileSync(LOG_FILE, entry);
  console.error(entry.trim());
}

// ============================================================================
// Tool Schemas
// ============================================================================

const ScanFilePathSchema = z.object({
  file: z.string().describe("Absolute path to the APK or IPA file to scan"),
});

const ScanFileBase64Schema = z.object({
  filename: z.string().describe("Name of the file (e.g., 'app.apk' or 'app.ipa')"),
  content: z.string().describe("Base64 encoded content of the APK or IPA file"),
  contentType: z.string().optional().describe("MIME type of the file (optional)"),
});

const GetReportSchema = z.object({
  hash: z.string().describe("The hash of a previously scanned file to retrieve its report"),
});

const ListScansSchema = z.object({
  page: z.number().optional().describe("Page number for pagination (default: 1)"),
  page_size: z.number().optional().describe("Number of results per page (default: 10)"),
});

const DeleteScanSchema = z.object({
  hash: z.string().describe("The hash of the scan to delete"),
});

// ============================================================================
// Path Translation for Docker
// ============================================================================

/**
 * Translate host paths to container paths
 * Docker mounts: $HOME -> /host_home, workspace -> /workspace
 */
function translatePath(inputPath: string): string {
  // If path starts with container paths, it's already translated
  if (inputPath.startsWith('/workspace') || inputPath.startsWith('/host_home') || inputPath.startsWith('/app/uploads')) {
    return inputPath;
  }

  // Get HOST_HOME from environment (the host's $HOME path, e.g., /Users/username)
  const hostHome = process.env.HOST_HOME;
  
  // Check if running in Docker
  const isDocker = hostHome || fs.existsSync('/host_home');
  
  if (!isDocker) {
    // Running locally, no translation needed
    return inputPath;
  }

  // If HOST_HOME is set, use it for precise path translation
  // HOST_HOME is the host's home directory (e.g., /Users/vinsen.k.alfragisa)
  // It's mounted to /host_home in Docker
  if (hostHome && inputPath.startsWith(hostHome)) {
    // /Users/vinsen.k.alfragisa/work/... -> /host_home/work/...
    const relativePath = inputPath.substring(hostHome.length);
    const translatedPath = `/host_home${relativePath}`;
    log(`Path translation: ${inputPath} -> ${translatedPath}`);
    return translatedPath;
  }

  // Fallback: Try to match /Users/xxx/ or /home/xxx/ patterns
  // Extract the home directory portion and translate
  const homeMatch = inputPath.match(/^(\/Users\/[^\/]+|\/home\/[^\/]+)(\/.*)?$/);
  if (homeMatch) {
    const restOfPath = homeMatch[2] || '';
    const translatedPath = `/host_home${restOfPath}`;
    log(`Path translation (fallback): ${inputPath} -> ${translatedPath}`);
    return translatedPath;
  }

  // Windows paths (if someone tries)
  if (/^[A-Za-z]:/.test(inputPath)) {
    log(`Warning: Windows paths not supported in Docker: ${inputPath}`);
  }

  return inputPath;
}

// ============================================================================
// MobSF API Functions
// ============================================================================

type ToolResult = {
  content: Array<{ type: "text"; text: string }>;
  isError?: boolean;
};

/**
 * Upload and scan a file from a local path
 */
async function scanFilePath(filePath: string): Promise<ToolResult> {
  // Translate host path to container path
  const containerPath = translatePath(filePath);
  
  const ext = path.extname(containerPath).toLowerCase();
  const scanType = ext === ".apk" ? "apk" : ext === ".ipa" ? "ios" : null;

  if (!scanType) {
    return {
      isError: true,
      content: [{ type: "text", text: "Unsupported file type. Must be .apk or .ipa" }],
    };
  }

  if (!fs.existsSync(containerPath)) {
    // Provide helpful error message with path info
    const errorMsg = containerPath !== filePath 
      ? `File not found: ${filePath}\nTranslated container path: ${containerPath}\n\nMake sure the file exists and is accessible from the Docker container.`
      : `File not found: ${filePath}`;
    return {
      isError: true,
      content: [{ type: "text", text: errorMsg }],
    };
  }

  try {
    log(`Uploading file from path: ${containerPath} (original: ${filePath})`);
    return await uploadAndScan(containerPath, scanType);
  } catch (error: unknown) {
    return handleError(error, "scan file");
  }
}

/**
 * Upload and scan a file from base64 content
 */
async function scanFileBase64(filename: string, base64Content: string): Promise<ToolResult> {
  const ext = path.extname(filename).toLowerCase();
  const scanType = ext === ".apk" ? "apk" : ext === ".ipa" ? "ios" : null;

  if (!scanType) {
    return {
      isError: true,
      content: [{ type: "text", text: "Unsupported file type. Filename must end with .apk or .ipa" }],
    };
  }

  try {
    // Decode base64 and save to temp file
    const buffer = Buffer.from(base64Content, "base64");
    // Sanitize filename to prevent path traversal
    const sanitizedFilename = path.basename(filename).replace(/[^a-zA-Z0-9._-]/g, '_');
    const tempPath = path.join(UPLOAD_DIR, `${randomUUID()}_${sanitizedFilename}`);
    fs.writeFileSync(tempPath, buffer);
    
    log(`Saved base64 file to: ${tempPath}`);
    
    try {
      const result = await uploadAndScan(tempPath, scanType);
      // Clean up temp file after scan
      fs.unlinkSync(tempPath);
      return result;
    } catch (err) {
      // Clean up on error
      if (fs.existsSync(tempPath)) fs.unlinkSync(tempPath);
      throw err;
    }
  } catch (error: unknown) {
    return handleError(error, "scan base64 file");
  }
}

/**
 * Core upload and scan function
 */
async function uploadAndScan(filePath: string, scanType: string): Promise<ToolResult> {
  // Upload file
  const form = new FormData();
  form.append("file", fs.createReadStream(filePath));

  const uploadRes = await axios.post(`${MOBSF_URL}/api/v1/upload`, form, {
    headers: {
      Authorization: MOBSF_API_KEY,
      ...form.getHeaders(),
    },
    maxContentLength: Infinity,
    maxBodyLength: Infinity,
    timeout: 300000, // 5 minutes timeout for large files
  });

  const { hash, file_name } = uploadRes.data;
  log(`Uploaded successfully. Hash: ${hash}, File: ${file_name}`);

  // Trigger scan
  const scanForm = new URLSearchParams();
  scanForm.append("hash", hash);
  scanForm.append("scan_type", scanType);
  scanForm.append("file_name", file_name);

  await axios.post(`${MOBSF_URL}/api/v1/scan`, scanForm.toString(), {
    headers: {
      Authorization: MOBSF_API_KEY,
      "Content-Type": "application/x-www-form-urlencoded",
    },
    timeout: 600000, // 10 minutes for scanning
  });

  // Get report
  const reportForm = new URLSearchParams();
  reportForm.append("hash", hash);

  const reportRes = await axios.post(`${MOBSF_URL}/api/v1/report_json`, reportForm.toString(), {
    headers: {
      Authorization: MOBSF_API_KEY,
      "Content-Type": "application/x-www-form-urlencoded",
    },
    timeout: 60000, // 1 minute for report retrieval
  });

  const report = reportRes.data;
  const summary = formatReport(report, scanType);

  return {
    content: [{ type: "text", text: JSON.stringify(summary, null, 2) }],
  };
}

/**
 * Get report for a previously scanned file
 */
async function getReport(hash: string): Promise<ToolResult> {
  try {
    const form = new URLSearchParams();
    form.append("hash", hash);

    const res = await axios.post(`${MOBSF_URL}/api/v1/report_json`, form.toString(), {
      headers: {
        Authorization: MOBSF_API_KEY,
        "Content-Type": "application/x-www-form-urlencoded",
      },
      timeout: 60000, // 1 minute timeout
    });

    const report = res.data;
    const scanType = report.file_name?.endsWith(".ipa") ? "ios" : "apk";
    const summary = formatReport(report, scanType);

    return {
      content: [{ type: "text", text: JSON.stringify(summary, null, 2) }],
    };
  } catch (error: unknown) {
    return handleError(error, "get report");
  }
}

/**
 * List all previous scans
 */
async function listScans(page: number = 1, pageSize: number = 10): Promise<ToolResult> {
  try {
    const form = new URLSearchParams();
    form.append("page", String(page));
    form.append("page_size", String(pageSize));

    const res = await axios.post(`${MOBSF_URL}/api/v1/scans`, form.toString(), {
      headers: {
        Authorization: MOBSF_API_KEY,
        "Content-Type": "application/x-www-form-urlencoded",
      },
      timeout: 30000, // 30 seconds timeout
    });

    return {
      content: [{ type: "text", text: JSON.stringify(res.data, null, 2) }],
    };
  } catch (error: unknown) {
    return handleError(error, "list scans");
  }
}

/**
 * Delete a scan
 */
async function deleteScan(hash: string): Promise<ToolResult> {
  try {
    const form = new URLSearchParams();
    form.append("hash", hash);

    const res = await axios.post(`${MOBSF_URL}/api/v1/delete_scan`, form.toString(), {
      headers: {
        Authorization: MOBSF_API_KEY,
        "Content-Type": "application/x-www-form-urlencoded",
      },
      timeout: 30000, // 30 seconds timeout
    });

    return {
      content: [{ type: "text", text: JSON.stringify(res.data, null, 2) }],
    };
  } catch (error: unknown) {
    return handleError(error, "delete scan");
  }
}

/**
 * Format report based on scan type
 */
function formatReport(report: Record<string, unknown>, scanType: string): Record<string, unknown> {
  if (scanType === "apk") {
    return {
      hash: report.hash,
      app_name: report.app_name,
      package_name: report.package_name,
      version_name: report.version_name,
      version_code: report.version_code,
      min_sdk: report.min_sdk,
      target_sdk: report.target_sdk,
      permissions: report.permissions,
      exported_activities: report.exported_activities,
      main_activity: report.main_activity,
      activities: report.activities,
      services: report.services,
      receivers: report.receivers,
      providers: report.providers,
      libraries: report.libraries,
      certificate_analysis: {
        certificate_summary: report.certificate_analysis,
      },
      manifest_analysis: report.manifest_analysis,
      android_api: report.android_api,
      code_analysis: report.code_analysis,
      urls: report.urls,
      domains: report.domains,
      firebase_urls: report.firebase_urls,
      trackers: report.trackers,
      network_security: report.network_security,
      security_score: report.security_score,
      average_cvss: report.average_cvss,
    };
  } else {
    return {
      hash: report.hash,
      app_name: report.app_name,
      bundle_id: report.bundle_id,
      version: report.version,
      build: report.build,
      min_ios_version: report.min_os_version,
      platform: report.platform,
      binary_archs: report.archs,
      entitlements: report.entitlements,
      url_schemes: report.url_schemes,
      binary_analysis: report.binary_analysis,
      macho_analysis: report.macho_analysis,
      code_analysis: report.code_analysis,
      file_analysis: report.file_analysis,
      urls: report.urls,
      domains: report.domains,
      security_score: report.security_score,
      average_cvss: report.average_cvss,
    };
  }
}

/**
 * Handle errors consistently
 */
function handleError(error: unknown, operation: string): ToolResult {
  const err = error as { response?: { data?: unknown; status?: number }; message?: string };
  let msg: string;
  
  if (err.response?.data) {
    msg = typeof err.response.data === "string" 
      ? err.response.data 
      : JSON.stringify(err.response.data);
  } else {
    msg = err.message || String(error);
  }
  
  log(`MobSF ${operation} error: ${msg}`);
  return {
    isError: true,
    content: [{ type: "text", text: `MobSF ${operation} failed: ${msg}` }],
  };
}

// ============================================================================
// MCP Server Setup
// ============================================================================

const server = new Server(
  { name: "mobsf", version: "2.1.0" },
  { capabilities: { tools: {} } }
);

// Register tools list handler
server.setRequestHandler(ListToolsRequestSchema, async () => {
  return {
    tools: [
      {
        name: "scanFile",
        description: "Scan an APK or IPA file from a local file path. Supports host machine paths (e.g., /Users/username/file.apk or /home/username/file.apk) which are automatically translated to container paths. You can use absolute paths from your system directly.",
        inputSchema: zodToJsonSchema(ScanFilePathSchema) as Record<string, unknown>,
      },
      {
        name: "scanFileBase64",
        description: "Scan an APK or IPA file by uploading base64 encoded content. Use this when you have file content but not a file path.",
        inputSchema: zodToJsonSchema(ScanFileBase64Schema) as Record<string, unknown>,
      },
      {
        name: "getReport",
        description: "Get the security report for a previously scanned file using its hash.",
        inputSchema: zodToJsonSchema(GetReportSchema) as Record<string, unknown>,
      },
      {
        name: "listScans",
        description: "List all previous scans stored in MobSF with pagination.",
        inputSchema: zodToJsonSchema(ListScansSchema) as Record<string, unknown>,
      },
      {
        name: "deleteScan",
        description: "Delete a scan and its associated files from MobSF.",
        inputSchema: zodToJsonSchema(DeleteScanSchema) as Record<string, unknown>,
      },
    ],
  };
});

// Register tool call handler
server.setRequestHandler(CallToolRequestSchema, async (req) => {
  const { name, arguments: args } = req.params;
  // Log tool call but mask sensitive data (base64 content, file paths)
  const safeArgs: Record<string, unknown> = { ...(args as Record<string, unknown>) };
  if (typeof safeArgs.content === 'string') {
    safeArgs.content = `[BASE64_CONTENT:${safeArgs.content.length} chars]`;
  }
  if (typeof safeArgs.file === 'string') {
    safeArgs.file = `[FILE_PATH:${path.basename(safeArgs.file)}]`;
  }
  log(`Tool call: ${name} with args: ${JSON.stringify(safeArgs)}`);

  switch (name) {
    case "scanFile": {
      const parsed = ScanFilePathSchema.safeParse(args);
      if (!parsed.success) {
        return {
          isError: true,
          content: [{ type: "text" as const, text: `Invalid input: ${parsed.error.message}` }],
        };
      }
      return await scanFilePath(parsed.data.file);
    }

    case "scanFileBase64": {
      const parsed = ScanFileBase64Schema.safeParse(args);
      if (!parsed.success) {
        return {
          isError: true,
          content: [{ type: "text" as const, text: `Invalid input: ${parsed.error.message}` }],
        };
      }
      return await scanFileBase64(parsed.data.filename, parsed.data.content);
    }

    case "getReport": {
      const parsed = GetReportSchema.safeParse(args);
      if (!parsed.success) {
        return {
          isError: true,
          content: [{ type: "text" as const, text: `Invalid input: ${parsed.error.message}` }],
        };
      }
      return await getReport(parsed.data.hash);
    }

    case "listScans": {
      const parsed = ListScansSchema.safeParse(args);
      if (!parsed.success) {
        return {
          isError: true,
          content: [{ type: "text" as const, text: `Invalid input: ${parsed.error.message}` }],
        };
      }
      return await listScans(parsed.data.page, parsed.data.page_size);
    }

    case "deleteScan": {
      const parsed = DeleteScanSchema.safeParse(args);
      if (!parsed.success) {
        return {
          isError: true,
          content: [{ type: "text" as const, text: `Invalid input: ${parsed.error.message}` }],
        };
      }
      return await deleteScan(parsed.data.hash);
    }

    default:
      return {
        isError: true,
        content: [{ type: "text" as const, text: `Unknown tool: ${name}` }],
      };
  }
});

// ============================================================================
// HTTP Server Setup
// ============================================================================

const transports: Map<string, StreamableHTTPServerTransport> = new Map();

/**
 * Authentication middleware - validates Bearer token
 */
function authenticateRequest(req: Request, res: Response, next: () => void): void {
  // Skip auth if MCP_API_KEY is not configured
  if (!MCP_API_KEY) {
    next();
    return;
  }

  const authHeader = req.headers.authorization;
  
  if (!authHeader) {
    res.status(401).json({
      jsonrpc: "2.0",
      error: {
        code: -32001,
        message: "Unauthorized: Missing Authorization header",
      },
      id: null,
    });
    return;
  }

  // Support both "Bearer <token>" and just "<token>"
  const token = authHeader.startsWith("Bearer ") 
    ? authHeader.slice(7) 
    : authHeader;

  // Use timing-safe comparison to prevent timing attacks
  const tokenBuffer = Buffer.from(token);
  const keyBuffer = Buffer.from(MCP_API_KEY);
  
  if (tokenBuffer.length !== keyBuffer.length || !timingSafeEqual(tokenBuffer, keyBuffer)) {
    log(`Authentication failed: invalid token`);
    res.status(403).json({
      jsonrpc: "2.0",
      error: {
        code: -32002,
        message: "Forbidden: Invalid API key",
      },
      id: null,
    });
    return;
  }

  next();
}

async function run() {
  const app = express();

  // NOTE: Do NOT use express.json() or express.raw() globally
  // The MCP StreamableHTTPServerTransport needs to read the raw request stream

  // MCP endpoint handler - handles Streamable HTTP protocol
  const mcpHandler = async (req: Request, res: Response) => {
    const sessionId = req.headers["mcp-session-id"] as string | undefined;
    
    log(`MCP request: ${req.method} sessionId=${sessionId || 'none'} accept=${req.headers.accept}`);

    // Reuse existing session
    if (sessionId && transports.has(sessionId)) {
      const transport = transports.get(sessionId)!;
      await transport.handleRequest(req, res);
      return;
    }

    // Create new session for POST without session ID (initialize request)
    if (req.method === "POST" && !sessionId) {
      const newSessionId = randomUUID();
      const transport = new StreamableHTTPServerTransport({
        sessionIdGenerator: () => newSessionId,
        onsessioninitialized: (id) => {
          transports.set(id, transport);
          log(`Session created: ${id}`);
        },
      });

      transport.onclose = () => {
        transports.delete(newSessionId);
        log(`Session closed: ${newSessionId}`);
      };

      try {
        await server.connect(transport);
        await transport.handleRequest(req, res);
      } catch (err) {
        // Clean up session on error
        transports.delete(newSessionId);
        log(`Session error and cleanup: ${newSessionId}`);
        throw err;
      }
      return;
    }

    // Handle GET requests for SSE - need session ID
    if (req.method === "GET") {
      res.status(400).json({
        jsonrpc: "2.0",
        error: {
          code: -32000,
          message: "Bad Request: GET requests require mcp-session-id header. Send POST with initialize request first.",
        },
        id: null,
      });
      return;
    }

    // Invalid request
    res.status(400).json({
      jsonrpc: "2.0",
      error: {
        code: -32000,
        message: "Bad Request: No valid session. Send an initialize request first.",
      },
      id: null,
    });
  };

  // MCP endpoint - handles both /mcp and /mcp/ (with authentication)
  app.all("/mcp", authenticateRequest, mcpHandler);
  app.all("/mcp/", authenticateRequest, mcpHandler);

  // Health check endpoint (no auth required)
  app.get("/health", (_req: Request, res: Response) => {
    const status = {
      status: "ok",
      server: "mobsf-mcp",
      version: "2.1.0",
      mobsf_url: MOBSF_URL,
      api_key_configured: !!MOBSF_API_KEY,
      auth_enabled: !!MCP_API_KEY,
      uptime: process.uptime(),
    };
    res.json(status);
  });

  // Server info endpoint (no auth required)
  app.get("/", (_req: Request, res: Response) => {
    res.json({
      name: "MobSF MCP Server",
      version: "2.1.0",
      description: "Model Context Protocol server for MobSF mobile security scanning",
      auth_required: !!MCP_API_KEY,
      endpoints: {
        mcp: "/mcp",
        health: "/health",
      },
      tools: ["scanFile", "scanFileBase64", "getReport", "listScans", "deleteScan"],
    });
  });

  const httpServer = app.listen(PORT, "0.0.0.0", () => {
    log(`MobSF MCP Server started on http://0.0.0.0:${PORT}`);
    console.log(`
╔══════════════════════════════════════════════════════════════╗
║           🛡️  MobSF MCP Server v2.1.0                        ║
╠══════════════════════════════════════════════════════════════╣
║  MCP Endpoint:    http://localhost:${PORT}/mcp                 ║
║  Health Check:    http://localhost:${PORT}/health              ║
║  MobSF URL:       ${MOBSF_URL.padEnd(40)}║
║  MobSF API Key:   ${MOBSF_API_KEY ? "✅ Configured".padEnd(40) : "❌ Not configured".padEnd(40)}║
║  Authentication:  ${MCP_API_KEY ? "🔐 Enabled (Bearer token)".padEnd(40) : "⚠️  Disabled".padEnd(40)}║
╚══════════════════════════════════════════════════════════════╝
`);
  });

  // Graceful shutdown handler
  const shutdown = async (signal: string) => {
    log(`Received ${signal}, shutting down gracefully...`);
    
    // Close all MCP sessions
    for (const [sessionId, transport] of transports.entries()) {
      log(`Closing session: ${sessionId}`);
      try {
        await transport.close();
      } catch (err) {
        log(`Error closing session ${sessionId}: ${err}`);
      }
    }
    transports.clear();
    
    // Close HTTP server
    httpServer.close(() => {
      log('HTTP server closed');
      process.exit(0);
    });
    
    // Force exit after 10 seconds
    setTimeout(() => {
      log('Forcing exit after timeout');
      process.exit(1);
    }, 10000);
  };

  process.on('SIGTERM', () => shutdown('SIGTERM'));
  process.on('SIGINT', () => shutdown('SIGINT'));
}

run().catch((err) => {
  log(`Fatal error: ${err.message}`);
  console.error("Fatal error:", err);
  process.exit(1);
});
