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
import { randomUUID } from "crypto";

// ESM compatibility
const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);

// Load environment variables
dotenv.config({ path: path.resolve(__dirname, ".env") });

// Configuration
const MOBSF_URL = process.env.MOBSF_URL || "http://localhost:8000";
const MOBSF_API_KEY = process.env.MOBSF_API_KEY || "";
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
  const ext = path.extname(filePath).toLowerCase();
  const scanType = ext === ".apk" ? "apk" : ext === ".ipa" ? "ios" : null;

  if (!scanType) {
    return {
      isError: true,
      content: [{ type: "text", text: "Unsupported file type. Must be .apk or .ipa" }],
    };
  }

  if (!fs.existsSync(filePath)) {
    return {
      isError: true,
      content: [{ type: "text", text: `File not found: ${filePath}` }],
    };
  }

  try {
    log(`Uploading file from path: ${filePath}`);
    return await uploadAndScan(filePath, scanType);
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
    const tempPath = path.join(UPLOAD_DIR, `${randomUUID()}_${filename}`);
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
  });

  // Get report
  const reportForm = new URLSearchParams();
  reportForm.append("hash", hash);

  const reportRes = await axios.post(`${MOBSF_URL}/api/v1/report_json`, reportForm.toString(), {
    headers: {
      Authorization: MOBSF_API_KEY,
      "Content-Type": "application/x-www-form-urlencoded",
    },
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
        description: "Scan an APK or IPA file from a local file path. The file must exist on the server's filesystem.",
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
  log(`Tool call: ${name} with args: ${JSON.stringify(args)}`);

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

async function run() {
  const app = express();

  // MCP endpoint - handles Streamable HTTP protocol
  app.all("/mcp", async (req: Request, res: Response) => {
    const sessionId = req.headers["mcp-session-id"] as string | undefined;

    // Reuse existing session
    if (sessionId && transports.has(sessionId)) {
      const transport = transports.get(sessionId)!;
      await transport.handleRequest(req, res);
      return;
    }

    // Create new session for POST without session ID
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

    // Invalid request
    res.status(400).json({
      jsonrpc: "2.0",
      error: {
        code: -32000,
        message: "Bad Request: No valid session. Send an initialize request first.",
      },
      id: null,
    });
  });

  // Health check endpoint
  app.get("/health", (_req: Request, res: Response) => {
    const status = {
      status: "ok",
      server: "mobsf-mcp",
      version: "2.1.0",
      mobsf_url: MOBSF_URL,
      api_key_configured: !!MOBSF_API_KEY,
      uptime: process.uptime(),
    };
    res.json(status);
  });

  // Server info endpoint
  app.get("/", (_req: Request, res: Response) => {
    res.json({
      name: "MobSF MCP Server",
      version: "2.1.0",
      description: "Model Context Protocol server for MobSF mobile security scanning",
      endpoints: {
        mcp: "/mcp",
        health: "/health",
      },
      tools: ["scanFile", "scanFileBase64", "getReport", "listScans", "deleteScan"],
    });
  });

  app.listen(PORT, "0.0.0.0", () => {
    log(`MobSF MCP Server started on http://0.0.0.0:${PORT}`);
    console.log(`
╔══════════════════════════════════════════════════════════════╗
║           🛡️  MobSF MCP Server v2.1.0                        ║
╠══════════════════════════════════════════════════════════════╣
║  MCP Endpoint:    http://localhost:${PORT}/mcp                 ║
║  Health Check:    http://localhost:${PORT}/health              ║
║  MobSF URL:       ${MOBSF_URL.padEnd(40)}║
║  API Key:         ${MOBSF_API_KEY ? "Configured ✓".padEnd(40) : "Not configured ✗".padEnd(40)}║
╚══════════════════════════════════════════════════════════════╝
`);
  });
}

run().catch((err) => {
  log(`Fatal error: ${err.message}`);
  console.error("Fatal error:", err);
  process.exit(1);
});
