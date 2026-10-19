// The upstream implements the Docker registry protocol and R2 storage.
// This adapter exposes anonymous pulls for raz alone. All uploads still
// pass through upstream authentication; its public identity has only pull.
import registry, { type Env as RegistryEnv } from "r2-registry";
import { UserAuthenticator } from "r2-registry/src/user";

interface Env {
  REGISTRY: R2Bucket;
  REGISTRY_USERNAME: string;
  REGISTRY_PASSWORD?: string;
}

const anonymousUser = "__anonymous_pull__";
const anonymousPassword = "public-read-only";
const publicPath = /^\/v2\/raz\/(?:manifests\/[^/]+|blobs\/[^/]+|tags\/list|referrers\/[^/]+)$/;
const uploadPath = /^\/v2\/raz\/blobs\/uploads\/(?:[^/]+)?$/;

const encoder = new TextEncoder();
const tokenLifetime = 300;
const encode = (bytes: Uint8Array) => btoa(String.fromCharCode(...bytes)).replace(/=/g, "").replace(/\+/g, "-").replace(/\//g, "_");
const decode = (text: string) => Uint8Array.from(atob(text.replace(/-/g, "+").replace(/_/g, "/")), (c) => c.charCodeAt(0));

// One secret serves as publisher password and token signing key. Rotation
// revokes both. Without a configured password, only public pulls can work.
async function tokenKey(env: Env) {
  return crypto.subtle.importKey("raw", encoder.encode(env.REGISTRY_PASSWORD || anonymousPassword),
    { name: "HMAC", hash: "SHA-256" }, false, ["sign", "verify"]);
}

function challenge(request: Request): Response {
  const url = new URL(request.url);
  const scope = url.pathname === "/v2/" ? "" : ',scope="repository:raz:pull,push"';
  return new Response(JSON.stringify({ errors: [{ code: "UNAUTHORIZED", message: "authentication required" }] }), {
    status: 401,
    headers: {
      "Content-Type": "application/json",
      "Docker-Distribution-Api-Version": "registry/2.0",
      "WWW-Authenticate": `Bearer realm="${url.origin}/token",service="${url.host}"${scope}`,
    },
  });
}

async function issueToken(request: Request, env: Env): Promise<Response> {
  if (request.method !== "GET") return new Response(null, { status: 405, headers: { Allow: "GET" } });
  const url = new URL(request.url);
  if (url.searchParams.has("service") && url.searchParams.get("service") !== url.host) {
    return new Response("Unknown service\n", { status: 400 });
  }
  const scopes = url.searchParams.getAll("scope");
  if (scopes.length > 1 || (scopes.length && !/^repository:raz:(pull|push)(,(pull|push))*$/.test(scopes[0]))) {
    return new Response("Unknown scope\n", { status: 400 });
  }
  let publisher = false;
  if (request.headers.has("Authorization")) {
    const credentials = env.REGISTRY_PASSWORD ? [{
      username: env.REGISTRY_USERNAME, password: env.REGISTRY_PASSWORD, capabilities: ["pull", "push"] as ("pull" | "push")[],
    }] : [];
    publisher = (await new UserAuthenticator(credentials).checkCredentials(request)).verified;
    if (!publisher) return challenge(request);
  }
  const requested = scopes.length ? scopes[0].split(":")[2].split(",") : ["pull", "push"];
  const actions = requested.filter((action) => action === "pull" || publisher);
  const now = Math.floor(Date.now() / 1000);
  const header = encode(encoder.encode(JSON.stringify({ alg: "HS256", typ: "JWT" })));
  const payload = encode(encoder.encode(JSON.stringify({
    iss: "raz-registry", aud: url.host, iat: now, exp: now + tokenLifetime,
    access: [{ type: "repository", name: "raz", actions }],
  })));
  const message = `${header}.${payload}`;
  const signature = encode(new Uint8Array(await crypto.subtle.sign("HMAC", await tokenKey(env), encoder.encode(message))));
  return Response.json({ token: `${message}.${signature}`, expires_in: tokenLifetime, issued_at: new Date().toISOString() }, {
    headers: { "Cache-Control": "no-store" },
  });
}

async function bearerActions(request: Request, env: Env): Promise<string[] | null> {
  try {
    const token = request.headers.get("Authorization")!.slice(7).split(".");
    if (token.length !== 3) return null;
    const valid = await crypto.subtle.verify("HMAC", await tokenKey(env), decode(token[2]), encoder.encode(`${token[0]}.${token[1]}`));
    if (!valid) return null;
    const header = JSON.parse(new TextDecoder().decode(decode(token[0])));
    const payload = JSON.parse(new TextDecoder().decode(decode(token[1])));
    if (header.alg !== "HS256" || payload.iss !== "raz-registry" || payload.aud !== new URL(request.url).host
      || !Number.isFinite(payload.exp) || payload.exp <= Date.now() / 1000) return null;
    const access = payload.access?.find((entry: { type: string; name: string }) => entry.type === "repository" && entry.name === "raz");
    return Array.isArray(access?.actions) ? access.actions : null;
  } catch {
    return null;
  }
}

export default {
  async fetch(request: Request, env: Env, context: ExecutionContext): Promise<Response> {
    const path = new URL(request.url).pathname;
    if (path === "/token") return issueToken(request, env);
    const ping = path === "/v2/";
    const pull = request.method === "GET" || request.method === "HEAD";
    if (!ping && !publicPath.test(path) && !uploadPath.test(path)) {
      return new Response("Not found\n", { status: 404 });
    }

    const headers = new Headers(request.headers);
    const authorization = headers.get("Authorization");
    if (authorization?.startsWith("Bearer ")) {
      const actions = await bearerActions(request, env);
      const permitted = actions && (ping || request.method === "HEAD"
        ? actions.includes("pull") || actions.includes("push")
        : actions.includes(pull ? "pull" : "push"));
      if (!permitted) return challenge(request);
      const publisher = !pull && env.REGISTRY_PASSWORD && actions!.includes("push");
      if (!pull && !publisher) return challenge(request);
      const user = publisher ? env.REGISTRY_USERNAME : anonymousUser;
      const password = publisher ? env.REGISTRY_PASSWORD! : anonymousPassword;
      headers.set("Authorization", `Basic ${btoa(`${user}:${password}`)}`);
    } else if (ping && !authorization) {
      // Docker discovers authentication at the initial ping. Returning 200
      // here makes it omit credentials on subsequent uploads.
      return challenge(request);
    } else if (pull && publicPath.test(path) && !authorization) {
      headers.set("Authorization", `Basic ${btoa(`${anonymousUser}:${anonymousPassword}`)}`);
    }
    const forwarded = new Request(request, {
      headers,
      method: ping && request.method === "HEAD" ? "GET" : request.method,
    });
    // REGISTRY_CLIENT is initialized by the upstream fetch handler. Do not
    // pass fallback registries or other credentials into this public service.
    const registryEnv = {
      REGISTRY: env.REGISTRY,
      ENVIRONMENT: "production",
      USERNAME: env.REGISTRY_USERNAME,
      PASSWORD: env.REGISTRY_PASSWORD,
      READONLY_USERNAME: anonymousUser,
      READONLY_PASSWORD: anonymousPassword,
      PUSH_COMPATIBILITY_MODE: "full",
    } as RegistryEnv;
    const response = await registry.fetch(forwarded, registryEnv, context);
    if (response.status === 401) return challenge(request);
    const responseHeaders = new Headers(response.headers);
    responseHeaders.set("Docker-Distribution-Api-Version", "registry/2.0");
    return new Response(request.method === "HEAD" ? null : response.body, {
      status: response.status,
      statusText: response.statusText,
      headers: responseHeaders,
    });
  },
} satisfies ExportedHandler<Env>;
