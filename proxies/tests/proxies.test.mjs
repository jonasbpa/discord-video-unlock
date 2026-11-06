import assert from "node:assert/strict";
import net from "node:net";
import test from "node:test";
import vm from "node:vm";
import { connectTunnel } from "../check.mjs";
import { PROVIDERS, buildList, buildPac, isPublicIpv4, mergeCandidates, parseTraceCountry, selectProxies } from "../lib.mjs";

const provider = name => PROVIDERS.find(p => p.name === name);

test("providers parse their formats and drop BR, non-http and invalid entries", () => {
  assert.deepEqual(provider("proxifly").parse([
    { protocol: "http", ip: "8.8.8.8", port: 80, geolocation: { country: "US" } },
    { protocol: "http", ip: "9.9.9.9", port: 80, geolocation: { country: "BR" } },
    { protocol: "socks5", ip: "1.1.1.1", port: 80, geolocation: { country: "US" } },
  ]).filter(Boolean), [{ server: "8.8.8.8:80" }]);

  assert.deepEqual(provider("monosans").parse([
    { protocol: "http", host: "8.8.4.4", port: 3128, geolocation: { country: { iso_code: "DE" } } },
    { protocol: "http", host: "9.9.9.9", port: 3128, geolocation: { country: { iso_code: "BR" } } },
  ]).filter(Boolean), [{ server: "8.8.4.4:3128" }]);

  assert.deepEqual(provider("proxyscrape").parse({ proxies: [
    { protocol: "http", ip: "1.0.0.1", port: 8080, ip_data: { countryCode: "CH" } },
    { protocol: "http", ip: "1.0.0.2", port: 8080, ip_data: { countryCode: "BR" } },
  ] }).filter(Boolean), [{ server: "1.0.0.1:8080" }]);
});

test("hostile provider values never become candidates", () => {
  const parse = provider("proxifly").parse;
  for (const [ip, port] of [
    ['1.1.1.1"; alert(1); "', 80], ["evil.example", 80], ["127.0.0.1", 80], ["10.0.0.1", 80],
    ["192.168.0.1", 80], ["999.1.1.1", 80], ["8.8.8.8", 0], ["8.8.8.8", 70000], ["8.8.8.8", "80;x"],
  ]) {
    assert.deepEqual(parse([{ protocol: "http", ip, port }]).filter(Boolean), [], `${ip}:${port}`);
  }
});

test("isPublicIpv4 separates public from private addresses", () => {
  assert.ok(isPublicIpv4("181.39.25.196"));
  assert.ok(!isPublicIpv4("172.16.0.1"));
});

test("mergeCandidates removes duplicates and nulls", () => {
  assert.deepEqual(
    mergeCandidates([[{ server: "a" }, null], [{ server: "a" }, { server: "b" }]]),
    [{ server: "a" }, { server: "b" }],
  );
});

test("selectProxies keeps the fastest non-BR proxies and survives failures", async () => {
  const results = {
    slow: { country: "US", latencyMs: 900 }, fast: { country: "DE", latencyMs: 100 },
    br: { country: "BR", latencyMs: 1 }, unknown: { country: null, latencyMs: 1 }, dead: null,
  };
  const check = async s => {
    if (s === "boom") throw new Error("boom");
    return results[s];
  };
  const servers = [...Object.keys(results), "boom"].map(server => ({ server }));
  const out = await selectProxies(servers, check, { concurrency: 2, keep: 5 });
  assert.deepEqual(out.map(p => p.server), ["fast", "slow"]);
  assert.equal((await selectProxies(servers, check, { keep: 1 })).length, 1);
});

function loadPac(source) {
  const ctx = { dnsDomainIs: (host, domain) => host.endsWith(domain) };
  vm.runInNewContext(source, ctx);
  return ctx.FindProxyForURL;
}

test("PAC proxies only the Discord login hosts, with no DIRECT fallback", () => {
  const find = loadPac(buildPac([{ server: "8.8.8.8:80" }, { server: "1.1.1.1:3128" }]));
  const chain = "PROXY 8.8.8.8:80; PROXY 1.1.1.1:3128";
  for (const host of ["discord.com", "gateway.discord.gg", "canary.discord.com", "discordapp.com", "DISCORD.COM"]) {
    assert.equal(find(`https://${host}/`, host), chain, host);
  }
  for (const host of ["google.com", "notdiscord.com", "discord.com.evil.example", "cdn.discordapp.com",
    "cdn.discord.com", "media.discordapp.net", "brazil123.discord.media"]) {
    assert.equal(find(`https://${host}/`, host), "DIRECT", host);
  }
});

test("buildPac refuses an empty or invalid list", () => {
  assert.throws(() => buildPac([]));
  assert.throws(() => buildPac([{ server: '1.1.1.1:80"; alert(1); "' }]));
  assert.throws(() => buildPac([{ server: "10.0.0.1:80" }]));
});

test("buildList is parseable and carries the proxies", () => {
  const out = JSON.parse(buildList([{ server: "8.8.8.8:80", country: "US", latencyMs: 5 }], new Date(0)));
  assert.equal(out.generatedAt, "1970-01-01T00:00:00.000Z");
  assert.equal(out.proxies[0].server, "8.8.8.8:80");
});

test("parseTraceCountry reads loc", () => {
  assert.equal(parseTraceCountry("HTTP/1.1 200 OK\r\n\r\nip=1.1.1.1\nloc=US\ntls=TLSv1.3\n"), "US");
  assert.equal(parseTraceCountry("Forbidden"), null);
});

function fakeProxy(reply) {
  return new Promise(resolve => {
    const server = net.createServer(socket => {
      socket.on("error", () => {});
      socket.once("data", () => (reply ? socket.write(reply) : socket.destroy()));
    });
    server.listen(0, "127.0.0.1", () => resolve(server));
  });
}

test("connectTunnel accepts 200 and rejects everything else", async t => {
  const ok = await fakeProxy("HTTP/1.1 200 Connection established\r\n\r\n");
  const denied = await fakeProxy("HTTP/1.1 403 Forbidden\r\n\r\n");
  const hangup = await fakeProxy(null);
  t.after(() => { ok.close(); denied.close(); hangup.close(); });
  const addr = s => `127.0.0.1:${s.address().port}`;

  (await connectTunnel(addr(ok), "discord.com", 2000)).destroy();
  await assert.rejects(connectTunnel(addr(denied), "discord.com", 2000), /403/);
  await assert.rejects(connectTunnel(addr(hangup), "discord.com", 2000));
});
