// Picks a proxy for the install page, straight from a public provider in the visitor's browser.
// Provider data is untrusted, so only validated values reach the page. A page cannot open raw
// sockets, so it cannot test the proxy: the provider's own reliability data is all there is.

const IPV4 = /^(\d{1,3})\.(\d{1,3})\.(\d{1,3})\.(\d{1,3})$/;

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

function entry(host, port, country, score) {
  const p = Number(port);
  const c = String(country ?? "").toUpperCase();
  if (typeof host !== "string" || !isPublicIpv4(host)) return null;
  if (!Number.isInteger(p) || p < 1 || p > 65535) return null;
  if (!/^[A-Z]{2}$/.test(c) || c === "BR") return null;
  return { host, port: p, country: c, score: Number(score) || 0 };
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
    parse: data => data
      // No HTTPS filter: this provider reports `https: false` for every entry.
      .filter(e => e.protocol === "http")
      .map(e => entry(e.ip, e.port, e.geolocation?.country, e.score)),
  },
];

// Random among the most reliable, so visitors do not all land on the same proxy.
export function pickProxy(entries, random = Math.random, top = 20) {
  const best = entries.filter(Boolean).sort((a, b) => b.score - a.score).slice(0, top);
  return best.length ? best[Math.floor(random() * best.length)] : null;
}

export async function fetchProxy(fetchImpl = fetch, random = Math.random) {
  for (const provider of PROVIDERS) {
    try {
      const res = await fetchImpl(provider.url);
      if (!res.ok) continue;
      const proxy = pickProxy(provider.parse(await res.json()), random);
      if (proxy) return proxy;
    } catch {
      // Try the next provider.
    }
  }
  return null;
}
