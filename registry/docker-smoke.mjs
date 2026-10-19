// Exercise the real Docker authentication flow against a disposable local
// Worker/R2 instance. No Cloudflare account or production password is used.
import { spawn } from "node:child_process";
import { randomBytes } from "node:crypto";
import { mkdtemp, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { fileURLToPath } from "node:url";
import { Miniflare, Log, LogLevel } from "miniflare";

const image = process.argv[2];
if (!image) throw new Error("Usage: node registry/docker-smoke.mjs SOURCE_IMAGE");
const work = await mkdtemp(join(tmpdir(), "raz-docker-registry-"));
const password = randomBytes(32).toString("hex");
const mf = new Miniflare({
  modules: true,
  scriptPath: fileURLToPath(new URL("dist/worker.mjs", import.meta.url)),
  compatibilityDate: "2026-07-30",
  host: "127.0.0.1",
  port: 0,
  r2Buckets: ["REGISTRY"],
  bindings: { REGISTRY_USERNAME: "publisher", REGISTRY_PASSWORD: password },
  log: new Log(LogLevel.ERROR),
});

function docker(args, input) {
  return new Promise((resolve, reject) => {
    const child = spawn("docker", args, {
      stdio: [input ? "pipe" : "ignore", "inherit", "inherit"],
      timeout: 300_000,
    });
    if (input) child.stdin.end(input);
    child.on("error", reject);
    child.on("exit", (code) => code === 0 ? resolve() : reject(new Error(`docker ${args[0]} exited ${code}`)));
  });
}

let target;
try {
  const address = await mf.ready;
  const registry = `localhost:${address.port}`;
  target = `${registry}/raz:local-smoke-${Date.now()}`;
  await docker(["--config", work, "login", registry, "--username", "publisher", "--password-stdin"], password);
  await docker(["tag", image, target]);
  await docker(["--config", work, "push", target]);
  // Remove just this test's alias. The source image and its tags stay intact.
  await docker(["image", "rm", target]);
  const anonymous = await mkdtemp(join(work, "anonymous-"));
  await docker(["--config", anonymous, "pull", target]);
  await docker(["--config", anonymous, "run", "--rm", target, "sh", "/usr/local/share/raz-ci/smoke.sh"]);
  console.log("Authenticated Docker push and anonymous pull/run passed.");
} finally {
  if (target) await docker(["image", "rm", target]).catch(() => {});
  await mf.dispose();
  await rm(work, { recursive: true, force: true });
}
