import assert from "node:assert/strict";
import { createHash, createHmac } from "node:crypto";
import { after, before, test } from "node:test";
import { Miniflare, Log, LogLevel } from "miniflare";

const origin = "https://registry.test";
const authorization = `Basic ${Buffer.from("publisher:test-only-password").toString("base64")}`;
const readonly = `Basic ${Buffer.from("__anonymous_pull__:public-read-only").toString("base64")}`;
const digest = (bytes) => `sha256:${createHash("sha256").update(bytes).digest("hex")}`;
let mf;

before(async () => {
  mf = new Miniflare({
    modules: true,
    scriptPath: "dist/worker.mjs",
    compatibilityDate: "2026-07-30",
    r2Buckets: ["REGISTRY"],
    bindings: { REGISTRY_USERNAME: "publisher", REGISTRY_PASSWORD: "test-only-password" },
    log: new Log(LogLevel.ERROR),
  });
  await mf.ready;
});
after(async () => mf?.dispose());

async function request(path, method = "GET", auth, body, headers = {}) {
  if (auth) headers.Authorization = auth;
  return mf.dispatchFetch(new URL(path, origin), { method, headers, body });
}

async function upload(bytes) {
  let response = await request("/v2/raz/blobs/uploads/", "POST", authorization);
  assert.equal(response.status, 202, await response.text());
  let location = response.headers.get("Location");
  response = await request(location, "PATCH", authorization, bytes, {
    "Content-Type": "application/octet-stream",
    "Content-Length": String(bytes.length),
  });
  assert.equal(response.status, 202, await response.text());
  location = new URL(response.headers.get("Location"), origin);
  location.searchParams.set("digest", digest(bytes));
  response = await request(location, "PUT", authorization, undefined, { "Content-Length": "0" });
  assert.equal(response.status, 201, await response.text());
  return digest(bytes);
}

test("Docker discovers Bearer authentication and gets an anonymous pull token", async () => {
  const challenge = await request("/v2/");
  assert.equal(challenge.status, 401);
  assert.match(challenge.headers.get("WWW-Authenticate"), /^Bearer realm="https:\/\/registry.test\/token"/);
  const token = (await (await request("/token?service=registry.test&scope=repository:raz:pull")).json()).token;
  for (const method of ["GET", "HEAD"]) {
    const response = await request("/v2/", method, `Bearer ${token}`);
    assert.equal(response.status, 200);
    assert.equal(response.headers.get("Docker-Distribution-Api-Version"), "registry/2.0");
  }
});

test("supplied credentials are validated, including during docker login", async () => {
  assert.equal((await request("/v2/", "GET", authorization)).status, 200);
  const response = await request("/v2/", "GET", "Basic d3Jvbmc6d3Jvbmc=");
  assert.equal(response.status, 401);
  assert.match(response.headers.get("WWW-Authenticate"), /Bearer/);
});

test("anonymous tokens have pull permission only", async () => {
  const response = await request("/token?scope=repository:raz:pull,push");
  assert.equal(response.status, 200);
  assert.equal(response.headers.get("Cache-Control"), "no-store");
  const auth = `Bearer ${(await response.json()).token}`;
  assert.equal((await request("/v2/", "GET", auth)).status, 200);
  assert.equal((await request("/v2/raz/blobs/uploads/", "POST", auth)).status, 401);
});

test("publisher tokens authorize uploads, respecting requested scope", async () => {
  for (const actions of ["pull,push", "pull"]) {
    const token = await request(`/token?scope=repository:raz:${actions}`, "GET", authorization);
    assert.equal(token.status, 200);
    const response = await request("/v2/raz/blobs/uploads/", "POST", `Bearer ${(await token.json()).token}`);
    assert.equal(response.status, actions.includes("push") ? 202 : 401);
  }
});

test("token issuance validates credentials, service and repository scope", async () => {
  assert.equal((await request("/token", "GET", "Basic d3Jvbmc6d3Jvbmc=")).status, 401);
  assert.equal((await request("/token?service=other.test")).status, 400);
  assert.equal((await request("/token?scope=repository:other:pull")).status, 400);
  assert.equal((await request("/token?scope=repository:raz:delete")).status, 400);
  assert.equal((await request("/token", "POST")).status, 405);
});

test("expired, tampered and foreign-audience tokens cannot authorize requests", async () => {
  const issued = await request("/token", "GET", authorization);
  const token = (await issued.json()).token;
  for (const invalid of ["invalid", `${token}garbage`]) {
    assert.equal((await request("/v2/", "GET", `Bearer ${invalid}`)).status, 401);
  }
  function signedToken(payload) {
    const header = Buffer.from(JSON.stringify({ alg: "HS256", typ: "JWT" })).toString("base64url");
    const body = Buffer.from(JSON.stringify(payload)).toString("base64url");
    const message = `${header}.${body}`;
    return `${message}.${createHmac("sha256", "test-only-password").update(message).digest("base64url")}`;
  }
  const payload = { iss: "raz-registry", aud: "registry.test", exp: Math.floor(Date.now() / 1000) + 300,
    access: [{ type: "repository", name: "raz", actions: ["pull", "push"] }] };
  for (const changed of [{ exp: 1 }, { aud: "another-registry.test" }, { iss: "someone-else" },
    { access: [{ type: "repository", name: "other", actions: ["push"] }] }]) {
    const auth = `Bearer ${signedToken({ ...payload, ...changed })}`;
    assert.equal((await request("/v2/raz/blobs/uploads/", "POST", auth)).status, 401);
  }
});

test("anonymous and public read-only credentials cannot mutate registry data", async () => {
  for (const auth of [undefined, readonly, "Basic d3Jvbmc6d3Jvbmc="]) {
    for (const [method, path] of [
      ["POST", "/v2/raz/blobs/uploads/"],
      ["PATCH", "/v2/raz/blobs/uploads/unknown"],
      ["PUT", "/v2/raz/manifests/release"],
      ["DELETE", "/v2/raz/manifests/release"],
      ["DELETE", "/v2/raz/blobs/uploads/unknown"],
    ]) {
      const response = await request(path, method, auth);
      assert.equal(response.status, 401, `${method} ${path}`);
    }
  }
});

test("unknown repositories and nested namespaces are not served", async () => {
  for (const path of [
    "/v2/other/manifests/release", "/v2/raz/nested/manifests/release",
    "/v2/_catalog", "/", "/v2/raz/anything",
  ]) {
    assert.equal((await request(path, "GET", authorization)).status, 404, path);
    assert.equal((await request(path, "PUT", authorization)).status, 404, path);
  }
});

test("upload status is not an anonymous read endpoint", async () => {
  assert.equal((await request("/v2/raz/blobs/uploads/unknown")).status, 401);
});

test("a publisher can cancel an incomplete upload", async () => {
  const response = await request("/v2/raz/blobs/uploads/", "POST", authorization);
  assert.equal(response.status, 202);
  assert.equal((await request(response.headers.get("Location"), "DELETE", authorization)).status, 204);
});

test("published OCI manifests and blobs can be pulled without credentials", async () => {
  const config = Buffer.from(JSON.stringify({
    architecture: "amd64", os: "linux", config: {},
    rootfs: { type: "layers", diff_ids: [] }, history: [],
  }));
  const configDigest = await upload(config);
  const manifest = JSON.stringify({
    schemaVersion: 2,
    mediaType: "application/vnd.oci.image.manifest.v1+json",
    config: { mediaType: "application/vnd.oci.image.config.v1+json", digest: configDigest, size: config.length },
    layers: [],
  });
  const path = "/v2/raz/manifests/test-release";
  const response = await request(path, "PUT", authorization, manifest, {
    "Content-Type": "application/vnd.oci.image.manifest.v1+json",
  });
  assert.equal(response.status, 201, await response.text());
  const manifestDigest = response.headers.get("Docker-Content-Digest");
  assert.equal(manifestDigest, digest(manifest));
  for (const reference of ["test-release", manifestDigest]) {
    const get = await request(`/v2/raz/manifests/${reference}`);
    assert.equal(get.status, 200);
    assert.equal(await get.text(), manifest);
    const head = await request(`/v2/raz/manifests/${reference}`, "HEAD");
    assert.equal(head.status, 200);
    assert.equal(head.headers.get("Docker-Content-Digest"), manifestDigest);
  }
  const blob = await request(`/v2/raz/blobs/${configDigest}`);
  assert.equal(blob.status, 200);
  assert.deepEqual(Buffer.from(await blob.arrayBuffer()), config);
  const tags = await request("/v2/raz/tags/list");
  assert.equal(tags.status, 200);
  assert.ok((await tags.json()).tags.includes("test-release"));
});

test("missing manifests return a registry error rather than a login challenge", async () => {
  const response = await request("/v2/raz/manifests/not-published");
  assert.equal(response.status, 404);
  assert.equal(response.headers.has("WWW-Authenticate"), false);
});
