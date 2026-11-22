import { spawn } from "node:child_process";
import { createServer } from "node:http";
import { readFile, realpath } from "node:fs/promises";
import { dirname, extname, isAbsolute, relative, resolve, sep } from "node:path";
import { fileURLToPath } from "node:url";

const workspaceRoot = resolve(dirname(fileURLToPath(import.meta.url)), "..");
const probePackagePath = resolve(workspaceRoot, "tools/scarlett-device-probe");
const host = "127.0.0.1";
const port = Number(process.env.PORT || 8787);
const mimeTypes = new Map([
  [".html", "text/html; charset=utf-8"],
  [".png", "image/png"]
]);

function sendJSON(response, statusCode, payload) {
  response.writeHead(statusCode, {
    "Cache-Control": "no-store",
    "Content-Type": "application/json; charset=utf-8",
    "X-Content-Type-Options": "nosniff"
  });
  response.end(JSON.stringify(payload));
}

function probeArguments(...args) {
  return ["run", "--package-path", probePackagePath, "ScarlettDeviceProbe", "--", ...args];
}

function readDeviceSnapshot(response) {
  const child = spawn("swift", probeArguments("--json"), {
    cwd: workspaceRoot,
    stdio: ["ignore", "pipe", "pipe"]
  });
  let stdout = "";
  let stderr = "";
  let outputTooLarge = false;
  const timeout = setTimeout(() => child.kill("SIGTERM"), 30000);

  child.stdout.setEncoding("utf8");
  child.stderr.setEncoding("utf8");
  child.stdout.on("data", (chunk) => {
    stdout += chunk;
    if (stdout.length > 1_000_000) {
      outputTooLarge = true;
      child.kill("SIGTERM");
    }
  });
  child.stderr.on("data", (chunk) => {
    stderr += chunk;
    if (stderr.length > 4000) stderr = stderr.slice(-4000);
  });
  child.on("error", (error) => {
    clearTimeout(timeout);
    sendJSON(response, 503, { error: `Could not start the Swift probe: ${error.message}` });
  });
  child.on("close", (exitCode) => {
    clearTimeout(timeout);
    if (response.writableEnded) return;
    if (outputTooLarge) {
      return sendJSON(response, 502, { error: "Probe output exceeded the size limit." });
    }
    if (exitCode !== 0) {
      return sendJSON(response, 503, {
        error: "The read-only device probe failed.",
        detail: stderr.trim()
      });
    }
    try {
      sendJSON(response, 200, JSON.parse(stdout));
    } catch {
      sendJSON(response, 502, { error: "The device probe returned invalid JSON." });
    }
  });
}

function readInputGain(response, channel) {
  const child = spawn("swift", probeArguments("--read-input-gain", String(channel)), {
    cwd: workspaceRoot,
    stdio: ["ignore", "pipe", "pipe"]
  });
  let stdout = "";
  let stderr = "";
  const timeout = setTimeout(() => child.kill("SIGTERM"), 30000);

  child.stdout.setEncoding("utf8");
  child.stderr.setEncoding("utf8");
  child.stdout.on("data", (chunk) => { stdout += chunk; });
  child.stderr.on("data", (chunk) => {
    stderr += chunk;
    if (stderr.length > 4000) stderr = stderr.slice(-4000);
  });
  child.on("error", (error) => {
    clearTimeout(timeout);
    sendJSON(response, 503, { error: `Could not start the Swift probe: ${error.message}` });
  });
  child.on("close", (exitCode) => {
    clearTimeout(timeout);
    if (response.writableEnded) return;
    if (exitCode !== 0) {
      return sendJSON(response, 503, {
        error: "The read-only gain query failed.",
        detail: stderr.trim()
      });
    }
    try {
      sendJSON(response, 200, JSON.parse(stdout));
    } catch {
      sendJSON(response, 502, { error: "The gain probe returned invalid JSON." });
    }
  });
}

function runProbeCommand(response, args, failureMessage) {
  const child = spawn("swift", probeArguments(...args), {
    cwd: workspaceRoot,
    stdio: ["ignore", "pipe", "pipe"]
  });
  let stdout = "";
  let stderr = "";
  const timeout = setTimeout(() => child.kill("SIGTERM"), 30000);

  child.stdout.setEncoding("utf8");
  child.stderr.setEncoding("utf8");
  child.stdout.on("data", (chunk) => { stdout += chunk; });
  child.stderr.on("data", (chunk) => {
    stderr += chunk;
    if (stderr.length > 4000) stderr = stderr.slice(-4000);
  });
  child.on("error", (error) => {
    clearTimeout(timeout);
    sendJSON(response, 503, { error: `Could not start the Swift probe: ${error.message}` });
  });
  child.on("close", (exitCode) => {
    clearTimeout(timeout);
    if (response.writableEnded) return;
    if (exitCode !== 0) {
      return sendJSON(response, 503, { error: failureMessage, detail: stderr.trim() });
    }
    try {
      sendJSON(response, 200, JSON.parse(stdout));
    } catch {
      sendJSON(response, 502, { error: "The device probe returned invalid JSON." });
    }
  });
}

function runInputMeasurement(response, args, failureMessage) {
  const child = spawn("swift", probeArguments(...args), {
    cwd: workspaceRoot,
    stdio: ["ignore", "pipe", "pipe"]
  });
  let stdout = "";
  let stderr = "";
  const timeout = setTimeout(() => child.kill("SIGTERM"), 30000);

  child.stdout.setEncoding("utf8");
  child.stderr.setEncoding("utf8");
  child.stdout.on("data", (chunk) => {
    stdout += chunk;
    if (stdout.length > 100_000) child.kill("SIGTERM");
  });
  child.stderr.on("data", (chunk) => {
    stderr += chunk;
    if (stderr.length > 4000) stderr = stderr.slice(-4000);
  });
  child.on("error", (error) => {
    clearTimeout(timeout);
    sendJSON(response, 503, { error: `Could not start the Swift meter: ${error.message}` });
  });
  child.on("close", (exitCode) => {
    clearTimeout(timeout);
    if (response.writableEnded) return;
    if (exitCode !== 0) {
      return sendJSON(response, 503, {
        error: failureMessage,
        detail: stderr.trim()
      });
    }
    try {
      sendJSON(response, 200, JSON.parse(stdout));
    } catch {
      sendJSON(response, 502, { error: "The input measurement returned invalid JSON." });
    }
  });
}

function measureInputLevel(response, channel) {
  return runInputMeasurement(
    response,
    ["--measure-input", String(channel)],
    "The 2-second input measurement failed."
  );
}

function measureAllInputLevels(response) {
  return runInputMeasurement(
    response,
    ["--measure-all-inputs"],
    "The 2-second all-input scan failed."
  );
}

function streamMeters(response, channels, direction = "input") {
  const probeArgumentsForStream = direction === "output"
    ? ["--stream-scarlett-output-meters", channels.join(",")]
    : channels.length === 1
      ? ["--stream-input-meter", String(channels[0])]
      : ["--stream-input-meters", channels.join(",")];
  const child = spawn("swift", probeArguments(...probeArgumentsForStream), {
    cwd: workspaceRoot,
    stdio: ["ignore", "pipe", "pipe"]
  });
  let outputBuffer = "";
  let stderr = "";
  let disconnected = false;

  response.writeHead(200, {
    "Cache-Control": "no-cache, no-transform",
    "Connection": "keep-alive",
    "Content-Type": "text/event-stream; charset=utf-8",
    "X-Accel-Buffering": "no",
    "X-Content-Type-Options": "nosniff"
  });
  response.flushHeaders();

  const stop = () => {
    if (disconnected) return;
    disconnected = true;
    child.kill("SIGTERM");
  };

  response.on("close", stop);
  child.stdout.setEncoding("utf8");
  child.stderr.setEncoding("utf8");
  child.stdout.on("data", (chunk) => {
    outputBuffer += chunk;
    const lines = outputBuffer.split("\n");
    outputBuffer = lines.pop() || "";
    for (const line of lines) {
      if (line.trim() && !response.destroyed) response.write(`data: ${line}\n\n`);
    }
  });
  child.stderr.on("data", (chunk) => {
    stderr += chunk;
    if (stderr.length > 4000) stderr = stderr.slice(-4000);
  });
  child.on("error", (error) => {
    if (disconnected || response.writableEnded) return;
    response.write(`event: probe-error\ndata: ${JSON.stringify({ error: `Could not start the Swift meter: ${error.message}` })}\n\n`);
    response.end();
  });
  child.on("close", (exitCode) => {
    if (disconnected || response.writableEnded) return;
    if (outputBuffer.trim() && exitCode === 0) response.write(`data: ${outputBuffer}\n\n`);
    if (exitCode !== 0) {
      response.write(`event: probe-error\ndata: ${JSON.stringify({ error: `The live ${direction} meter stopped.`, detail: stderr.trim() })}\n\n`);
    }
    response.end();
  });
}

const server = createServer(async (request, response) => {
  let pathname;
  let parsedURL;
  try {
    parsedURL = new URL(request.url || "/", `http://${host}:${port}`);
    pathname = decodeURIComponent(parsedURL.pathname);
  } catch {
    response.writeHead(400);
    return response.end("Invalid URL.\n");
  }

  if (pathname === "/api/live-input-meter") {
    if (request.method !== "GET") {
      response.writeHead(405, { Allow: "GET" });
      return response.end("The live input meter uses GET with a server-sent event stream.\n");
    }
    const channel = Number(parsedURL.searchParams.get("channel"));
    if (channel !== 1) {
      return sendJSON(response, 400, { error: "The live meter currently supports Input 1 only." });
    }
    return streamMeters(response, [channel]);
  }

  if (pathname === "/api/live-input-meters") {
    if (request.method !== "GET") {
      response.writeHead(405, { Allow: "GET" });
      return response.end("Live input meters use GET with a server-sent event stream.\n");
    }
    const channelValues = parsedURL.searchParams.get("channels")?.split(",") || [];
    const channels = channelValues.map(Number);
    if (channels.length === 0 || channels.some((channel) => !Number.isInteger(channel) || channel < 1 || channel > 18)
        || new Set(channels).size !== channels.length) {
      return sendJSON(response, 400, { error: "Choose unique CoreAudio input channels from 1 to 18." });
    }
    return streamMeters(response, channels);
  }

  if (pathname === "/api/output-tone") {
    if (request.method !== "POST") {
      response.writeHead(405, { Allow: "POST" });
      return response.end("Scarlett output tone requires an explicit POST action.\n");
    }

    const chunks = [];
    let bodySize = 0;
    for await (const chunk of request) {
      bodySize += chunk.length;
      if (bodySize > 1024) {
        response.writeHead(413);
        return response.end("Request body is too large.\n");
      }
      chunks.push(chunk);
    }

    let input;
    try {
      input = JSON.parse(Buffer.concat(chunks).toString("utf8"));
    } catch {
      return sendJSON(response, 400, { error: "Expected a Scarlett output channel, frequency, and duration." });
    }
    const channel = Number(input.channel);
    const frequencyHz = Number(input.frequencyHz);
    const durationMilliseconds = Number(input.durationMilliseconds);
    if (!Number.isInteger(channel) || channel < 1 || channel > 8
        || !Number.isFinite(frequencyHz) || frequencyHz < 20 || frequencyHz > 20_000
        || !Number.isInteger(durationMilliseconds) || durationMilliseconds < 100 || durationMilliseconds > 10_000) {
      return sendJSON(response, 400, { error: "Choose output 1-8, 20-20000 Hz, and a duration from 100-10000 ms." });
    }
    return runProbeCommand(
      response,
      ["--play-scarlett-output-tone", String(channel), String(frequencyHz), String(durationMilliseconds)],
      "Could not play the Scarlett output tone."
    );
  }

  if (pathname === "/api/live-output-meter") {
    if (request.method !== "GET") {
      response.writeHead(405, { Allow: "GET" });
      return response.end("The Scarlett output meter uses GET with a server-sent event stream.\n");
    }
    return streamMeters(response, [1, 2, 3, 4, 5, 6, 7, 8], "output");
  }

  if (pathname === "/api/input-scan") {
    if (request.method !== "POST") {
      response.writeHead(405, { Allow: "POST" });
      return response.end("An all-input scan requires an explicit POST action.\n");
    }
    return measureAllInputLevels(response);
  }

  if (pathname === "/api/input-meter") {
    if (request.method !== "POST") {
      response.writeHead(405, { Allow: "POST" });
      return response.end("Input measurement requires an explicit POST action.\n");
    }

    const chunks = [];
    let bodySize = 0;
    for await (const chunk of request) {
      bodySize += chunk.length;
      if (bodySize > 1024) {
        response.writeHead(413);
        return response.end("Request body is too large.\n");
      }
      chunks.push(chunk);
    }

    let input;
    try {
      input = JSON.parse(Buffer.concat(chunks).toString("utf8"));
    } catch {
      return sendJSON(response, 400, { error: "Expected JSON with an input channel." });
    }
    const channel = Number(input.channel);
    if (!Number.isInteger(channel) || channel < 1 || channel > 18) {
      return sendJSON(response, 400, { error: "Input channel must be between 1 and 18." });
    }
    return measureInputLevel(response, channel);
  }

  if (pathname === "/api/default-output") {
    if (request.method !== "POST") {
      response.writeHead(405, { Allow: "POST" });
      return response.end("Changing the macOS default output requires an explicit POST action.\n");
    }

    const chunks = [];
    let bodySize = 0;
    for await (const chunk of request) {
      bodySize += chunk.length;
      if (bodySize > 1024) {
        response.writeHead(413);
        return response.end("Request body is too large.\n");
      }
      chunks.push(chunk);
    }

    let input;
    try {
      input = JSON.parse(Buffer.concat(chunks).toString("utf8"));
    } catch {
      return sendJSON(response, 400, { error: "Expected a CoreAudio output device ID." });
    }
    const deviceID = Number(input.deviceID);
    if (!Number.isInteger(deviceID) || deviceID < 1 || deviceID > 0xFFFFFFFF) {
      return sendJSON(response, 400, { error: "Choose an available CoreAudio output device." });
    }
    return runProbeCommand(
      response,
      ["--set-default-output", String(deviceID)],
      "Could not change the macOS default output."
    );
  }

  if (pathname === "/api/default-input") {
    if (request.method !== "POST") {
      response.writeHead(405, { Allow: "POST" });
      return response.end("Changing the macOS default input requires an explicit POST action.\n");
    }

    const chunks = [];
    let bodySize = 0;
    for await (const chunk of request) {
      bodySize += chunk.length;
      if (bodySize > 1024) {
        response.writeHead(413);
        return response.end("Request body is too large.\n");
      }
      chunks.push(chunk);
    }

    let input;
    try {
      input = JSON.parse(Buffer.concat(chunks).toString("utf8"));
    } catch {
      return sendJSON(response, 400, { error: "Expected a CoreAudio input device ID." });
    }
    const deviceID = Number(input.deviceID);
    if (!Number.isInteger(deviceID) || deviceID < 1 || deviceID > 0xFFFFFFFF) {
      return sendJSON(response, 400, { error: "Choose an available CoreAudio input device." });
    }
    return runProbeCommand(
      response,
      ["--set-default-input", String(deviceID)],
      "Could not change the macOS default input."
    );
  }

  if (pathname === "/api/sample-rate") {
    if (request.method !== "POST") {
      response.writeHead(405, { Allow: "POST" });
      return response.end("Changing the Scarlett sample rate requires an explicit POST action.\n");
    }

    const chunks = [];
    let bodySize = 0;
    for await (const chunk of request) {
      bodySize += chunk.length;
      if (bodySize > 1024) {
        response.writeHead(413);
        return response.end("Request body is too large.\n");
      }
      chunks.push(chunk);
    }

    let input;
    try {
      input = JSON.parse(Buffer.concat(chunks).toString("utf8"));
    } catch {
      return sendJSON(response, 400, { error: "Expected a device ID and sample rate in Hz." });
    }
    const deviceID = Number(input.deviceID);
    const sampleRateHz = Number(input.sampleRateHz);
    if (!Number.isInteger(deviceID) || deviceID < 1 || deviceID > 0xFFFFFFFF || !Number.isFinite(sampleRateHz)) {
      return sendJSON(response, 400, { error: "Choose a valid Scarlett device ID and sample rate." });
    }
    return runProbeCommand(
      response,
      ["--set-scarlett-sample-rate", String(deviceID), String(sampleRateHz)],
      "Could not change the Scarlett sample rate."
    );
  }

  if (pathname === "/api/clock-source") {
    if (request.method !== "POST") {
      response.writeHead(405, { Allow: "POST" });
      return response.end("Changing the Scarlett clock source requires an explicit POST action.\n");
    }

    const chunks = [];
    let bodySize = 0;
    for await (const chunk of request) {
      bodySize += chunk.length;
      if (bodySize > 1024) {
        response.writeHead(413);
        return response.end("Request body is too large.\n");
      }
      chunks.push(chunk);
    }

    let input;
    try {
      input = JSON.parse(Buffer.concat(chunks).toString("utf8"));
    } catch {
      return sendJSON(response, 400, { error: "Expected a Scarlett device ID and clock-source ID." });
    }
    const deviceID = Number(input.deviceID);
    const sourceID = Number(input.sourceID);
    if (!Number.isInteger(deviceID) || deviceID < 1 || deviceID > 0xFFFFFFFF
        || !Number.isInteger(sourceID) || sourceID < 0 || sourceID > 0xFFFFFFFF) {
      return sendJSON(response, 400, { error: "Choose a valid Scarlett device and supported clock source." });
    }
    return runProbeCommand(
      response,
      ["--set-scarlett-clock-source", String(deviceID), String(sourceID)],
      "Could not change the Scarlett clock source."
    );
  }

  if (pathname === "/api/input-pad") {
    const channelFromQuery = Number(parsedURL.searchParams.get("channel"));
    if (request.method === "GET") {
      if (!Number.isInteger(channelFromQuery) || channelFromQuery < 1 || channelFromQuery > 4) {
        return sendJSON(response, 400, { error: "PAD status is supported only on analog inputs 1-4." });
      }
      return runProbeCommand(
        response,
        ["--read-input-pad", String(channelFromQuery)],
        "Could not read the Scarlett input PAD state."
      );
    }
    if (request.method !== "POST") {
      response.writeHead(405, { Allow: "GET, POST" });
      return response.end("Input PAD accepts GET for read and POST for an explicit change.\n");
    }

    const chunks = [];
    let bodySize = 0;
    for await (const chunk of request) {
      bodySize += chunk.length;
      if (bodySize > 1024) {
        response.writeHead(413);
        return response.end("Request body is too large.\n");
      }
      chunks.push(chunk);
    }
    let input;
    try {
      input = JSON.parse(Buffer.concat(chunks).toString("utf8"));
    } catch {
      return sendJSON(response, 400, { error: "Expected an input channel and PAD state." });
    }
    const channel = Number(input.channel);
    if (!Number.isInteger(channel) || channel < 1 || channel > 4 || typeof input.enabled !== "boolean") {
      return sendJSON(response, 400, { error: "Choose input 1-4 and PAD enabled true or false." });
    }
    return runProbeCommand(
      response,
      ["--set-input-pad", String(channel), input.enabled ? "on" : "off"],
      "Could not change the Scarlett input PAD state."
    );
  }

  if (pathname === "/api/input-mode") {
    const channelFromQuery = Number(parsedURL.searchParams.get("channel"));
    if (request.method === "GET") {
      if (!Number.isInteger(channelFromQuery) || channelFromQuery < 1 || channelFromQuery > 2) {
        return sendJSON(response, 400, { error: "Line/Inst mode is supported only on inputs 1 and 2." });
      }
      return runProbeCommand(
        response,
        ["--read-input-mode", String(channelFromQuery)],
        "Could not read the Scarlett input mode."
      );
    }
    if (request.method !== "POST") {
      response.writeHead(405, { Allow: "GET, POST" });
      return response.end("Input mode accepts GET for read and POST for an explicit Line/Inst change.\n");
    }

    const chunks = [];
    let bodySize = 0;
    for await (const chunk of request) {
      bodySize += chunk.length;
      if (bodySize > 1024) {
        response.writeHead(413);
        return response.end("Request body is too large.\n");
      }
      chunks.push(chunk);
    }
    let input;
    try {
      input = JSON.parse(Buffer.concat(chunks).toString("utf8"));
    } catch {
      return sendJSON(response, 400, { error: "Expected JSON with channel and mode." });
    }
    const channel = Number(input.channel);
    const mode = String(input.mode || "").toLowerCase();
    if (!Number.isInteger(channel) || channel < 1 || channel > 2 || !["line", "inst"].includes(mode)) {
      return sendJSON(response, 400, { error: "Choose input 1 or 2 and mode line or inst." });
    }
    return runProbeCommand(
      response,
      ["--set-input-mode", String(channel), mode],
      "Could not change the Scarlett input mode."
    );
  }

  if (request.method !== "GET") {
    response.writeHead(405, { Allow: "GET" });
    return response.end("Only GET requests are supported except for the explicit input-meter POST.\n");
  }

  if (pathname === "/api/device") return readDeviceSnapshot(response);
  if (pathname === "/api/input-gain") {
    const channel = Number(parsedURL.searchParams.get("channel"));
    if (!Number.isInteger(channel) || channel < 1 || channel > 8) {
      return sendJSON(response, 400, { error: "Input channel must be between 1 and 8." });
    }
    return readInputGain(response, channel);
  }

  let relativePath;
  if (pathname === "/" || pathname === "/playground.html") {
    relativePath = "playground.html";
  } else if (pathname.startsWith("/target/")) {
    relativePath = pathname.slice(1);
  } else {
    response.writeHead(404);
    return response.end("Not found.\n");
  }

  const filePath = resolve(workspaceRoot, relativePath);
  const pathFromRoot = relative(workspaceRoot, filePath);
  if (isAbsolute(pathFromRoot) || pathFromRoot === ".." || pathFromRoot.startsWith(`..${sep}`)) {
    response.writeHead(404);
    return response.end("Not found.\n");
  }

  try {
    const resolvedPath = await realpath(filePath);
    const resolvedRelativePath = relative(workspaceRoot, resolvedPath);
    if (isAbsolute(resolvedRelativePath) || resolvedRelativePath === ".." || resolvedRelativePath.startsWith(`..${sep}`)) {
      response.writeHead(404);
      return response.end("Not found.\n");
    }
    const body = await readFile(resolvedPath);
    response.writeHead(200, {
      "Cache-Control": "no-store",
      "Content-Security-Policy": "default-src 'self'; img-src 'self'; style-src 'self' 'unsafe-inline'; script-src 'self' 'unsafe-inline'; connect-src 'self'",
      "Content-Type": mimeTypes.get(extname(resolvedPath)) || "application/octet-stream",
      "X-Content-Type-Options": "nosniff"
    });
    response.end(body);
  } catch {
    response.writeHead(404);
    response.end("Not found.\n");
  }
});

server.listen(port, host, () => {
  console.log(`Scarlett read-only playground: http://${host}:${port}/`);
});

server.on("error", (error) => {
  console.error(`Playground server failed: ${error.message}`);
  process.exitCode = 1;
});