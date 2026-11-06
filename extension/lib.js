// Pure helpers. Provider data is untrusted: only validated public ip:port values leave this file,
// because they end up inside a PAC script.

const IPV4 = /^(\d{1,3})\.(\d{1,3})\.(\d{1,3})\.(\d{1,3})$/;

// Discord hosts sent through the proxy while logging in. Voice (discord.media), CDN and media stay direct.
export const PROXIED_HOSTS = ["discord.com", "discord.gg", "discordapp.com"];
export const DIRECT_HOSTS = ["cdn.discord.com", "cdn.discordapp.com"];
// Needed to read the exit country, since discord.com answers 403 on /cdn-cgi/trace.
export const TRACE_HOST = "www.cloudflare.com";

// With the channel's region on automatic, Discord picks the voice server from the proxy's location,
// so a distant exit means high ping. Closest first.
export const NEAR_COUNTRIES = ["AR", "UY", "PY", "CL", "BO", "PE", "CO", "EC", "VE", "PA", "CR", "MX", "US"];

export function isPublicIpv4(ip) {
  const m = IPV4.exec(ip);
  if (!m) return false;
  const [a, b, c, d] = m.slice(1).map(Number);
  if ([a, b, c, d].some(n => n > 255)) return false;
  return !(
    a === 0 || a === 10 || a === 127 || a >= 224 ||
    (a === 100 && b >= 64 && b <= 127) ||
    (a === 169 && b === 254) ||
    (a === 172 && b >= 16 && b <= 31) ||
    (a === 192 && (b === 0 || b === 168)) ||
    (a === 198 && (b === 18 || b === 19))
  );
}

export function isValidServer(server) {
  if (typeof server !== "string") return false;
  const parts = server.split(":");
  if (parts.length !== 2 || !isPublicIpv4(parts[0]) || !/^\d{1,5}$/.test(parts[1])) return false;
  const port = Number(parts[1]);
  return port >= 1 && port <= 65535;
}

function entry(ip, port, country, score) {
  const server = `${ip}:${port}`;
  const c = String(country ?? "").toUpperCase();
  if (!isValidServer(server) || !/^[A-Z]{2}$/.test(c) || c === "BR") return null;
  return { server, country: c, score: Number(score) || 0 };
}

export const PROVIDERS = [
  {
    name: "proxyscrape",
    url: "https://api.proxyscrape.com/v4/free-proxy-list/get?request=display_proxies&proxy_format=protocolipport&format=json&protocol=http",
    parse: data => data.proxies
      .filter(e => e.alive && e.ssl && e.protocol === "http")
      .map(e => entry(e.ip, e.port, e.ip_data?.countryCode, e.uptime)),
  },
  {
    name: "proxifly",
    url: "https://raw.githubusercontent.com/proxifly/free-proxy-list/main/proxies/protocols/http/data.json",
    // No HTTPS filter: this provider reports `https: false` for every entry.
    parse: data => data
      .filter(e => e.protocol === "http")
      .map(e => entry(e.ip, e.port, e.geolocation?.country, e.score)),
  },
];

// Providers that report no real uptime score low. Reliable proxies come first, because most of the
// rest are dead and every dead batch makes the user wait.
const RELIABLE_SCORE = 50;

// Reliable before unreliable, then nearest country, then highest score.
export function rankCandidates(entries) {
  const rank = c => {
    const i = NEAR_COUNTRIES.indexOf(c);
    return i < 0 ? NEAR_COUNTRIES.length : i;
  };
  const seen = new Set();
  return entries
    .filter(e => e && !seen.has(e.server) && seen.add(e.server))
    .sort((a, b) =>
      (b.score >= RELIABLE_SCORE) - (a.score >= RELIABLE_SCORE) ||
      rank(a.country) - rank(b.country) ||
      b.score - a.score);
}

export function buildPac(servers) {
  if (!servers.length) throw new Error("cannot build a PAC without proxies");
  for (const s of servers) if (!isValidServer(s)) throw new Error(`invalid proxy: ${s}`);
  // No DIRECT fallback: logging in from the real IP would silently bring the restriction back.
  const chain = servers.map(s => `PROXY ${s}`).join("; ");
  return `var PROXIED = ${JSON.stringify([...PROXIED_HOSTS, TRACE_HOST])};
var DIRECT = ${JSON.stringify(DIRECT_HOSTS)};
function matches(host, list) {
  for (var i = 0; i < list.length; i++) {
    if (host === list[i] || dnsDomainIs(host, "." + list[i])) return true;
  }
  return false;
}
function FindProxyForURL(url, host) {
  host = host.toLowerCase();
  if (matches(host, DIRECT) || !matches(host, PROXIED)) return "DIRECT";
  return ${JSON.stringify(chain)};
}
`;
}

// Same routing as the PAC, for browsers that use proxy.onRequest (Firefox).
export function isProxiedHost(hostname) {
  const host = hostname.toLowerCase();
  const inList = list => list.some(d => host === d || host.endsWith(`.${d}`));
  return !inList(DIRECT_HOSTS) && inList([...PROXIED_HOSTS, TRACE_HOST]);
}

export function parseTraceCountry(body) {
  return /^loc=([A-Z0-9]{2})\s*$/m.exec(body)?.[1] ?? null;
}

export function isGatewayUrl(url) {
  return /^wss:\/\/gateway(-[a-z0-9-]+)?\.discord\.gg\//i.test(url);
}

// Pages that open a gateway connection when they load. Marketing and help pages do not.
export function isDiscordAppUrl(url) {
  return /^https:\/\/((canary|ptb)\.)?discord\.com\/(app|channels|login|activity|shop|store|library)(\/|$|\?)/i.test(url);
}
