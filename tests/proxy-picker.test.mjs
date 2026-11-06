import assert from "node:assert/strict";
import test from "node:test";
import { PROVIDERS, fetchProxy, isPublicIpv4, pickProxy } from "../proxy-picker.mjs";

const provider = name => PROVIDERS.find(p => p.name === name);
const scrape = (ip, port, country, extra = {}) => ({
  alive: true, ssl: true, protocol: "http", ip, port, uptime: 50, ip_data: { countryCode: country }, ...extra,
});

test("proxyscrape keeps live HTTPS-capable proxies outside Brazil", () => {
  const out = provider("proxyscrape").parse({ proxies: [
    scrape("8.8.8.8", 80, "US"),
    scrape("9.9.9.9", 80, "BR"),
    scrape("1.1.1.1", 80, "US", { alive: false }),
    scrape("1.0.0.1", 80, "US", { ssl: false }),
    scrape("1.0.0.2", 80, undefined),
  ] }).filter(Boolean);
  assert.deepEqual(out, [{ host: "8.8.8.8", port: 80, country: "US", score: 50 }]);
});

test("proxifly format is parsed", () => {
  const out = provider("proxifly").parse([
    { protocol: "http", https: false, ip: "8.8.4.4", port: 3128, score: 2, geolocation: { country: "DE" } },
    { protocol: "http", https: false, ip: "8.8.8.8", port: 3128, score: 2, geolocation: { country: "BR" } },
    { protocol: "socks5", https: false, ip: "1.1.1.1", port: 3128, score: 2, geolocation: { country: "DE" } },
  ]).filter(Boolean);
  assert.deepEqual(out, [{ host: "8.8.4.4", port: 3128, country: "DE", score: 2 }]);
});

test("hostile provider values are dropped", () => {
  const parse = provider("proxyscrape").parse;
  for (const [ip, port] of [
    ["<img src=x onerror=alert(1)>", 80], ["evil.example", 80], ["127.0.0.1", 80], ["10.0.0.1", 80],
    ["192.168.0.1", 80], ["999.1.1.1", 80], ["8.8.8.8", 0], ["8.8.8.8", 70000], ["8.8.8.8", "80;x"],
  ]) {
    assert.deepEqual(parse({ proxies: [scrape(ip, port, "US")] }).filter(Boolean), [], `${ip}:${port}`);
  }
  assert.deepEqual(parse({ proxies: [scrape("8.8.8.8", 80, "<b>")] }).filter(Boolean), []);
});

test("isPublicIpv4 separates public from private addresses", () => {
  assert.ok(isPublicIpv4("181.39.25.196"));
  assert.ok(!isPublicIpv4("172.16.0.1"));
});

test("pickProxy chooses among the most reliable", () => {
  const low = { host: "1.1.1.1", score: 1 }, high = { host: "8.8.8.8", score: 99 };
  assert.equal(pickProxy([low, null, high], () => 0, 1), high);
  assert.equal(pickProxy([null]), null);
});

test("fetchProxy falls back to the next provider and reports total failure", async () => {
  const proxifly = [{ protocol: "http", https: true, ip: "8.8.4.4", port: 3128, score: 2, geolocation: { country: "DE" } }];
  const fallback = async url => {
    if (url === provider("proxyscrape").url) throw new Error("down");
    return { ok: true, json: async () => proxifly };
  };
  assert.equal((await fetchProxy(fallback)).host, "8.8.4.4");
  assert.equal(await fetchProxy(async () => ({ ok: false })), null);
});
