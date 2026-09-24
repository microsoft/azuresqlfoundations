"use strict";

const assert = require("node:assert/strict");
const { spawn } = require("node:child_process");
const { test } = require("node:test");

const variants = [
  { kind: "customer", port: 3211, title: "Personal Loans", script: "customer.js", blockedPath: "/api/operations/dashboard" },
  { kind: "internal", port: 3212, title: "Operations Console", script: "operations.js", blockedPath: "/api/ai/search" },
  { kind: "internal-ai", port: 3213, title: "Operations Console", script: "ai.js", blockedPath: "/api/rates" }
];

async function startServer(variant) {
  const child = spawn(process.execPath, ["server.js"], {
    cwd: process.cwd(),
    env: {
      ...process.env,
      APP_KIND: variant.kind,
      PORT: String(variant.port),
      AZURE_SQL_SERVER: "test-server",
      AZURE_SQL_DATABASE: "test-database"
    },
    stdio: ["ignore", "pipe", "pipe"]
  });

  let stderr = "";
  child.stderr.on("data", chunk => { stderr += chunk; });
  await new Promise((resolve, reject) => {
    const timeout = setTimeout(() => reject(new Error(`Server startup timed out: ${stderr}`)), 10000);
    child.stdout.on("data", chunk => {
      if (chunk.toString().includes("listening")) {
        clearTimeout(timeout);
        resolve();
      }
    });
    child.once("exit", code => {
      clearTimeout(timeout);
      reject(new Error(`Server exited with code ${code}: ${stderr}`));
    });
  });
  return child;
}

async function stopServer(child) {
  if (child.exitCode !== null) return;
  child.kill();
  await new Promise(resolve => child.once("exit", resolve));
}

test("each App Service variant serves its UI and isolates APIs", async () => {
  for (const variant of variants) {
    const child = await startServer(variant);
    try {
      const baseUrl = `http://127.0.0.1:${variant.port}`;
      const page = await fetch(`${baseUrl}/`);
      assert.equal(page.status, 200);
      assert.match(await page.text(), new RegExp(variant.title));

      const script = await fetch(`${baseUrl}/shared/${variant.script}`);
      assert.equal(script.status, 200);

      const blocked = await fetch(`${baseUrl}${variant.blockedPath}`, {
        method: variant.blockedPath === "/api/operations/dashboard" ? "GET" : "POST",
        headers: { "Content-Type": "application/json" },
        body: variant.blockedPath === "/api/operations/dashboard" ? undefined : "{}"
      });
      assert.equal(blocked.status, 404);
    } finally {
      await stopServer(child);
    }
  }
});

test("customer rate validation rejects invalid income before database access", async () => {
  const variant = variants[0];
  const child = await startServer({ ...variant, port: 3214 });
  try {
    const response = await fetch("http://127.0.0.1:3214/api/rates", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ amount: 25000, income: 0, creditScore: 775, loanType: "Auto" })
    });
    assert.equal(response.status, 400);
    assert.deepEqual(await response.json(), { error: "Annual income must be greater than zero." });
  } finally {
    await stopServer(child);
  }
});