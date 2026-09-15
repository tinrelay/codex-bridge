import crypto from "node:crypto";
import fs from "node:fs";
import net from "node:net";
import os from "node:os";
import path from "node:path";
import readline from "node:readline";

const MAX_FRAME = 8 * 1024 * 1024;
const SEND_TOOL = "send_message_to_thread";
const STOCK_SOCKET_ROOT = "/tmp/codex-browser-use";
const relayGeneration = process.argv[3];
let nativePipe;
const stateHome = process.argv[2] || process.env.CODEX_BRIDGE_STATE_HOME ||
  path.join(os.homedir(), ".codex", "codex-bridge");
const relayPath = path.join(
  stateHome,
  `codex-bridge-relay-${process.pid}-${crypto.randomUUID()}.sock`
);

let relayServer;

function encodeFrame(message) {
  const payload = Buffer.from(JSON.stringify(message));
  if (payload.length > MAX_FRAME) throw new Error("response too large");
  const header = Buffer.alloc(4);
  header.writeUInt32LE(payload.length);
  return Buffer.concat([header, payload]);
}

function rpcError(id, message) {
  return {jsonrpc: "2.0", id, error: {code: -32600, message}};
}

function allowedRequest(request) {
  if (request?.method === "tools/list") return true;
  if (request?.method !== "tools/call") return false;

  const params = request.params;
  const args = params?.arguments;
  return params?.namespace === "codex_app" &&
    params?.tool === SEND_TOOL &&
    typeof params?.threadId === "string" &&
    typeof args?.threadId === "string" &&
    args?.hostId === "local" &&
    typeof args?.prompt === "string";
}

function filterResponse(request, response) {
  if (request.method !== "tools/list" || response?.error) return response;
  const tools = Array.isArray(response?.result?.tools) ? response.result.tools : [];
  return {
    ...response,
    result: {
      ...response.result,
      codexBridgeRelayGeneration: relayGeneration,
      tools: tools.filter(tool =>
        tool?.namespace === "codex_app" && tool?.name === SEND_TOOL
      )
    }
  };
}

function advertisesSendTool(candidate) {
  return new Promise(resolve => {
    const socket = net.createConnection(candidate);
    let buffer = Buffer.alloc(0);
    let settled = false;
    const finish = value => {
      if (settled) return;
      settled = true;
      socket.destroy();
      resolve(value);
    };

    socket.setTimeout(250, () => finish(false));
    socket.on("error", () => finish(false));
    socket.on("close", () => finish(false));
    socket.on("connect", () => {
      socket.write(encodeFrame({
        id: 1,
        jsonrpc: "2.0",
        method: "tools/list",
        params: {threadStartKind: "all"}
      }));
    });
    socket.on("data", chunk => {
      buffer = Buffer.concat([buffer, chunk]);
      if (buffer.length < 4) return;
      const size = buffer.readUInt32LE(0);
      if (size > MAX_FRAME) return finish(false);
      if (buffer.length < size + 4) return;
      try {
        const response = JSON.parse(buffer.subarray(4, size + 4).toString("utf8"));
        const tools = Array.isArray(response?.result?.tools) ? response.result.tools : [];
        finish(tools.some(tool =>
          tool?.namespace === "codex_app" && tool?.name === SEND_TOOL
        ));
      } catch {
        finish(false);
      }
    });
  });
}

async function discoverNativePipe() {
  const candidates = [];
  if (process.env.CODEX_APP_TOOLS_PIPE_PATH) {
    candidates.push(process.env.CODEX_APP_TOOLS_PIPE_PATH);
  }
  try {
    const names = await fs.promises.readdir(STOCK_SOCKET_ROOT);
    for (const name of names.sort()) {
      if (name.endsWith(".sock") && !name.startsWith("codex-bridge-relay-")) {
        candidates.push(path.join(STOCK_SOCKET_ROOT, name));
      }
    }
  } catch {
    // A missing stock socket directory means Codex app tools are unavailable.
  }

  for (const candidate of [...new Set(candidates)]) {
    if (await advertisesSendTool(candidate)) return candidate;
  }
}

function relayIsDead(candidate) {
  return new Promise(resolve => {
    const socket = net.createConnection(candidate);
    let settled = false;
    const finish = value => {
      if (settled) return;
      settled = true;
      socket.destroy();
      resolve(value);
    };

    socket.setTimeout(250, () => finish(false));
    socket.on("connect", () => finish(false));
    socket.on("error", error => finish(error.code === "ECONNREFUSED"));
  });
}

async function removeDeadRelays() {
  let names;
  try {
    names = await fs.promises.readdir(stateHome);
  } catch {
    return;
  }

  for (const name of names.sort()) {
    if (!name.startsWith("codex-bridge-relay-") || !name.endsWith(".sock")) continue;
    const candidate = path.join(stateHome, name);
    if (await relayIsDead(candidate)) {
      await fs.promises.unlink(candidate).catch(() => {});
    }
  }
}

function forward(request, client) {
  const upstream = net.createConnection(nativePipe);
  let buffer = Buffer.alloc(0);
  let replied = false;
  let submitted = false;
  const mutating = request.method === "tools/call";

  const fail = message => {
    if (replied || client.destroyed) return;
    replied = true;
    if (mutating && submitted) {
      client.destroy();
    } else {
      client.end(encodeFrame(rpcError(request.id, message)));
    }
  };

  upstream.on("connect", () => {
    try {
      upstream.write(encodeFrame(request));
      submitted = mutating;
    } catch (error) {
      fail(error.message);
    }
  });
  upstream.setTimeout(20000, () => {
    fail("Codex app tools timeout");
    upstream.destroy();
  });
  upstream.on("error", () => fail("Codex app tools unavailable"));
  upstream.on("close", () => fail("Codex app tools closed"));
  upstream.on("data", chunk => {
    buffer = Buffer.concat([buffer, chunk]);
    if (buffer.length < 4) return;
    const size = buffer.readUInt32LE(0);
    if (size > MAX_FRAME) {
      fail("invalid Codex app-tools frame");
      upstream.destroy();
      return;
    }
    if (buffer.length < size + 4) return;

    try {
      const response = JSON.parse(buffer.subarray(4, size + 4).toString("utf8"));
      const frame = encodeFrame(filterResponse(request, response));
      replied = true;
      client.end(frame);
    } catch {
      fail("invalid Codex app-tools response");
    } finally {
      upstream.destroy();
    }
  });
}

function handleClient(client) {
  let buffer = Buffer.alloc(0);
  client.on("data", chunk => {
    buffer = Buffer.concat([buffer, chunk]);
    if (buffer.length < 4) return;
    const size = buffer.readUInt32LE(0);
    if (size > MAX_FRAME) {
      client.end(encodeFrame(rpcError(null, "invalid frame")));
      return;
    }
    if (buffer.length < size + 4) return;

    let request;
    try {
      request = JSON.parse(buffer.subarray(4, size + 4).toString("utf8"));
    } catch {
      client.end(encodeFrame(rpcError(null, "invalid JSON")));
      return;
    }

    if (!allowedRequest(request)) {
      client.end(encodeFrame(rpcError(request.id, "unsupported codex-bridge operation")));
      return;
    }
    forward(request, client);
  });
}

function answerMcp(message) {
  if (!Object.hasOwn(message, "id")) return;
  let result;
  if (message.method === "initialize") {
    result = {
      protocolVersion: message.params?.protocolVersion || "2024-11-05",
      capabilities: {tools: {}},
      serverInfo: {name: "codex-bridge-relay", version: "0.2.0"}
    };
  } else if (message.method === "tools/list") {
    result = {tools: []};
  } else if (message.method === "ping") {
    result = {};
  } else {
    process.stdout.write(`${JSON.stringify({
      jsonrpc: "2.0",
      id: message.id,
      error: {code: -32601, message: "Method not found"}
    })}\n`);
    return;
  }
  process.stdout.write(`${JSON.stringify({jsonrpc: "2.0", id: message.id, result})}\n`);
}

async function startRelay() {
  if (!nativePipe) return;
  await fs.promises.mkdir(stateHome, {recursive: true, mode: 0o700});
  await fs.promises.chmod(stateHome, 0o700);
  await fs.promises.unlink(relayPath).catch(() => {});
  relayServer = net.createServer(handleClient);
  relayServer.on("error", error => {
    process.stderr.write(`codex-bridge relay: ${error.message}\n`);
  });
  process.umask(0o177);
  relayServer.listen(relayPath, () => {
    fs.chmodSync(relayPath, 0o600);
  });
}

async function cleanup() {
  if (!relayServer) return;
  const server = relayServer;
  relayServer = undefined;
  await new Promise(resolve => server.close(resolve));
  await fs.promises.unlink(relayPath).catch(() => {});
}

process.on("SIGINT", async () => { await cleanup(); process.exit(0); });
process.on("SIGTERM", async () => { await cleanup(); process.exit(0); });
process.on("exit", () => { if (relayServer) fs.rmSync(relayPath, {force: true}); });

const input = readline.createInterface({input: process.stdin});
input.on("line", line => {
  try {
    answerMcp(JSON.parse(line));
  } catch {
    // Invalid MCP input is isolated from the relay.
  }
});
input.on("close", async () => { await cleanup(); process.exit(0); });

await removeDeadRelays();
nativePipe = await discoverNativePipe();
await startRelay();
