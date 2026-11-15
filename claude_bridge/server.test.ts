// Tests for the bridge with a fake query(): no Claude Code process, no network beyond loopback.
// Run: node --test 'claude_bridge/*.test.ts'

import assert from "node:assert/strict";
import { mkdtempSync } from "node:fs";
import http from "node:http";
import type { AddressInfo } from "node:net";
import os from "node:os";
import path from "node:path";
import { afterEach, describe, test } from "node:test";
import type { SDKMessage } from "@anthropic-ai/claude-agent-sdk";
import {
  assertCliVersion,
  cleanEnv,
  compareVersions,
  createBridge,
  denyForeignTools,
  isLoopback,
  mcpUrlAllowed,
  tokenMatches,
} from "./server.ts";
import type { QueryFn, Timing } from "./server.ts";

const TOKEN = "t".repeat(64);
const MCP_URL = "http://localhost:3333/mcp";
const TURN_TOKEN = "turn-token-123";

type Script = (ctx: { signal: AbortSignal }) => AsyncGenerator<SDKMessage>;

type FakeOptions = {
  account?: Record<string, unknown>;
  mcpErrors?: Record<string, string>;
  usage?: unknown;
};

type Call = {
  params: Parameters<QueryFn>[0];
  mcpServers: Record<string, unknown> | null;
  prompts: unknown[];
  closed: boolean;
  aborted: () => boolean;
};

function fakeQuery(script: Script, fake: FakeOptions = {}) {
  const calls: Call[] = [];
  const fn = ((params) => {
    const signal = params.options?.abortController?.signal as AbortSignal;
    const call: Call = {
      params,
      mcpServers: null,
      prompts: [],
      closed: false,
      aborted: () => signal.aborted,
    };
    calls.push(call);
    const generator = (async function* () {
      if (typeof params.prompt !== "string") {
        const iterator = params.prompt[Symbol.asyncIterator]();
        const first = await iterator.next();
        if (first.done) return;
        call.prompts.push(first.value);
      }
      yield* script({ signal });
    })();
    return Object.assign(generator, {
      initializationResult: async () =>
        ({
          account: fake.account ?? {
            email: "owner@example.com",
            subscriptionType: "max",
            tokenSource: "claude.ai",
            apiProvider: "firstParty",
          },
          models: [
            { value: "sonnet", displayName: "Sonnet", description: "Everyday", resolvedModel: "claude-sonnet-5-5" },
          ],
        }) as never,
      setMcpServers: async (servers: Record<string, unknown>) => {
        call.mcpServers = servers;
        return { added: Object.keys(servers), removed: [], errors: fake.mcpErrors ?? {} };
      },
      usage_EXPERIMENTAL_MAY_CHANGE_DO_NOT_RELY_ON_THIS_API_YET: async () =>
        (fake.usage ?? {
          rate_limits_available: true,
          subscription_type: "max",
          rate_limits: {
            five_hour: { utilization: 42, resets_at: "2026-11-15T15:00:00Z" },
            seven_day: { utilization: 10, resets_at: "2026-11-20T09:00:00Z" },
          },
        }) as never,
      close: () => {
        call.closed = true;
      },
    });
  }) as QueryFn;
  return { fn, calls };
}

// ---- SDK message builders

const init = (sessionId = "sess-new") =>
  ({ type: "system", subtype: "init", session_id: sessionId, model: "claude-sonnet-5-5" }) as unknown as SDKMessage;

const delta = (text: string) =>
  ({
    type: "stream_event",
    parent_tool_use_id: null,
    session_id: "sess-new",
    event: { type: "content_block_delta", index: 0, delta: { type: "text_delta", text } },
  }) as unknown as SDKMessage;

const toolUse = (id: string, name: string, input: unknown) =>
  ({
    type: "assistant",
    parent_tool_use_id: null,
    session_id: "sess-new",
    message: { content: [{ type: "tool_use", id, name, input }] },
  }) as unknown as SDKMessage;

const toolResult = (id: string, content: unknown, isError = false) =>
  ({
    type: "user",
    parent_tool_use_id: null,
    session_id: "sess-new",
    message: { role: "user", content: [{ type: "tool_result", tool_use_id: id, content, is_error: isError }] },
  }) as unknown as SDKMessage;

const rateLimit = (status: string, resetsAt = 1_763_222_400) =>
  ({
    type: "rate_limit_event",
    session_id: "sess-new",
    rate_limit_info: { status, resetsAt, rateLimitType: "five_hour", utilization: 1 },
  }) as unknown as SDKMessage;

const success = (overrides: Record<string, unknown> = {}) =>
  ({
    type: "result",
    subtype: "success",
    is_error: false,
    result: "Hello",
    session_id: "sess-new",
    num_turns: 2,
    duration_ms: 1234,
    stop_reason: "end_turn",
    total_cost_usd: 0.012,
    usage: { input_tokens: 10, output_tokens: 5, cache_read_input_tokens: 100, cache_creation_input_tokens: 20 },
    modelUsage: { "claude-sonnet-5-5": { inputTokens: 10, outputTokens: 5 } },
    ...overrides,
  }) as unknown as SDKMessage;

const sleep = (ms: number) => new Promise((resolve) => setTimeout(resolve, ms));

const untilAborted = (signal: AbortSignal) =>
  new Promise<void>((resolve) => {
    if (signal.aborted) resolve();
    else signal.addEventListener("abort", () => resolve(), { once: true });
  });

// ---- server harness

const servers: http.Server[] = [];

afterEach(() => {
  for (const server of servers.splice(0)) {
    server.closeAllConnections();
    server.close();
  }
});

async function start(
  fn: QueryFn,
  extra: { timing?: Partial<Timing>; cliVersion?: string; env?: NodeJS.ProcessEnv } = {},
) {
  const workDir = mkdtempSync(path.join(os.tmpdir(), "claude-bridge-test-"));
  const logs: { event: string; fields: Record<string, unknown> }[] = [];
  const bridge = createBridge({
    query: fn,
    config: { port: 0, token: TOKEN, mcpAllowlist: [MCP_URL], workDir },
    cliVersion: extra.cliVersion ?? "2.1.325",
    sdkVersion: "0.3.325",
    minCliVersion: "2.1.325",
    timing: { coalesceMs: 20, drainMs: 10, ...extra.timing },
    env: extra.env ?? { PATH: "/usr/bin" },
    log: (event, fields = {}) => logs.push({ event, fields }),
  });
  await new Promise<void>((resolve) => bridge.server.listen(0, "127.0.0.1", resolve));
  servers.push(bridge.server);
  const port = (bridge.server.address() as AddressInfo).port;
  return { bridge, port, logs };
}

type Reply = { status: number; lines: Record<string, unknown>[] };

function request(
  port: number,
  method: string,
  pathname: string,
  body?: unknown,
  token = TOKEN,
  onLine?: (line: Record<string, unknown>, req: http.ClientRequest) => void,
): Promise<Reply> {
  return new Promise((resolve, reject) => {
    const req = http.request(
      {
        host: "127.0.0.1",
        port,
        method,
        path: pathname,
        headers: { authorization: `Bearer ${token}`, "content-type": "application/json" },
      },
      (res) => {
        const lines: Record<string, unknown>[] = [];
        let buffer = "";
        res.setEncoding("utf8");
        res.on("data", (chunk: string) => {
          buffer += chunk;
          let index = buffer.indexOf("\n");
          while (index >= 0) {
            const line = JSON.parse(buffer.slice(0, index));
            lines.push(line);
            onLine?.(line, req);
            buffer = buffer.slice(index + 1);
            index = buffer.indexOf("\n");
          }
        });
        const done = () => resolve({ status: res.statusCode ?? 0, lines });
        res.on("end", done);
        res.on("error", done);
        res.on("close", done);
      },
    );
    req.on("error", (error) => {
      if ((error as NodeJS.ErrnoException).code === "ECONNRESET") resolve({ status: 0, lines: [] });
      else reject(error);
    });
    if (body !== undefined) req.write(JSON.stringify(body));
    req.end();
  });
}

const turnBody = (extra: Record<string, unknown> = {}) => ({
  turn_id: "msg-1",
  model: "sonnet",
  system_prompt: "You are Sure's assistant.",
  prompt: "What did I spend on groceries?",
  mcp: { url: MCP_URL, token: TURN_TOKEN },
  ...extra,
});

const types = (reply: Reply) => reply.lines.map((line) => line.type);

// ---------------------------------------------------------------------------------------

describe("helpers", () => {
  test("compareVersions orders dotted versions numerically", () => {
    assert.equal(compareVersions("2.1.325", "2.1.325"), 0);
    assert.equal(compareVersions("2.1.324", "2.1.325"), -1);
    assert.equal(compareVersions("2.2.0", "2.1.325"), 1);
    assert.equal(compareVersions("2.1.1000", "2.1.325"), 1);
  });

  test("tokenMatches compares the bearer token", () => {
    assert.equal(tokenMatches(`Bearer ${TOKEN}`, TOKEN), true);
    assert.equal(tokenMatches(`Bearer ${TOKEN}x`, TOKEN), false);
    assert.equal(tokenMatches(TOKEN, TOKEN), false);
    assert.equal(tokenMatches(undefined, TOKEN), false);
  });

  test("isLoopback accepts only this machine", () => {
    assert.equal(isLoopback("127.0.0.1"), true);
    assert.equal(isLoopback("::1"), true);
    assert.equal(isLoopback("::ffff:127.0.0.1"), true);
    assert.equal(isLoopback("192.168.1.20"), false);
    assert.equal(isLoopback("::ffff:192.168.1.20"), false);
    assert.equal(isLoopback(undefined), false);
  });

  test("mcpUrlAllowed matches the allowlist exactly", () => {
    const list = ["http://localhost:3333/mcp", "http://127.0.0.1:3000/mcp"];
    assert.equal(mcpUrlAllowed("http://localhost:3333/mcp", list), true);
    assert.equal(mcpUrlAllowed("http://127.0.0.1:3000/mcp", list), true);
    assert.equal(mcpUrlAllowed("http://evil.example/mcp", list), false);
    assert.equal(mcpUrlAllowed("http://localhost:3333/other", list), false);
    assert.equal(mcpUrlAllowed("http://localhost:3333/mcp?x=1", list), false);
    assert.equal(mcpUrlAllowed("http://user:pw@localhost:3333/mcp", list), false);
    assert.equal(mcpUrlAllowed("file:///etc/passwd", list), false);
    assert.equal(mcpUrlAllowed(42, list), false);
  });

  test("cleanEnv drops credentials and host-session variables", () => {
    const env = cleanEnv({
      PATH: "/usr/bin",
      HOME: "/Users/owner",
      CLAUDE_CONFIG_DIR: "/Users/owner/.claude",
      ANTHROPIC_API_KEY: "sk-ant",
      ANTHROPIC_AUTH_TOKEN: "x",
      ANTHROPIC_BASE_URL: "http://proxy",
      CLAUDE_CODE_OAUTH_TOKEN: "oauth",
      CLAUDE_CODE_SESSION_ID: "s",
      CLAUDE_CODE_USE_BEDROCK: "1",
      CLAUDECODE: "1",
      CLAUDE_BRIDGE_TOKEN: TOKEN,
      MCP_API_TOKEN: "mcp",
    });
    assert.deepEqual(Object.keys(env).sort(), [
      "CLAUDE_AGENT_SDK_CLIENT_APP",
      "CLAUDE_CONFIG_DIR",
      "ENABLE_CLAUDEAI_MCP_SERVERS",
      "HOME",
      "PATH",
    ]);
    assert.equal(env.ENABLE_CLAUDEAI_MCP_SERVERS, "false");
  });

  test("the PreToolUse hook denies every tool but Sure's", async () => {
    const signal = new AbortController().signal;
    const allowed = await denyForeignTools({ tool_name: "mcp__sure__get_accounts" } as never, "id", { signal });
    assert.deepEqual(allowed, {});
    for (const name of ["Bash", "Read", "WebFetch", "mcp__other__x", "mcp__sure_evil__x"]) {
      const denied = (await denyForeignTools({ tool_name: name } as never, "id", { signal })) as {
        hookSpecificOutput: { permissionDecision: string };
      };
      assert.equal(denied.hookSpecificOutput.permissionDecision, "deny", name);
    }
  });

  test("an older bundled CLI refuses to start", () => {
    assert.throws(() => assertCliVersion("2.1.324", "2.1.325"), /older than 2\.1\.325/);
    assert.throws(() => assertCliVersion("", "2.1.325"), /unknown/);
    assert.doesNotThrow(() => assertCliVersion("2.1.330", "2.1.325"));
    const { fn } = fakeQuery(async function* () {});
    assert.throws(
      () =>
        createBridge({
          query: fn,
          config: { port: 0, token: TOKEN, mcpAllowlist: [MCP_URL], workDir: os.tmpdir() },
          cliVersion: "2.1.300",
          sdkVersion: "0.3.300",
          minCliVersion: "2.1.325",
        }),
      /claude-agent-sdk pin/,
    );
  });
});

describe("POST /turn", () => {
  test("streams session, coalesced text, tool, tool_result and result", async () => {
    const { fn, calls } = fakeQuery(async function* () {
      yield init();
      yield delta("Let me ");
      yield delta("check.");
      yield toolUse("tu_1", "mcp__sure__get_transactions", { category: "Groceries" });
      yield toolResult("tu_1", [{ type: "text", text: "3 transactions" }]);
      yield delta("You spent ");
      yield delta("₴1,200.");
      yield success({ result: "Let me check.You spent ₴1,200." });
    });
    const { port, logs } = await start(fn);
    const reply = await request(port, "POST", "/turn", turnBody());

    assert.equal(reply.status, 200);
    assert.deepEqual(types(reply), ["session", "text", "tool", "tool_result", "text", "result"]);
    assert.deepEqual(reply.lines[0], { type: "session", session_id: "sess-new", model: "claude-sonnet-5-5" });
    assert.equal(reply.lines[1].delta, "Let me check.");
    assert.deepEqual(reply.lines[2], {
      type: "tool",
      id: "tu_1",
      name: "mcp__sure__get_transactions",
      input: { category: "Groceries" },
    });
    assert.deepEqual(reply.lines[3], { type: "tool_result", id: "tu_1", is_error: false, content: "3 transactions" });
    assert.equal(reply.lines[4].delta, "You spent ₴1,200.");
    const result = reply.lines[5];
    assert.equal(result.session_id, "sess-new");
    assert.equal(result.model, "claude-sonnet-5-5");
    assert.equal(result.num_turns, 2);
    assert.equal(result.total_cost_usd, 0.012);
    assert.deepEqual(result.usage, {
      input_tokens: 10,
      output_tokens: 5,
      cache_read_input_tokens: 100,
      cache_creation_input_tokens: 20,
    });

    // The prompt went in as a user message after the MCP server was set.
    assert.equal(calls.length, 1);
    assert.deepEqual((calls[0].prompts[0] as { message: unknown }).message, {
      role: "user",
      content: "What did I spend on groceries?",
    });
    // Logs carry ids and codes, never the prompt or the text.
    const logText = JSON.stringify(logs);
    assert.doesNotMatch(logText, /groceries|spent|1,200/i);
    assert.doesNotMatch(logText, new RegExp(TURN_TOKEN));
    assert.ok(logs.some((entry) => entry.event === "turn_end" && entry.fields.outcome === "ok"));
  });

  test("sets the query options and passes the turn token only through setMcpServers", async () => {
    const { fn, calls } = fakeQuery(async function* () {
      yield init();
      yield success();
    });
    const { port } = await start(fn, {
      env: { PATH: "/usr/bin", ANTHROPIC_API_KEY: "sk-ant", CLAUDE_CODE_OAUTH_TOKEN: "oauth", CLAUDECODE: "1" },
    });
    await request(port, "POST", "/turn", turnBody({ resume_session_id: "sess-old" }));

    const options = calls[0].params.options as Record<string, unknown>;
    assert.deepEqual(options.tools, []);
    assert.deepEqual(options.allowedTools, ["mcp__sure__*"]);
    assert.ok((options.disallowedTools as string[]).includes("Bash"));
    assert.equal(options.permissionMode, "dontAsk");
    assert.equal(options.strictMcpConfig, true);
    assert.deepEqual(options.settingSources, []);
    assert.equal(options.includePartialMessages, true);
    assert.equal(options.maxTurns, 16);
    assert.equal(options.model, "sonnet");
    assert.equal(options.systemPrompt, "You are Sure's assistant.");
    assert.equal(options.resume, "sess-old");
    assert.equal(options.forkSession, true);
    assert.equal(options.mcpServers, undefined);
    assert.ok((options.hooks as { PreToolUse: unknown[] }).PreToolUse.length === 1);
    const env = options.env as Record<string, string>;
    assert.equal(env.ANTHROPIC_API_KEY, undefined);
    assert.equal(env.CLAUDE_CODE_OAUTH_TOKEN, undefined);
    assert.equal(env.CLAUDECODE, undefined);
    assert.equal(env.ENABLE_CLAUDEAI_MCP_SERVERS, "false");
    assert.ok(!JSON.stringify(options).includes(TURN_TOKEN));

    assert.deepEqual(calls[0].mcpServers, {
      sure: {
        type: "http",
        url: MCP_URL,
        headers: { Authorization: `Bearer ${TURN_TOKEN}` },
        timeout: 60_000,
      },
    });
  });

  test("a new conversation does not resume", async () => {
    const { fn, calls } = fakeQuery(async function* () {
      yield success();
    });
    const { port } = await start(fn);
    await request(port, "POST", "/turn", turnBody());
    const options = calls[0].params.options as Record<string, unknown>;
    assert.equal(options.resume, undefined);
    assert.equal(options.forkSession, undefined);
  });

  test("max_turns from the request is capped at 16", async () => {
    const { fn, calls } = fakeQuery(async function* () {
      yield success();
    });
    const { port } = await start(fn);
    await request(port, "POST", "/turn", turnBody({ limits: { max_turns: 99 } }));
    await request(port, "POST", "/turn", turnBody({ limits: { max_turns: 4 } }));
    assert.equal((calls[0].params.options as { maxTurns: number }).maxTurns, 16);
    assert.equal((calls[1].params.options as { maxTurns: number }).maxTurns, 4);
  });

  test("text the model returns without streaming it is still sent", async () => {
    const { fn } = fakeQuery(async function* () {
      yield success({ result: "Only in the result" });
    });
    const { port } = await start(fn);
    const reply = await request(port, "POST", "/turn", turnBody());
    assert.deepEqual(types(reply), ["text", "result"]);
    assert.equal(reply.lines[0].delta, "Only in the result");
  });

  test("tool results are cut to 8 KB", async () => {
    const { fn } = fakeQuery(async function* () {
      yield toolUse("tu_1", "mcp__sure__get_transactions", {});
      yield toolResult("tu_1", "x".repeat(20_000), true);
      yield success();
    });
    const { port } = await start(fn);
    const reply = await request(port, "POST", "/turn", turnBody());
    const result = reply.lines.find((line) => line.type === "tool_result") as { content: string; is_error: boolean };
    assert.equal(result.is_error, true);
    assert.ok(result.content.length < 8300);
    assert.match(result.content, /\[truncated\]$/);
  });

  test("a rejected rate limit aborts the turn with usage_limit and reset_at", async () => {
    let afterReject = false;
    const { fn, calls } = fakeQuery(async function* ({ signal }) {
      yield init();
      yield rateLimit("allowed_warning");
      yield rateLimit("rejected");
      // Claude Code would wait for the window here.
      await untilAborted(signal);
      afterReject = true;
    });
    const { port } = await start(fn);
    const reply = await request(port, "POST", "/turn", turnBody());

    assert.deepEqual(types(reply), ["session", "rate_limit", "rate_limit", "error"]);
    assert.deepEqual(reply.lines[2], {
      type: "rate_limit",
      kind: "five_hour",
      utilization: 1,
      resets_at: "2025-11-15T16:00:00.000Z",
      status: "rejected",
    });
    const error = reply.lines[3];
    assert.equal(error.code, "usage_limit");
    assert.equal(error.reset_at, "2025-11-15T16:00:00.000Z");
    assert.equal(error.retryable, false);
    assert.equal(calls[0].aborted(), true);
    assert.equal(calls[0].closed, true);
    await sleep(10);
    assert.equal(afterReject, true);
  });

  test("a result with is_error and status 429 is a usage limit", async () => {
    const { fn } = fakeQuery(async function* () {
      yield init();
      yield rateLimit("allowed_warning", 1_763_230_000);
      yield success({ is_error: true, api_error_status: 429, result: "Usage limit reached" });
    });
    const { port } = await start(fn);
    const reply = await request(port, "POST", "/turn", turnBody());
    const error = reply.lines.at(-1) as Record<string, unknown>;
    assert.equal(error.type, "error");
    assert.equal(error.code, "usage_limit");
    assert.equal(error.reset_at, new Date(1_763_230_000 * 1000).toISOString());
  });

  test("other result errors map to their codes", async () => {
    const cases: [Record<string, unknown>, string][] = [
      [{ is_error: true, api_error_status: 529, result: "Overloaded" }, "overloaded"],
      [{ is_error: true, api_error_status: 401, result: "Invalid credentials" }, "auth"],
      [{ subtype: "error_max_turns", is_error: true, errors: [] }, "max_turns"],
      [{ subtype: "error_max_budget_usd", is_error: true, errors: [] }, "budget"],
      [
        { subtype: "error_during_execution", is_error: true, errors: ["No conversation found with session ID: sess-old"] },
        "session_not_found",
      ],
      [{ subtype: "error_during_execution", is_error: true, errors: ["boom"] }, "internal"],
    ];
    for (const [overrides, code] of cases) {
      const { fn } = fakeQuery(async function* () {
        yield success(overrides);
      });
      const { port } = await start(fn);
      const reply = await request(port, "POST", "/turn", turnBody());
      const error = reply.lines.at(-1) as Record<string, unknown>;
      assert.equal(error.type, "error", code);
      assert.equal(error.code, code);
    }
  });

  test("a signed-out login gives auth and says claude auth login", async () => {
    const { fn, calls } = fakeQuery(
      async function* () {
        yield success();
      },
      { account: { tokenSource: "none" } },
    );
    const { port } = await start(fn);
    const reply = await request(port, "POST", "/turn", turnBody());
    assert.deepEqual(types(reply), ["error"]);
    assert.equal(reply.lines[0].code, "auth");
    assert.match(String(reply.lines[0].message), /claude auth login/);
    assert.equal(calls[0].mcpServers, null);
    assert.equal(calls[0].closed, true);
  });

  test("an MCP server that does not connect gives mcp_unavailable", async () => {
    const { fn } = fakeQuery(
      async function* () {
        yield success();
      },
      { mcpErrors: { sure: "connection refused" } },
    );
    const { port } = await start(fn);
    const reply = await request(port, "POST", "/turn", turnBody());
    assert.equal(reply.lines[0].code, "mcp_unavailable");
    assert.equal(reply.lines[0].retryable, true);
  });

  test("a client disconnect aborts the query", async () => {
    const { fn, calls } = fakeQuery(async function* ({ signal }) {
      yield init();
      yield delta("Thinking about it");
      await untilAborted(signal);
    });
    const { port, bridge, logs } = await start(fn, { timing: { coalesceMs: 1 } });
    await request(port, "POST", "/turn", turnBody(), TOKEN, (line, req) => {
      if (line.type === "text") req.destroy();
    });
    for (let i = 0; i < 50 && bridge.activeTurns > 0; i++) await sleep(10);
    assert.equal(calls[0].aborted(), true);
    assert.equal(calls[0].closed, true);
    assert.equal(bridge.activeTurns, 0);
    assert.ok(logs.some((entry) => entry.event === "turn_end" && entry.fields.outcome === "disconnected"));
  });

  test("heartbeats keep a long turn visibly alive", async () => {
    const { fn } = fakeQuery(async function* () {
      yield init();
      await sleep(120);
      yield success();
    });
    const { port } = await start(fn, { timing: { heartbeatMs: 25 } });
    const reply = await request(port, "POST", "/turn", turnBody());
    const heartbeats = reply.lines.filter((line) => line.type === "heartbeat").length;
    assert.ok(heartbeats >= 2, `expected heartbeats, got ${heartbeats}`);
    assert.equal(reply.lines.at(-1)?.type, "result");
  });

  test("the wall clock stops a turn that runs too long", async () => {
    const { fn, calls } = fakeQuery(async function* ({ signal }) {
      yield init();
      await untilAborted(signal);
    });
    const { port } = await start(fn, { timing: { wallClockMs: 60 } });
    const reply = await request(port, "POST", "/turn", turnBody());
    assert.equal(reply.lines.at(-1)?.code, "timeout");
    assert.equal(calls[0].aborted(), true);
  });

  test("a third concurrent turn is busy (429)", async () => {
    let release: () => void = () => {};
    const gate = new Promise<void>((resolve) => {
      release = resolve;
    });
    const { fn } = fakeQuery(async function* () {
      yield init();
      await gate;
      yield success();
    });
    const { port, bridge } = await start(fn);
    const first = request(port, "POST", "/turn", turnBody());
    const second = request(port, "POST", "/turn", turnBody());
    for (let i = 0; i < 50 && bridge.activeTurns < 2; i++) await sleep(10);
    assert.equal(bridge.activeTurns, 2);

    const third = await request(port, "POST", "/turn", turnBody());
    assert.equal(third.status, 429);
    assert.equal(third.lines[0].code, "busy");
    assert.equal(third.lines[0].retryable, true);

    release();
    const [a, b] = await Promise.all([first, second]);
    assert.equal(a.lines.at(-1)?.type, "result");
    assert.equal(b.lines.at(-1)?.type, "result");
  });

  test("a wrong token gets 401", async () => {
    const { fn, calls } = fakeQuery(async function* () {
      yield success();
    });
    const { port } = await start(fn);
    const reply = await request(port, "POST", "/turn", turnBody(), "wrong-token");
    assert.equal(reply.status, 401);
    assert.equal(reply.lines[0].code, "unauthorized");
    assert.equal(calls.length, 0);
  });

  test("a foreign mcp.url is refused", async () => {
    const { fn, calls } = fakeQuery(async function* () {
      yield success();
    });
    const { port } = await start(fn);
    for (const url of ["http://evil.example/mcp", "http://192.168.1.5:3333/mcp", "http://localhost:3333/mcp?x"]) {
      const reply = await request(port, "POST", "/turn", turnBody({ mcp: { url, token: TURN_TOKEN } }));
      assert.equal(reply.status, 400, url);
      assert.equal(reply.lines[0].code, "mcp_url_not_allowed");
    }
    assert.equal(calls.length, 0);
  });

  test("missing fields and bad JSON are 400", async () => {
    const { fn } = fakeQuery(async function* () {
      yield success();
    });
    const { port } = await start(fn);
    assert.equal((await request(port, "POST", "/turn", { ...turnBody(), prompt: "" })).status, 400);
    assert.equal((await request(port, "POST", "/turn", { ...turnBody(), model: undefined })).status, 400);
    assert.equal((await request(port, "POST", "/turn", { ...turnBody(), mcp: { url: MCP_URL } })).status, 400);
    assert.equal((await request(port, "GET", "/nope")).status, 404);
  });
});

describe("GET /health and /models", () => {
  test("reports the account, plan, CLI version and usage windows, cached", async () => {
    const { fn, calls } = fakeQuery(async function* () {});
    const { port } = await start(fn);
    const reply = await request(port, "GET", "/health");
    assert.equal(reply.status, 200);
    const health = reply.lines[0] as Record<string, any>;
    assert.equal(health.ok, true);
    assert.equal(health.signed_in, true);
    assert.equal(health.account.email, "owner@example.com");
    assert.equal(health.plan, "max");
    assert.equal(health.token_source, "claude.ai");
    assert.equal(health.cli_version, "2.1.325");
    assert.equal(health.max_concurrent_turns, 2);
    assert.deepEqual(health.usage.five_hour, { utilization: 0.42, resets_at: "2026-11-15T15:00:00Z" });
    assert.equal(health.usage.seven_day.utilization, 0.1);

    // The probe never sends a prompt and never attaches an MCP server.
    const options = calls[0].params.options as Record<string, unknown>;
    assert.equal(options.persistSession, false);
    assert.deepEqual(options.mcpServers, {});
    assert.equal(calls[0].prompts.length, 0);
    assert.equal(calls[0].closed, true);

    await request(port, "GET", "/health");
    await request(port, "GET", "/models");
    assert.equal(calls.length, 1, "the probe is cached");
  });

  test("a signed-out login shows signed_in false with the auth fix", async () => {
    const { fn } = fakeQuery(async function* () {}, { account: { tokenSource: "none" } });
    const { port } = await start(fn);
    const health = (await request(port, "GET", "/health")).lines[0] as Record<string, any>;
    assert.equal(health.ok, false);
    assert.equal(health.signed_in, false);
    assert.equal(health.error.code, "auth");
    assert.match(health.error.message, /claude auth login/);
  });

  test("usage that cannot be read does not break health", async () => {
    const { fn } = fakeQuery(async function* () {}, { usage: { rate_limits_available: false, rate_limits: null } });
    const { port } = await start(fn);
    const health = (await request(port, "GET", "/health")).lines[0] as Record<string, any>;
    assert.equal(health.ok, true);
    assert.deepEqual(health.usage, { available: false });
  });

  test("/models lists the models Claude Code offers", async () => {
    const { fn } = fakeQuery(async function* () {});
    const { port } = await start(fn);
    const reply = await request(port, "GET", "/models");
    assert.deepEqual((reply.lines[0] as { models: unknown[] }).models, [
      { value: "sonnet", display_name: "Sonnet", description: "Everyday", resolved_model: "claude-sonnet-5-5" },
    ]);
  });

  test("health needs the token too", async () => {
    const { fn } = fakeQuery(async function* () {});
    const { port } = await start(fn);
    assert.equal((await request(port, "GET", "/health", undefined, "nope")).status, 401);
  });
});
