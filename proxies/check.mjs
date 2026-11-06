// Real connectivity check through a proxy: CONNECT, then TLS with certificate validation, so a proxy
// that intercepts TLS fails. Only anonymous requests are sent; no Discord token or account is involved.
import net from "node:net";
import tls from "node:tls";
import { parseTraceCountry } from "./lib.mjs";

export function connectTunnel(server, host, timeoutMs) {
  const [proxyHost, proxyPort] = server.split(":");
  return new Promise((resolve, reject) => {
    const socket = net.connect(Number(proxyPort), proxyHost);
    const fail = err => { socket.destroy(); reject(err); };
    socket.setTimeout(timeoutMs, () => fail(new Error("timeout")));
    socket.once("error", fail);
    socket.once("close", () => reject(new Error("closed")));
    let head = "";
    const onData = chunk => {
      head += chunk.toString("latin1");
      if (head.length > 16384) return fail(new Error("oversized response"));
      if (!head.includes("\r\n\r\n")) return;
      socket.off("data", onData);
      if (!/^HTTP\/1\.[01] 200\b/.test(head)) return fail(new Error(head.split("\r\n")[0]));
      socket.removeAllListeners("close");
      socket.removeAllListeners("error");
      socket.setTimeout(0);
      resolve(socket);
    };
    socket.on("data", onData);
    socket.once("connect", () => socket.write(`CONNECT ${host}:443 HTTP/1.1\r\nHost: ${host}:443\r\n\r\n`));
  });
}

async function httpsThrough(server, host, path, timeoutMs) {
  const raw = await connectTunnel(server, host, timeoutMs);
  return new Promise((resolve, reject) => {
    const socket = tls.connect({ socket: raw, servername: host, rejectUnauthorized: true });
    const fail = err => { socket.destroy(); raw.destroy(); reject(err); };
    socket.setTimeout(timeoutMs, () => fail(new Error("timeout")));
    socket.once("error", fail);
    let body = "";
    socket.on("data", chunk => {
      body += chunk.toString("latin1");
      if (body.length > 65536) fail(new Error("oversized response"));
    });
    socket.once("end", () => { socket.destroy(); resolve(body); });
    socket.once("secureConnect", () =>
      socket.write(`GET ${path} HTTP/1.1\r\nHost: ${host}\r\nUser-Agent: Mozilla/5.0\r\nConnection: close\r\n\r\n`));
  });
}

const status = response => Number(/^HTTP\/1\.[01] (\d{3})/.exec(response)?.[1]);

export async function checkProxy(server, timeoutMs = 8000) {
  const started = Date.now();
  // Discord must accept the exit IP: blocklisted proxies get a 403 or 429 here.
  const api = await httpsThrough(server, "discord.com", "/api/v9/gateway", timeoutMs);
  if (status(api) !== 200 || !api.includes("gateway.discord.gg")) return null;
  const latencyMs = Date.now() - started;

  const gateway = await connectTunnel(server, "gateway.discord.gg", timeoutMs);
  gateway.destroy();

  // discord.com answers 403 on /cdn-cgi/trace. Same Cloudflare geolocation, different zone.
  const trace = await httpsThrough(server, "www.cloudflare.com", "/cdn-cgi/trace", timeoutMs);
  return { country: parseTraceCountry(trace), latencyMs };
}
