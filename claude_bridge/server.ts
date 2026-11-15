// Sure's Claude bridge.
//
// Runs Claude Code turns for Sure's chat on this Mac through the Agent SDK, signed in with
// the owner's own `claude auth login`. Sure (in Docker) reaches it at
// http://host.docker.internal:3339 with a shared bearer token and reads back one JSON
// object per line. Each turn gets only Sure's MCP endpoint, with a short-lived turn token,
// and no built-in tools. It listens on loopback only and serves nobody else.
//
// Run it with `bin/claude-bridge run` (foreground) or `bin/claude-bridge install` (LaunchAgent).
// Plain Node 24 with native type stripping: no build step, node:http only.
// See .claude/deploy.md, section "Claude bridge".

import { createHash, timingSafeEqual } from "node:crypto";
import { mkdirSync, readFileSync } from "node:fs";
import http from "node:http";
import type { IncomingMessage, ServerResponse } from "node:http";
import os from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";
import type {
  AccountInfo,
  HookCallback,
  McpServerConfig,
  McpSetServersResult,
  ModelInfo,
  Options,
  SDKControlGetUsageResponse,
  SDKControlInitializeResponse,
  SDKMessage,
  SDKRateLimitInfo,
  SDKResultMessage,
  SDKUserMessage,
} from "@anthropic-ai/claude-agent-sdk";

export const HOST = "127.0.0.1";
export const DEFAULT_PORT = 3339;
export const MAX_CONCURRENT_TURNS = 2;
export const MAX_TURNS = 16;
export const SURE_SERVER = "sure";
export const SURE_TOOL_PREFIX = `mcp__${SURE_SERVER}__`;

// Every built-in tool, refused a second time on top of `tools: []` and the PreToolUse hook.
export const BUILTIN_TOOLS = [
  "Agent",
  "AskUserQuestion",
  "Bash",
  "BashOutput",
  "Edit",
  "ExitPlanMode",
  "Glob",
  "Grep",
  "KillShell",
  "ListMcpResourcesTool",
  "MultiEdit",
  "NotebookEdit",
  "Read",
  "ReadMcpResourceTool",
  "Task",
  "TodoWrite",
  "WebFetch",
  "WebSearch",
  "Write",
];

// Sure's /mcp as seen from this Mac: production, development (bin/dev, bin/staging dev), staging.
export const DEFAULT_MCP_ALLOWLIST = [
  "http://localhost:3333/mcp",
  "http://127.0.0.1:3333/mcp",
  "http://localhost:3000/mcp",
  "http://127.0.0.1:3000/mcp",
  "http://localhost:3334/mcp",
  "http://127.0.0.1:3334/mcp",
];

export type Timing = {
  heartbeatMs: number;
  wallClockMs: number;
  coalesceMs: number;
  coalesceChars: number;
  healthTtlMs: number;
  modelsTtlMs: number;
  probeTimeoutMs: number;
  drainMs: number;
};

export const DEFAULT_TIMING: Timing = {
  heartbeatMs: 15_000,
  // Below AssistantMessage::STALE_AFTER (10 minutes), so Sure never reaps a turn the bridge still runs.
  wallClockMs: 8 * 60_000,
  coalesceMs: 100,
  coalesceChars: 200,
  healthTtlMs: 60_000,
  modelsTtlMs: 10 * 60_000,
  probeTimeoutMs: 20_000,
  drainMs: 10_000,
};

const MAX_BODY_BYTES = 4 * 1024 * 1024;
const TOOL_RESULT_CHARS = 8 * 1024;

export type ErrorCode =
  | "auth"
  | "usage_limit"
  | "overloaded"
  | "session_not_found"
  | "mcp_unavailable"
  | "timeout"
  | "budget"
  | "max_turns"
  | "busy"
  | "internal";

const RETRYABLE: Record<ErrorCode, boolean> = {
  auth: false,
  usage_limit: false,
  overloaded: true,
  session_not_found: false,
  mcp_unavailable: true,
  timeout: true,
  budget: false,
  max_turns: false,
  busy: true,
  internal: true,
};

export const AUTH_MESSAGE =
  "Claude is signed out on the Mac. Run `claude auth login` in a terminal there, then retry.";

export class TurnError extends Error {
  code: ErrorCode;
  resetAt: string | null;

  constructor(code: ErrorCode, message: string, resetAt: string | null = null) {
    super(message);
    this.code = code;
    this.resetAt = resetAt;
  }

  toEvent() {
    const event: Record<string, unknown> = {
      type: "error",
      code: this.code,
      message: this.message,
      retryable: RETRYABLE[this.code],
    };
    if (this.resetAt) event.reset_at = this.resetAt;
    return event;
  }
}

// The part of the SDK's Query that the bridge uses. Tests pass a fake with the same shape.
export type QueryLike = AsyncIterable<SDKMessage> & {
  initializationResult(): Promise<SDKControlInitializeResponse>;
  setMcpServers(servers: Record<string, McpServerConfig>): Promise<McpSetServersResult>;
  usage_EXPERIMENTAL_MAY_CHANGE_DO_NOT_RELY_ON_THIS_API_YET(opts?: {
    skipBehaviors?: boolean;
  }): Promise<SDKControlGetUsageResponse>;
  close(): void;
};

export type QueryFn = (params: {
  prompt: string | AsyncIterable<SDKUserMessage>;
  options?: Options;
}) => QueryLike;

export type BridgeConfig = {
  port: number;
  token: string;
  mcpAllowlist: string[];
  workDir: string;
};

export type BridgeDeps = {
  query: QueryFn;
  config: BridgeConfig;
  cliVersion: string;
  sdkVersion: string;
  minCliVersion: string;
  timing?: Partial<Timing>;
  env?: NodeJS.ProcessEnv;
  log?: (event: string, fields?: Record<string, unknown>) => void;
};

// ---------------------------------------------------------------------------------------
// Versions and configuration

export function compareVersions(a: string, b: string): number {
  const pa = a.split(/[.-]/).map((part) => Number.parseInt(part, 10) || 0);
  const pb = b.split(/[.-]/).map((part) => Number.parseInt(part, 10) || 0);
  for (let i = 0; i < Math.max(pa.length, pb.length); i++) {
    const diff = (pa[i] ?? 0) - (pb[i] ?? 0);
    if (diff !== 0) return diff < 0 ? -1 : 1;
  }
  return 0;
}

export function assertCliVersion(cliVersion: string, minCliVersion: string): void {
  if (!minCliVersion) {
    throw new Error("claude_bridge/package.json has no sure.minClaudeCodeVersion.");
  }
  if (!cliVersion || compareVersions(cliVersion, minCliVersion) < 0) {
    throw new Error(
      `The Agent SDK bundles Claude Code ${cliVersion || "(unknown)"}, older than ${minCliVersion}, ` +
        "the version that speaks MCP 2026-07-28 with Sure. Raise the @anthropic-ai/claude-agent-sdk pin " +
        "in claude_bridge/package.json, then run bin/claude-bridge install.",
    );
  }
}

const HERE = path.dirname(fileURLToPath(import.meta.url));

export function readVersions(dir = HERE): { sdk: string; cli: string; min: string } {
  const own = JSON.parse(readFileSync(path.join(dir, "package.json"), "utf8"));
  const min = String(own.sure?.minClaudeCodeVersion ?? "");
  let sdk = "";
  let cli = "";
  try {
    const pkg = JSON.parse(
      readFileSync(
        path.join(dir, "node_modules", "@anthropic-ai", "claude-agent-sdk", "package.json"),
        "utf8",
      ),
    );
    sdk = String(pkg.version ?? "");
    cli = String(pkg.claudeCodeVersion ?? "");
  } catch {
    // Not installed: reported by the caller.
  }
  return { sdk, cli, min };
}

export function loadConfig(env: NodeJS.ProcessEnv = process.env): BridgeConfig {
  const file =
    env.CLAUDE_BRIDGE_CONFIG ||
    path.join(os.homedir(), ".config", "sure-claude-bridge", "config.json");
  let raw: Record<string, unknown> = {};
  try {
    raw = JSON.parse(readFileSync(file, "utf8"));
  } catch (error) {
    if ((error as NodeJS.ErrnoException).code !== "ENOENT") throw error;
  }
  const token = String(env.CLAUDE_BRIDGE_TOKEN || raw.token || "");
  if (token.length < 32) {
    throw new Error(
      `No bridge token: run bin/claude-bridge install (it writes ${file}), or set CLAUDE_BRIDGE_TOKEN (32+ characters).`,
    );
  }
  const port = Number(env.CLAUDE_BRIDGE_PORT || raw.port || DEFAULT_PORT);
  const allowlist = Array.isArray(raw.mcp_allowlist)
    ? raw.mcp_allowlist.map(String)
    : DEFAULT_MCP_ALLOWLIST;
  const workDir = String(
    raw.work_dir ||
      path.join(os.homedir(), "Library", "Application Support", "sure-claude-bridge", "work"),
  );
  return { port, token, mcpAllowlist: allowlist, workDir };
}

// ---------------------------------------------------------------------------------------
// Small helpers

const LOOPBACK = new Set(["127.0.0.1", "::1", "::ffff:127.0.0.1"]);

export function isLoopback(address: string | undefined): boolean {
  return !!address && LOOPBACK.has(address);
}

export function tokenMatches(header: string | undefined, token: string): boolean {
  const match = /^Bearer (.+)$/.exec(header ?? "");
  if (!match) return false;
  // Hash both sides so the comparison is constant time whatever the lengths.
  const given = createHash("sha256").update(match[1]).digest();
  const expected = createHash("sha256").update(token).digest();
  return timingSafeEqual(given, expected);
}

function normalizeUrl(raw: string): string | null {
  let url: URL;
  try {
    url = new URL(raw);
  } catch {
    return null;
  }
  if (url.username || url.password || url.search || url.hash) return null;
  if (url.protocol !== "http:" && url.protocol !== "https:") return null;
  return `${url.protocol}//${url.host}${url.pathname}`;
}

export function mcpUrlAllowed(raw: unknown, allowlist: string[]): boolean {
  if (typeof raw !== "string") return false;
  const wanted = normalizeUrl(raw);
  return !!wanted && allowlist.some((entry) => normalizeUrl(entry) === wanted);
}

const STRIP_PREFIXES = ["ANTHROPIC_", "CLAUDE_CODE_", "CLAUDE_BRIDGE_"];
const STRIP_KEYS = new Set([
  "CLAUDECODE",
  "CLAUDE_EFFORT",
  "CLAUDE_AGENT_SDK_VERSION",
  "MCP_API_TOKEN",
  "OPENAI_ACCESS_TOKEN",
]);

// The environment for the Claude Code process. API keys, OAuth tokens and the variables of
// a Claude Code session this was started from would take priority over (or hijack) the
// owner's subscription login, so they go. CLAUDE_CONFIG_DIR stays: it selects the login.
export function cleanEnv(env: NodeJS.ProcessEnv): Record<string, string | undefined> {
  const out: Record<string, string | undefined> = {};
  for (const [key, value] of Object.entries(env)) {
    if (STRIP_KEYS.has(key)) continue;
    if (STRIP_PREFIXES.some((prefix) => key.startsWith(prefix))) continue;
    out[key] = value;
  }
  out.ENABLE_CLAUDEAI_MCP_SERVERS = "false";
  out.CLAUDE_AGENT_SDK_CLIENT_APP = "sure-claude-bridge";
  return out;
}

export function signedOut(account: AccountInfo | undefined): boolean {
  if (!account) return true;
  return (!account.tokenSource || account.tokenSource === "none") && !account.apiKeySource;
}

function isoFromEpochSeconds(seconds: number | undefined | null): string | null {
  return typeof seconds === "number" && Number.isFinite(seconds)
    ? new Date(seconds * 1000).toISOString()
    : null;
}

function truncate(text: string, max: number): string {
  return text.length > max ? `${text.slice(0, max)}\n[truncated]` : text;
}

function toolResultText(content: unknown): string {
  if (typeof content === "string") return content;
  if (!Array.isArray(content)) return content == null ? "" : JSON.stringify(content);
  return content
    .map((block) =>
      block && typeof block === "object" && (block as { type?: string }).type === "text"
        ? String((block as { text?: unknown }).text ?? "")
        : `[${(block as { type?: string })?.type ?? "content"}]`,
    )
    .join("\n");
}

// Only Sure's tools may run. `tools: []`, `allowedTools` and `dontAsk` already say so; this
// hook is the last word for anything that slips through (a plugin, a future built-in).
export const denyForeignTools: HookCallback = async (input) => {
  const name = (input as { tool_name?: string }).tool_name ?? "";
  if (name.startsWith(SURE_TOOL_PREFIX)) return {};
  return {
    hookSpecificOutput: {
      hookEventName: "PreToolUse",
      permissionDecision: "deny",
      permissionDecisionReason: "Only Sure's tools are available here.",
    },
  };
};

// The prompt stream for one query. The prompt goes in only after the MCP server is set,
// and closing it lets Claude Code exit once the turn is over.
class PromptInput implements AsyncIterable<SDKUserMessage> {
  #items: SDKUserMessage[] = [];
  #waiters: ((result: IteratorResult<SDKUserMessage>) => void)[] = [];
  #ended = false;

  push(message: SDKUserMessage) {
    if (this.#ended) return;
    const waiter = this.#waiters.shift();
    if (waiter) waiter({ value: message, done: false });
    else this.#items.push(message);
  }

  end() {
    this.#ended = true;
    for (const waiter of this.#waiters.splice(0)) waiter({ value: undefined, done: true });
  }

  [Symbol.asyncIterator](): AsyncIterator<SDKUserMessage> {
    return {
      next: () => {
        const item = this.#items.shift();
        if (item) return Promise.resolve({ value: item, done: false });
        if (this.#ended) return Promise.resolve({ value: undefined, done: true });
        return new Promise((resolve) => this.#waiters.push(resolve));
      },
      return: () => {
        this.end();
        return Promise.resolve({ value: undefined, done: true });
      },
    };
  }
}

function userMessage(text: string): SDKUserMessage {
  return {
    type: "user",
    message: { role: "user", content: text },
    parent_tool_use_id: null,
  } as SDKUserMessage;
}

function withTimeout<T>(promise: Promise<T>, ms: number, what: string): Promise<T> {
  let timer: NodeJS.Timeout | undefined;
  const timeout = new Promise<never>((_, reject) => {
    timer = setTimeout(() => reject(new Error(`${what} timed out`)), ms);
  });
  return Promise.race([promise, timeout]).finally(() => clearTimeout(timer));
}

function untilAborted<T>(promise: Promise<T>, signal: AbortSignal): Promise<T> {
  if (signal.aborted) return Promise.reject(new Error("aborted"));
  return new Promise<T>((resolve, reject) => {
    const onAbort = () => reject(new Error("aborted"));
    signal.addEventListener("abort", onAbort, { once: true });
    promise.then(
      (value) => {
        signal.removeEventListener("abort", onAbort);
        resolve(value);
      },
      (error) => {
        signal.removeEventListener("abort", onAbort);
        reject(error);
      },
    );
  });
}

function writeJson(res: ServerResponse, status: number, body: unknown) {
  if (res.headersSent) return;
  res.writeHead(status, {
    "content-type": "application/x-ndjson; charset=utf-8",
    "cache-control": "no-store",
  });
  res.end(`${JSON.stringify(body)}\n`);
}

function requestError(res: ServerResponse, status: number, code: string, message: string) {
  writeJson(res, status, { type: "error", code, message, retryable: false });
}

async function readBody(req: IncomingMessage): Promise<string> {
  const chunks: Buffer[] = [];
  let size = 0;
  for await (const chunk of req) {
    size += (chunk as Buffer).length;
    if (size > MAX_BODY_BYTES) throw new Error("too_large");
    chunks.push(chunk as Buffer);
  }
  return Buffer.concat(chunks).toString("utf8");
}

// ---------------------------------------------------------------------------------------
// Error classification

export function classifyResult(
  result: SDKResultMessage,
  context: { lastRateLimit: SDKRateLimitInfo | null; assistantError: string | null },
): TurnError {
  const resultText = result.subtype === "success" ? result.result : "";
  const errors = "errors" in result && Array.isArray(result.errors) ? result.errors : [];
  const text = [resultText, ...errors].filter(Boolean).join(" ").trim();
  const status = (result as { api_error_status?: number | null }).api_error_status ?? null;
  const terminal = (result as { terminal_reason?: string }).terminal_reason;
  const assistantError = context.assistantError;

  if (/no conversation found/i.test(text)) {
    return new TurnError("session_not_found", "The earlier Claude conversation was not found.");
  }
  if (status === 429 || assistantError === "rate_limit") {
    return usageLimitError(context.lastRateLimit);
  }
  if (status === 529 || assistantError === "overloaded") {
    return new TurnError("overloaded", "Claude is overloaded right now. Try again in a minute.");
  }
  if (
    status === 401 ||
    status === 403 ||
    assistantError === "authentication_failed" ||
    assistantError === "oauth_org_not_allowed"
  ) {
    return new TurnError("auth", AUTH_MESSAGE);
  }
  if (result.subtype === "error_max_turns" || terminal === "max_turns") {
    return new TurnError("max_turns", `Claude used all ${MAX_TURNS} tool rounds without finishing.`);
  }
  if (result.subtype === "error_max_budget_usd" || terminal === "budget_exhausted") {
    return new TurnError("budget", "The turn hit its spending cap.");
  }
  return new TurnError(
    "internal",
    `Claude Code stopped: ${truncate(text || result.subtype, 300).replace(/\s+/g, " ")}`,
  );
}

export function usageLimitError(info: SDKRateLimitInfo | null): TurnError {
  const resetAt = isoFromEpochSeconds(info?.resetsAt);
  const window = info?.rateLimitType ? ` (${info.rateLimitType.replace(/_/g, " ")} window)` : "";
  return new TurnError("usage_limit", `Claude usage limit reached${window}.`, resetAt);
}

function classifyThrown(error: unknown): TurnError {
  if (error instanceof TurnError) return error;
  const message = error instanceof Error ? error.message : String(error);
  if (/no conversation found/i.test(message)) {
    return new TurnError("session_not_found", "The earlier Claude conversation was not found.");
  }
  if (/not logged in|auth(entication)? (failed|required)|claude auth login|\/login/i.test(message)) {
    return new TurnError("auth", AUTH_MESSAGE);
  }
  const firstLine = message.split("\n")[0] ?? "";
  return new TurnError("internal", `Claude Code failed: ${truncate(firstLine, 200)}`);
}

// ---------------------------------------------------------------------------------------
// The bridge

type TurnRequest = {
  turn_id?: string | number;
  model?: string;
  system_prompt?: string;
  prompt?: string;
  resume_session_id?: string | null;
  mcp?: { url?: string; token?: string };
  limits?: { max_turns?: number; timeout_s?: number };
};

type ProbeResult = {
  account: AccountInfo;
  models: ModelInfo[];
  usage: Record<string, unknown> | null;
  at: number;
};

export function createBridge(deps: BridgeDeps) {
  assertCliVersion(deps.cliVersion, deps.minCliVersion);

  const timing: Timing = { ...DEFAULT_TIMING, ...deps.timing };
  const config = deps.config;
  const env = deps.env ?? process.env;
  const log =
    deps.log ??
    ((event: string, fields: Record<string, unknown> = {}) => {
      console.log(JSON.stringify({ ts: new Date().toISOString(), event, ...fields }));
    });
  mkdirSync(config.workDir, { recursive: true });

  let activeTurns = 0;
  const running = new Set<() => void>();
  let probeCache: ProbeResult | null = null;
  let probeInFlight: Promise<ProbeResult> | null = null;

  function baseOptions(abortController: AbortController): Options {
    return {
      abortController,
      cwd: config.workDir,
      env: cleanEnv(env),
      tools: [],
      disallowedTools: BUILTIN_TOOLS,
      strictMcpConfig: true,
      settingSources: [],
    };
  }

  // ---- /health and /models: one query that never sends a prompt, so nothing reaches the model.

  async function runProbe(): Promise<ProbeResult> {
    const abortController = new AbortController();
    const prompt = (async function* (): AsyncGenerator<SDKUserMessage> {
      await new Promise((resolve) =>
        abortController.signal.addEventListener("abort", resolve, { once: true }),
      );
    })();
    const q = deps.query({
      prompt,
      options: {
        ...baseOptions(abortController),
        persistSession: false,
        allowedTools: [],
        mcpServers: {},
        settings: { disableAllHooks: true },
      },
    });
    try {
      const init = await withTimeout(q.initializationResult(), timing.probeTimeoutMs, "probe");
      let usage: Record<string, unknown> | null = null;
      if (!signedOut(init.account)) {
        try {
          const raw = await withTimeout(
            q.usage_EXPERIMENTAL_MAY_CHANGE_DO_NOT_RELY_ON_THIS_API_YET({ skipBehaviors: true }),
            timing.probeTimeoutMs,
            "usage",
          );
          usage = normalizeUsage(raw);
        } catch {
          // The usage call is experimental: no windows is fine, a broken health check is not.
          usage = null;
        }
      }
      return { account: init.account ?? {}, models: init.models ?? [], usage, at: Date.now() };
    } finally {
      abortController.abort();
      try {
        q.close();
      } catch {
        // already gone
      }
    }
  }

  function probe(maxAgeMs: number): Promise<ProbeResult> {
    if (probeCache && Date.now() - probeCache.at < maxAgeMs) return Promise.resolve(probeCache);
    if (!probeInFlight) {
      probeInFlight = runProbe()
        .then((result) => {
          probeCache = result;
          return result;
        })
        .finally(() => {
          probeInFlight = null;
        });
    }
    return probeInFlight;
  }

  async function handleHealth(res: ServerResponse) {
    const base = {
      cli_version: deps.cliVersion,
      sdk_version: deps.sdkVersion,
      min_cli_version: deps.minCliVersion,
      active_turns: activeTurns,
      max_concurrent_turns: MAX_CONCURRENT_TURNS,
    };
    try {
      const result = await probe(timing.healthTtlMs);
      const account = result.account;
      const isSignedOut = signedOut(account);
      writeJson(res, 200, {
        ok: !isSignedOut,
        signed_in: !isSignedOut,
        account: {
          email: account.email ?? null,
          organization: account.organization ?? null,
          plan: account.subscriptionType ?? null,
          token_source: account.tokenSource ?? null,
          api_provider: account.apiProvider ?? null,
        },
        plan: account.subscriptionType ?? null,
        token_source: account.tokenSource ?? null,
        usage: result.usage,
        checked_at: new Date(result.at).toISOString(),
        ...base,
        ...(isSignedOut ? { error: { code: "auth", message: AUTH_MESSAGE } } : {}),
      });
    } catch (error) {
      log("health_failed", { error: (error as Error).name });
      writeJson(res, 200, {
        ok: false,
        signed_in: null,
        ...base,
        error: classifyThrown(error).toEvent(),
      });
    }
  }

  async function handleModels(res: ServerResponse) {
    try {
      const result = await probe(timing.modelsTtlMs);
      writeJson(res, 200, {
        models: result.models.map((model) => ({
          value: model.value,
          display_name: model.displayName,
          description: model.description,
          resolved_model: model.resolvedModel ?? null,
        })),
        checked_at: new Date(result.at).toISOString(),
      });
    } catch (error) {
      writeJson(res, 502, classifyThrown(error).toEvent());
    }
  }

  // ---- POST /turn

  async function handleTurn(req: IncomingMessage, res: ServerResponse) {
    let body: TurnRequest;
    try {
      body = JSON.parse(await readBody(req));
    } catch (error) {
      if ((error as Error).message === "too_large") {
        return requestError(res, 413, "bad_request", "The request body is too large.");
      }
      return requestError(res, 400, "bad_request", "The request body is not valid JSON.");
    }
    if (!body || typeof body !== "object") {
      return requestError(res, 400, "bad_request", "The request body must be a JSON object.");
    }
    if (typeof body.prompt !== "string" || body.prompt.trim() === "") {
      return requestError(res, 400, "bad_request", "prompt is required.");
    }
    if (typeof body.model !== "string" || body.model.trim() === "") {
      return requestError(res, 400, "bad_request", "model is required.");
    }
    if (typeof body.mcp?.token !== "string" || body.mcp.token === "") {
      return requestError(res, 400, "bad_request", "mcp.token is required.");
    }
    if (!mcpUrlAllowed(body.mcp?.url, config.mcpAllowlist)) {
      return requestError(
        res,
        400,
        "mcp_url_not_allowed",
        "mcp.url is not one of Sure's local MCP endpoints.",
      );
    }
    if (activeTurns >= MAX_CONCURRENT_TURNS) {
      return writeJson(
        res,
        429,
        new TurnError(
          "busy",
          `Claude is already answering ${MAX_CONCURRENT_TURNS} messages. Try again when one finishes.`,
        ).toEvent(),
      );
    }

    activeTurns++;
    try {
      await runTurn(body, res);
    } finally {
      activeTurns--;
    }
  }

  async function runTurn(body: TurnRequest, res: ServerResponse) {
    const turnId = String(body.turn_id ?? "").slice(0, 64) || null;
    const startedAt = Date.now();
    const abortController = new AbortController();
    const input = new PromptInput();
    const maxTurns = Math.min(Math.max(Number(body.limits?.max_turns) || MAX_TURNS, 1), MAX_TURNS);
    const wallClockMs = Math.min(
      Number(body.limits?.timeout_s) > 0 ? Number(body.limits?.timeout_s) * 1000 : timing.wallClockMs,
      timing.wallClockMs,
    );
    const resume =
      typeof body.resume_session_id === "string" && body.resume_session_id
        ? body.resume_session_id
        : null;

    let q: QueryLike | null = null;
    let done = false; // a result or an error has been sent
    let outcome = "ok";
    let errorCode: string | null = null;
    let textBuffer = "";
    let textTimer: NodeJS.Timeout | null = null;
    let anyText = false;
    let model: string | null = null;
    let lastRateLimit: SDKRateLimitInfo | null = null;
    let assistantError: string | null = null;
    let numTurns: number | null = null;

    res.writeHead(200, {
      "content-type": "application/x-ndjson; charset=utf-8",
      "cache-control": "no-store",
      "x-accel-buffering": "no",
    });
    res.flushHeaders();

    const send = (event: Record<string, unknown>) => {
      if (!res.writableEnded && !res.destroyed) res.write(`${JSON.stringify(event)}\n`);
    };

    const flushText = () => {
      if (textTimer) {
        clearTimeout(textTimer);
        textTimer = null;
      }
      if (textBuffer) {
        send({ type: "text", delta: textBuffer });
        textBuffer = "";
      }
    };

    const addText = (delta: string) => {
      if (!delta) return;
      anyText = true;
      textBuffer += delta;
      if (textBuffer.length >= timing.coalesceChars) flushText();
      else if (!textTimer) textTimer = setTimeout(flushText, timing.coalesceMs);
    };

    const stopQuery = () => {
      abortController.abort();
      input.end();
      try {
        q?.close();
      } catch {
        // already gone
      }
    };

    // Ends the turn with an error (sent only if Sure is still listening) and stops Claude Code.
    const fail = (error: TurnError) => {
      if (done) return;
      done = true;
      outcome = "error";
      errorCode = error.code;
      flushText();
      send(error.toEvent());
      res.end();
      stopQuery();
    };

    running.add(stopQuery);
    const heartbeat = setInterval(() => send({ type: "heartbeat" }), timing.heartbeatMs);
    const wallClock = setTimeout(
      () =>
        fail(
          new TurnError(
            "timeout",
            `The turn ran longer than ${Math.round(wallClockMs / 60_000)} minutes and was stopped.`,
          ),
        ),
      wallClockMs,
    );
    // Sure went away (job killed, deploy): stop spending the subscription on nobody.
    res.on("close", () => {
      if (!res.writableFinished && !done) {
        done = true;
        outcome = "disconnected";
        stopQuery();
      }
    });

    const finishWithResult = (result: SDKResultMessage) => {
      if (done) return;
      if (result.subtype === "success" && !result.is_error) {
        if (!anyText && result.result?.trim()) addText(result.result);
        flushText();
        done = true;
        numTurns = result.num_turns;
        // `usage` covers this turn only. `total_cost_usd` and `model_usage` continue from the
        // totals of the session this turn resumed, so they include earlier turns: price a turn
        // from `usage`.
        send({
          type: "result",
          session_id: result.session_id,
          model: model ?? Object.keys(result.modelUsage ?? {})[0] ?? body.model,
          usage: result.usage,
          model_usage: result.modelUsage,
          total_cost_usd: result.total_cost_usd,
          num_turns: result.num_turns,
          duration_ms: result.duration_ms,
          stop_reason: result.stop_reason,
        });
        res.end();
        // Let Claude Code finish writing the session, then make sure it is gone.
        input.end();
        setTimeout(stopQuery, timing.drainMs).unref();
      } else {
        numTurns = result.num_turns;
        fail(classifyResult(result, { lastRateLimit, assistantError }));
      }
    };

    const handle = (message: SDKMessage) => {
      switch (message.type) {
        case "system": {
          if (message.subtype === "init") {
            model = message.model;
            send({ type: "session", session_id: message.session_id, model: message.model });
          } else if (
            message.subtype === "api_retry" &&
            (message as { error?: string }).error === "authentication_failed"
          ) {
            fail(new TurnError("auth", AUTH_MESSAGE));
          }
          break;
        }
        case "stream_event": {
          if (message.parent_tool_use_id !== null) break;
          const event = message.event as { type: string; delta?: { type?: string; text?: string } };
          if (event.type === "content_block_delta" && event.delta?.type === "text_delta") {
            addText(event.delta.text ?? "");
          }
          break;
        }
        case "assistant": {
          if (message.parent_tool_use_id !== null) break;
          if (message.error) assistantError = message.error;
          for (const block of message.message.content ?? []) {
            if (block.type === "tool_use") {
              flushText();
              send({ type: "tool", id: block.id, name: block.name, input: block.input });
            }
          }
          break;
        }
        case "user": {
          if (message.parent_tool_use_id !== null) break;
          const content = message.message.content;
          if (!Array.isArray(content)) break;
          for (const block of content) {
            if (block.type === "tool_result") {
              send({
                type: "tool_result",
                id: block.tool_use_id,
                is_error: block.is_error === true,
                content: truncate(toolResultText(block.content), TOOL_RESULT_CHARS),
              });
            }
          }
          break;
        }
        case "rate_limit_event": {
          const info = message.rate_limit_info;
          lastRateLimit = info;
          send({
            type: "rate_limit",
            kind: info.rateLimitType ?? null,
            utilization: info.utilization ?? null,
            resets_at: isoFromEpochSeconds(info.resetsAt),
            status: info.status,
          });
          // Claude Code would otherwise sit and wait for the window to reopen.
          if (info.status === "rejected") fail(usageLimitError(info));
          break;
        }
        case "result": {
          finishWithResult(message);
          break;
        }
        default:
          break;
      }
    };

    log("turn_start", { turn_id: turnId, model: body.model, resume: !!resume });
    try {
      const options: Options = {
        ...baseOptions(abortController),
        model: body.model,
        allowedTools: [`${SURE_TOOL_PREFIX}*`],
        permissionMode: "dontAsk",
        hooks: { PreToolUse: [{ hooks: [denyForeignTools] }] },
        includePartialMessages: true,
        persistSession: true,
        maxTurns,
        ...(typeof body.system_prompt === "string" && body.system_prompt
          ? { systemPrompt: body.system_prompt }
          : {}),
        ...(resume ? { resume, forkSession: true } : {}),
      };
      q = deps.query({ prompt: input, options });

      const init = await untilAborted(q.initializationResult(), abortController.signal);
      if (signedOut(init.account)) throw new TurnError("auth", AUTH_MESSAGE);

      // Sent over stdin, so the turn token never shows up in the process list.
      const servers = await untilAborted(
        q.setMcpServers({
          [SURE_SERVER]: {
            type: "http",
            url: body.mcp?.url as string,
            headers: { Authorization: `Bearer ${body.mcp?.token}` },
            timeout: 60_000,
          },
        }),
        abortController.signal,
      );
      const mcpError = servers?.errors?.[SURE_SERVER];
      if (mcpError) {
        throw new TurnError(
          "mcp_unavailable",
          `Claude could not reach Sure's MCP endpoint: ${truncate(String(mcpError), 200)}`,
        );
      }

      input.push(userMessage(body.prompt as string));
      for await (const message of q) {
        if (done && outcome !== "ok") break;
        handle(message);
      }
      if (!done) throw new TurnError("internal", "Claude Code ended without finishing the turn.");
    } catch (error) {
      if (!done) fail(classifyThrown(error));
    } finally {
      running.delete(stopQuery);
      clearInterval(heartbeat);
      clearTimeout(wallClock);
      if (textTimer) clearTimeout(textTimer);
      if (!res.writableEnded) res.end();
      if (outcome !== "ok") stopQuery();
      log("turn_end", {
        turn_id: turnId,
        outcome,
        code: errorCode,
        num_turns: numTurns,
        duration_ms: Date.now() - startedAt,
      });
    }
  }

  // ---- HTTP

  const server = http.createServer(async (req, res) => {
    if (!isLoopback(req.socket.remoteAddress)) {
      req.socket.destroy();
      return;
    }
    if (!tokenMatches(req.headers.authorization, config.token)) {
      return requestError(res, 401, "unauthorized", "Missing or wrong bridge token.");
    }
    const url = new URL(req.url ?? "/", "http://bridge");
    try {
      if (req.method === "GET" && url.pathname === "/health") return await handleHealth(res);
      if (req.method === "GET" && url.pathname === "/models") return await handleModels(res);
      if (req.method === "POST" && url.pathname === "/turn") return await handleTurn(req, res);
      return requestError(res, 404, "not_found", "Unknown endpoint.");
    } catch (error) {
      log("request_failed", { path: url.pathname, error: (error as Error).name });
      if (!res.headersSent) requestError(res, 500, "internal", "The bridge failed.");
      else res.end();
    }
  });
  // Refuse anything that is not this Mac before a byte is read.
  server.on("connection", (socket) => {
    if (!isLoopback(socket.remoteAddress)) socket.destroy();
  });
  server.requestTimeout = 0; // turns stream for minutes
  server.headersTimeout = 10_000;

  return {
    server,
    get activeTurns() {
      return activeTurns;
    },
    closeAll() {
      for (const stop of running) stop();
      server.closeAllConnections();
    },
  };
}

function normalizeUsage(raw: SDKControlGetUsageResponse): Record<string, unknown> | null {
  if (!raw?.rate_limits_available || !raw.rate_limits) {
    return { available: false };
  }
  const windows: Record<string, unknown> = { available: true };
  for (const [name, window] of Object.entries(raw.rate_limits)) {
    if (!window || typeof window !== "object") continue;
    const { utilization, resets_at } = window as {
      utilization: number | null;
      resets_at: string | null;
    };
    // The usage endpoint reports percent; rate_limit events report 0-1. Sure gets 0-1 from both.
    windows[name] = {
      utilization: typeof utilization === "number" ? utilization / 100 : null,
      resets_at: resets_at ?? null,
    };
  }
  return windows;
}

// ---------------------------------------------------------------------------------------
// Entry point

async function main(argv: string[]) {
  const versions = readVersions();
  if (argv.includes("--versions")) {
    if (!versions.cli) {
      console.log("The Agent SDK is not installed: run bin/claude-bridge install.");
      process.exit(1);
    }
    const ok = compareVersions(versions.cli, versions.min) >= 0;
    console.log(
      `Agent SDK ${versions.sdk}, bundled Claude Code ${versions.cli} (needs ${versions.min} or newer)${ok ? "" : ": too old"}`,
    );
    process.exit(ok ? 0 : 1);
  }

  if (!versions.cli) {
    throw new Error("The Agent SDK is not installed in claude_bridge/: run bin/claude-bridge install.");
  }
  const config = loadConfig();
  console.log(
    JSON.stringify({
      ts: new Date().toISOString(),
      event: "starting",
      sdk_version: versions.sdk,
      cli_version: versions.cli,
      min_cli_version: versions.min,
      port: config.port,
    }),
  );
  const { query } = await import("@anthropic-ai/claude-agent-sdk");
  const bridge = createBridge({
    query: query as unknown as QueryFn,
    config,
    cliVersion: versions.cli,
    sdkVersion: versions.sdk,
    minCliVersion: versions.min,
  });
  bridge.server.listen(config.port, HOST, () => {
    console.log(
      JSON.stringify({ ts: new Date().toISOString(), event: "listening", host: HOST, port: config.port }),
    );
  });
  const shutdown = () => {
    bridge.server.close();
    bridge.closeAll();
    setTimeout(() => process.exit(0), 2000).unref();
  };
  process.on("SIGTERM", shutdown);
  process.on("SIGINT", shutdown);
}

if (import.meta.main) {
  main(process.argv.slice(2)).catch((error) => {
    console.error(error instanceof Error ? error.message : String(error));
    process.exit(1);
  });
}
