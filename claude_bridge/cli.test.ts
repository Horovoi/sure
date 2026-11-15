// Tests for bin/claude-bridge install, uninstall and status against a temporary HOME.
// launchctl, claude, npm and trash are stubs that log their arguments; nothing is loaded
// into launchd and the real ~/.claude.json is never touched.
// Run: node --test 'claude_bridge/*.test.ts'

import assert from "node:assert/strict";
import { execFile } from "node:child_process";
import {
  chmodSync,
  copyFileSync,
  existsSync,
  mkdirSync,
  mkdtempSync,
  readFileSync,
  statSync,
  writeFileSync,
} from "node:fs";
import http from "node:http";
import type { AddressInfo } from "node:net";
import os from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { describe, test } from "node:test";

const HERE = path.dirname(fileURLToPath(import.meta.url));
const SCRIPT = path.join(HERE, "..", "bin", "claude-bridge");
const MCP_TOKEN = "mcp-secret-token-0123456789";
const LABEL = "ua.sure.claude-bridge";

type Sandbox = {
  root: string;
  home: string;
  bridgeDir: string;
  envFile: string;
  fakeLog: string;
  env: NodeJS.ProcessEnv;
  plist: string;
  config: string;
  log: string;
};

function sandbox(opts: { cliVersion?: string; envFile?: string } = {}): Sandbox {
  const root = mkdtempSync(path.join(os.tmpdir(), "claude-bridge-cli-"));
  const home = path.join(root, "home");
  const bin = path.join(root, "bin");
  const bridgeDir = path.join(root, "bridge");
  const fakeLog = path.join(root, "calls.log");
  mkdirSync(home, { recursive: true });
  mkdirSync(bin);
  mkdirSync(path.join(bridgeDir, "node_modules", "@anthropic-ai", "claude-agent-sdk"), { recursive: true });

  copyFileSync(path.join(HERE, "server.ts"), path.join(bridgeDir, "server.ts"));
  copyFileSync(path.join(HERE, "package.json"), path.join(bridgeDir, "package.json"));
  writeFileSync(
    path.join(bridgeDir, "node_modules", "@anthropic-ai", "claude-agent-sdk", "package.json"),
    JSON.stringify({ version: "0.3.325", claudeCodeVersion: opts.cliVersion ?? "2.1.325" }),
  );

  const stub = (name: string, body = "") => {
    const file = path.join(bin, name);
    writeFileSync(file, `#!/bin/bash\necho "${name} $*" >> "$FAKE_LOG"\n${body}\nexit 0\n`);
    chmodSync(file, 0o755);
  };
  stub("launchctl", 'if [ "$1" = print ] && [ -z "$FAKE_LOADED" ]; then exit 113; fi');
  stub("claude");
  stub("npm");
  stub("trash", 'mkdir -p "$HOME/.Trash-fake"; for f in "$@"; do mv "$f" "$HOME/.Trash-fake/"; done');

  const envFile = path.join(root, ".env.production");
  writeFileSync(envFile, opts.envFile ?? `SECRET_KEY_BASE=abc\nMCP_API_TOKEN="${MCP_TOKEN}"\n`);

  return {
    root,
    home,
    bridgeDir,
    envFile,
    fakeLog,
    plist: path.join(home, "Library", "LaunchAgents", `${LABEL}.plist`),
    config: path.join(home, ".config", "sure-claude-bridge", "config.json"),
    log: path.join(home, "Library", "Logs", "sure-claude-bridge.log"),
    env: {
      HOME: home,
      PATH: `${bin}:${path.dirname(process.execPath)}:/usr/bin:/bin:/usr/sbin:/sbin`,
      CLAUDE_BRIDGE_DIR: bridgeDir,
      CLAUDE_BRIDGE_ENV_FILE: envFile,
      FAKE_LOG: fakeLog,
    },
  };
}

function run(box: Sandbox, args: string[], extraEnv: NodeJS.ProcessEnv = {}) {
  return new Promise<{ code: number; out: string }>((resolve) => {
    execFile(
      "bash",
      [SCRIPT, ...args],
      { env: { ...box.env, ...extraEnv }, timeout: 60_000 },
      (error, stdout, stderr) => {
        const code = error ? (typeof error.code === "number" ? error.code : 1) : 0;
        resolve({ code, out: `${stdout}${stderr}` });
      },
    );
  });
}

const calls = (box: Sandbox) => (existsSync(box.fakeLog) ? readFileSync(box.fakeLog, "utf8") : "");
const readConfig = (box: Sandbox) => JSON.parse(readFileSync(box.config, "utf8"));
const uid = String(process.getuid?.() ?? "");

describe("bin/claude-bridge install", () => {
  test("writes the plist, config and log, loads the agent and registers the MCP", async () => {
    const box = sandbox();
    const { code, out } = await run(box, ["install"]);
    assert.equal(code, 0, out);

    const plist = readFileSync(box.plist, "utf8");
    assert.match(plist, new RegExp(`<string>${LABEL}</string>`));
    assert.ok(plist.includes(`<string>${process.execPath}</string>`), "absolute node path");
    assert.ok(plist.includes(`<string>${path.join(box.bridgeDir, "server.ts")}</string>`));
    assert.match(plist, /<key>RunAtLoad<\/key>\s*<true\/>/);
    assert.match(plist, /<key>KeepAlive<\/key>\s*<true\/>/);
    assert.ok(plist.includes(box.log));

    const config = readConfig(box);
    assert.equal(config.port, 3339);
    assert.match(config.token, /^[0-9a-f]{64}$/);
    assert.ok(config.mcp_allowlist.includes("http://localhost:3333/mcp"));
    assert.equal(statSync(box.config).mode & 0o777, 0o600);
    assert.equal(statSync(path.dirname(box.config)).mode & 0o777, 0o700);
    assert.ok(existsSync(box.log));

    const log = calls(box);
    assert.match(log, /^npm ci/m);
    assert.ok(log.includes(`launchctl bootstrap gui/${uid} ${box.plist}`));
    assert.ok(
      log.includes(
        `claude mcp add --scope user --transport http sure http://localhost:3333/mcp --header Authorization: Bearer ${MCP_TOKEN}`,
      ),
    );

    // The MCP token is never printed; the bridge lines are, for pasting.
    assert.ok(!out.includes(MCP_TOKEN));
    assert.ok(out.includes("CLAUDE_BRIDGE_URL=http://host.docker.internal:3339"));
    assert.ok(out.includes(`CLAUDE_BRIDGE_TOKEN=${config.token}`));
    // Without a terminal and without --write-env, .env.production is left alone.
    assert.ok(!readFileSync(box.envFile, "utf8").includes("CLAUDE_BRIDGE"));
  });

  test("--write-env adds the lines once, and a second install keeps the token", async () => {
    const box = sandbox();
    assert.equal((await run(box, ["install", "--write-env"])).code, 0);
    const token = readConfig(box).token;
    const env = readFileSync(box.envFile, "utf8");
    assert.ok(env.includes("CLAUDE_BRIDGE_URL=http://host.docker.internal:3339\n"));
    assert.ok(env.includes(`CLAUDE_BRIDGE_TOKEN=${token}\n`));

    const again = await run(box, ["install", "--write-env"]);
    assert.equal(again.code, 0, again.out);
    assert.equal(readConfig(box).token, token);
    assert.equal(readFileSync(box.envFile, "utf8"), env, "no duplicate lines");
    assert.match(again.out, /already has CLAUDE_BRIDGE_URL and CLAUDE_BRIDGE_TOKEN/);
  });

  test("uses the token already in .env.production", async () => {
    const existing = "e".repeat(64);
    const box = sandbox({
      envFile: `MCP_API_TOKEN=${MCP_TOKEN}\nCLAUDE_BRIDGE_URL=http://host.docker.internal:3339\nCLAUDE_BRIDGE_TOKEN=${existing}\n`,
    });
    assert.equal((await run(box, ["install"])).code, 0);
    assert.equal(readConfig(box).token, existing);
  });

  test("skips claude mcp add without MCP_API_TOKEN", async () => {
    const box = sandbox({ envFile: "SECRET_KEY_BASE=abc\n" });
    const { code, out } = await run(box, ["install"]);
    assert.equal(code, 0, out);
    assert.match(out, /MCP_API_TOKEN is not set/);
    assert.doesNotMatch(calls(box), /claude mcp add/);
  });

  test("refuses an SDK whose bundled Claude Code is too old", async () => {
    const box = sandbox({ cliVersion: "2.1.300" });
    const { code, out } = await run(box, ["install"]);
    assert.notEqual(code, 0);
    assert.match(out, /too old/);
    assert.ok(!existsSync(box.plist));
    assert.doesNotMatch(calls(box), /launchctl bootstrap/);
  });
});

describe("bin/claude-bridge uninstall", () => {
  test("unloads the agent, removes the MCP and moves every file to the Trash", async () => {
    const box = sandbox();
    assert.equal((await run(box, ["install"])).code, 0);
    const { code, out } = await run(box, ["uninstall"]);
    assert.equal(code, 0, out);

    const log = calls(box);
    assert.ok(log.includes(`launchctl bootout gui/${uid}/${LABEL}`));
    assert.match(log, /claude mcp remove --scope user sure/);
    assert.match(log, /^trash /m);
    for (const file of [box.plist, path.dirname(box.config), box.log]) {
      assert.ok(!existsSync(file), `${file} removed`);
    }
    assert.ok(existsSync(path.join(box.home, ".Trash-fake", `${LABEL}.plist`)), "recoverable");
    assert.ok(existsSync(box.envFile), ".env.production untouched");
  });
});

describe("bin/claude-bridge status", () => {
  const freePort = () =>
    new Promise<number>((resolve) => {
      const server = http.createServer();
      server.listen(0, "127.0.0.1", () => {
        const { port } = server.address() as AddressInfo;
        server.close(() => resolve(port));
      });
    });

  const setPort = (box: Sandbox, port: number) => {
    const config = readConfig(box);
    writeFileSync(box.config, JSON.stringify({ ...config, port }));
  };

  test("names the fix for a missing node, a stopped agent and missing env lines", async () => {
    const box = sandbox();
    assert.equal((await run(box, ["install"])).code, 0);
    writeFileSync(box.plist, readFileSync(box.plist, "utf8").replace(process.execPath, "/nonexistent/node"));
    setPort(box, await freePort());

    const { code, out } = await run(box, ["status"]);
    assert.equal(code, 1);
    assert.match(out, /FAIL {2}The Node the agent runs \(\/nonexistent\/node\) is gone/);
    assert.match(out, /FAIL {2}The LaunchAgent ua\.sure\.claude-bridge is not loaded/);
    assert.match(out, /does not answer/);
    assert.match(out, /lacks CLAUDE_BRIDGE_URL or CLAUDE_BRIDGE_TOKEN/);
    assert.match(out, /fix: bin\/claude-bridge install/);
  });

  test("names the fix for an old bundled CLI", async () => {
    const box = sandbox();
    assert.equal((await run(box, ["install"])).code, 0);
    writeFileSync(
      path.join(box.bridgeDir, "node_modules", "@anthropic-ai", "claude-agent-sdk", "package.json"),
      JSON.stringify({ version: "0.3.300", claudeCodeVersion: "2.1.300" }),
    );
    setPort(box, await freePort());
    const { code, out } = await run(box, ["status"]);
    assert.equal(code, 1);
    assert.match(out, /bundled Claude Code 2\.1\.300 .*too old/);
    assert.match(out, /raise the @anthropic-ai\/claude-agent-sdk pin/);
  });

  test("says claude auth login when the bridge reports a signed-out login", async () => {
    const box = sandbox();
    assert.equal((await run(box, ["install", "--write-env"])).code, 0);
    const token = readConfig(box).token;
    let seenAuth = "";
    const server = http.createServer((req, res) => {
      seenAuth = String(req.headers.authorization);
      res.end(JSON.stringify({ ok: false, signed_in: false, error: { code: "auth" } }));
    });
    await new Promise<void>((resolve) => server.listen(0, "127.0.0.1", resolve));
    setPort(box, (server.address() as AddressInfo).port);
    try {
      const { code, out } = await run(box, ["status"], { FAKE_LOADED: "1" });
      assert.equal(code, 1);
      assert.equal(seenAuth, `Bearer ${token}`);
      assert.match(out, /FAIL {2}Claude is signed out/);
      assert.match(out, /fix: claude auth login/);
      assert.ok(!out.includes(token), "the token is not printed");
    } finally {
      server.close();
    }
  });

  test("is green when everything is in place", async () => {
    const box = sandbox();
    assert.equal((await run(box, ["install", "--write-env"])).code, 0);
    const server = http.createServer((_req, res) => {
      res.end(
        JSON.stringify({
          ok: true,
          signed_in: true,
          account: { email: "owner@example.com" },
          plan: "max",
          token_source: "claude.ai",
          cli_version: "2.1.325",
          usage: { available: true, five_hour: { utilization: 0.42, resets_at: "2026-11-15T15:00:00Z" } },
        }),
      );
    });
    await new Promise<void>((resolve) => server.listen(0, "127.0.0.1", resolve));
    setPort(box, (server.address() as AddressInfo).port);
    try {
      const { code, out } = await run(box, ["status"], { FAKE_LOADED: "1" });
      assert.equal(code, 0, out);
      assert.match(out, /Signed in as owner@example\.com \(plan max/);
      assert.match(out, /five-hour window 42% used/);
      assert.match(out, /All good\./);
    } finally {
      server.close();
    }
  });
});
