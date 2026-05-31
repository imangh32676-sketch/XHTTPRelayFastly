/// <reference types="@fastly/js-compute" />

import { CacheOverride } from "fastly:cache-override";
import { ConfigStore } from "fastly:config-store";

const ALLOWED_METHODS = new Set(["GET", "HEAD", "POST"]);

const FORWARD_HEADER_EXACT = new Set([
  "accept", "accept-encoding", "accept-language", "cache-control",
  "content-length", "content-type", "pragma", "range", "referer", "user-agent",
]);
const FORWARD_HEADER_PREFIXES = ["sec-ch-", "sec-fetch-"];

addEventListener("fetch", (event) => {
  event.respondWith(handleRequest(event.request));
});

async function handleRequest(request) {
  // Config Store is a runtime API - must be called inside handler, not at module level
  let TARGET_BASE, TARGET_HOSTNAME, RELAY_PATH;
  try {
    const store = new ConfigStore("relay_config");
    TARGET_BASE     = store.get("TARGET_BASE")     || "https://example.com:443";
    TARGET_HOSTNAME = store.get("TARGET_HOSTNAME") || "example.com";
    RELAY_PATH      = store.get("RELAY_PATH")      || "/api";
  } catch (e) {
    return textResponse("Config error: " + String(e), 500);
  }

  const PUBLIC_RELAY_PATH = RELAY_PATH;

  const url      = new URL(request.url);
  const pathname = normalizePath(url.pathname);

  if (!isAllowedRelayPath(pathname, PUBLIC_RELAY_PATH))
    return textResponse("Not Found", 404);

  if (!ALLOWED_METHODS.has(request.method))
    return textResponse("Method Not Allowed", 405, { Allow: "GET, HEAD, POST" });

  const upstreamPath = mapPath(pathname, PUBLIC_RELAY_PATH, RELAY_PATH);
  const targetUrl    = TARGET_BASE + upstreamPath + url.search;
  const headers      = forwardHeaders(request.headers, TARGET_HOSTNAME);

  let upstream;
  try {
    upstream = await fetch(targetUrl, {
      method: request.method,
      headers,
      body: request.method === "GET" || request.method === "HEAD" ? null : request.body,
      cacheOverride: new CacheOverride("pass"),
    });
  } catch (err) {
    return textResponse("Bad Gateway: " + String(err), 502);
  }

  const responseHeaders = new Headers();
  for (const [key, value] of upstream.headers) {
    const k = key.toLowerCase();
    if (k === "transfer-encoding" || k === "connection") continue;
    responseHeaders.set(key, value);
  }
  responseHeaders.set("Cache-Control", "no-store, no-cache, must-revalidate, max-age=0");
  responseHeaders.set("CDN-Cache-Control", "no-store");

  return new Response(upstream.body, { status: upstream.status, headers: responseHeaders });
}

function forwardHeaders(inputHeaders, hostname) {
  const headers = new Headers();
  for (const [key, value] of inputHeaders) {
    const lower = key.toLowerCase();
    if (shouldForward(lower)) headers.set(key, value);
  }
  headers.set("Host", hostname);
  return headers;
}

function shouldForward(name) {
  if (FORWARD_HEADER_EXACT.has(name)) return true;
  for (const p of FORWARD_HEADER_PREFIXES) if (name.startsWith(p)) return true;
  return false;
}

function normalizePath(pathname) {
  let out = String(pathname || "/").replace(/\/{2,}/g, "/");
  if (!out.startsWith("/")) out = "/" + out;
  if (out.length > 1 && out.endsWith("/")) out = out.slice(0, -1);
  return out;
}

function isAllowedRelayPath(pathname, publicPath) {
  return pathname === publicPath || pathname.startsWith(publicPath + "/");
}

function mapPath(pathname, publicPath, relayPath) {
  if (pathname === publicPath) return relayPath;
  return relayPath + pathname.slice(publicPath.length);
}

function textResponse(body, status, extraHeaders) {
  const headers = new Headers(extraHeaders || {});
  headers.set("Content-Type", "text/plain; charset=utf-8");
  headers.set("Cache-Control", "no-store");
  return new Response(body, { status, headers });
}
