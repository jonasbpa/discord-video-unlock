import assert from "node:assert/strict";
import test from "node:test";
import vm from "node:vm";
import { createController, BATCH_SIZE } from "../extension/controller.js";
import {
  PROVIDERS, buildPac, isDiscordAppUrl, isGatewayUrl, isProxiedHost, isValidServer, parseTraceCountry, rankCandidates,
} from "../extension/lib.js";

const provider = name => PROVIDERS.find(p => p.name === name);
const scrape = (ip, port, country, extra = {}) => ({
  alive: true, ssl: true, protocol: "http", ip, port, uptime: 50, ip_data: { countryCode: country }, ...extra,
});

test("providers keep usable proxies outside Brazil", () => {
  assert.deepEqual(provider("proxyscrape").parse({ proxies: [
    scrape("8.8.8.8", 80, "US"), scrape("9.9.9.9", 80, "BR"),
    scrape("1.1.1.1", 80, "US", { alive: false }), scrape("1.0.0.1", 80, "US", { ssl: false }),
  ] }).filter(Boolean), [{ server: "8.8.8.8:80", country: "US", score: 50 }]);
  assert.deepEqual(provider("proxifly").parse([
    { protocol: "http", https: false, ip: "8.8.4.4", port: 3128, score: 1, geolocation: { country: "DE" } },
    { protocol: "socks5", ip: "1.1.1.1", port: 3128, score: 1, geolocation: { country: "DE" } },
  ]).filter(Boolean), [{ server: "8.8.4.4:3128", country: "DE", score: 1 }]);
});

test("hostile provider values are dropped", () => {
  const parse = provider("proxyscrape").parse;
  for (const [ip, port] of [
    ['1.1.1.1"; alert(1); "', 80], ["evil.example", 80], ["127.0.0.1", 80], ["10.0.0.1", 80],
    ["192.168.0.1", 80], ["999.1.1.1", 80], ["8.8.8.8", 0], ["8.8.8.8", 70000], ["8.8.8.8", "80;x"],
  ]) {
    assert.deepEqual(parse({ proxies: [scrape(ip, port, "US")] }).filter(Boolean), [], `${ip}:${port}`);
  }
  assert.ok(!isValidServer("8.8.8.8:80:1"));
  assert.ok(isValidServer("181.39.25.196:8118"));
});

test("candidates are ranked by proximity, then reliability, without duplicates", () => {
  const ranked = rankCandidates([
    { server: "de:1", country: "DE", score: 99 }, { server: "us:1", country: "US", score: 99 },
    { server: "ar:low", country: "AR", score: 1 }, { server: "ar:high", country: "AR", score: 50 },
    { server: "ar:high", country: "AR", score: 50 }, null,
  ]);
  assert.deepEqual(ranked.map(e => e.server), ["ar:high", "ar:low", "us:1", "de:1"]);
});

test("PAC proxies only Discord login hosts, with no DIRECT fallback", () => {
  const ctx = { dnsDomainIs: (host, domain) => host.endsWith(domain) };
  vm.runInNewContext(buildPac(["8.8.8.8:80", "1.1.1.1:3128"]), ctx);
  const chain = "PROXY 8.8.8.8:80; PROXY 1.1.1.1:3128";
  for (const host of ["discord.com", "gateway.discord.gg", "canary.discord.com", "www.cloudflare.com", "DISCORD.COM"]) {
    assert.equal(ctx.FindProxyForURL(`https://${host}/`, host), chain, host);
    assert.ok(isProxiedHost(host), host);
  }
  for (const host of ["google.com", "notdiscord.com", "discord.com.evil.example", "cdn.discordapp.com",
    "cdn.discord.com", "media.discordapp.net", "brazil123.discord.media"]) {
    assert.equal(ctx.FindProxyForURL(`https://${host}/`, host), "DIRECT", host);
    assert.ok(!isProxiedHost(host), host);
  }
  assert.throws(() => buildPac([]));
  assert.throws(() => buildPac(['1.1.1.1:80"; alert(1); "']));
});

test("URL and trace helpers", () => {
  assert.ok(isGatewayUrl("wss://gateway.discord.gg/?encoding=etf"));
  assert.ok(isGatewayUrl("wss://gateway-us-east1-b.discord.gg/"));
  assert.ok(!isGatewayUrl("wss://remote-auth-gateway.discord.gg/"));
  assert.ok(isDiscordAppUrl("https://discord.com/app"));
  assert.ok(isDiscordAppUrl("https://canary.discord.com/channels/1/2"));
  assert.ok(!isDiscordAppUrl("https://discord.com/"));
  assert.ok(!isDiscordAppUrl("https://discord.com/blog"));
  assert.ok(!isDiscordAppUrl("https://discord.com.evil.example/app"));
  assert.equal(parseTraceCountry("ip=1.1.1.1\nloc=AR\ntls=TLSv1.3\n"), "AR");
  assert.equal(parseTraceCountry("Forbidden"), null);
});

const servers = n => Array.from({ length: n }, (_, i) => `8.8.${Math.floor(i / 250)}.${(i % 250) + 1}:80`);

function setup({ candidates = servers(BATCH_SIZE * 2), working = [], ownProxy = "", enabled = true, respond } = {}) {
  const data = { candidates, candidatesAt: 1000, working, ownProxy, enabled };
  const sessionData = {};
  const calls = { set: [], clear: 0, alarmsCreated: 0, alarmsCleared: 0, shown: [] };
  const release = [];
  let active = null;
  const defaultRespond = async url => {
    if (url.includes("gateway")) return { ok: true, text: async () => '{"url":"wss://gateway.discord.gg"}' };
    return { ok: true, text: async () => "loc=AR\n" };
  };
  const controller = createController({
    proxy: {
      set: async list => { active = list; calls.set.push(list); },
      clear: async () => { active = null; calls.clear++; },
    },
    store: { get: async () => ({ ...data }), set: async v => Object.assign(data, v) },
    session: { get: async () => ({ ...sessionData }), set: async v => Object.assign(sessionData, v) },
    alarms: { create: async () => { calls.alarmsCreated++; }, clear: async () => { calls.alarmsCleared++; } },
    ui: { show: status => calls.shown.push(status) },
    fetchFn: (url, opts) => (respond ?? defaultRespond)(url, opts, () => active),
    wait: () => new Promise(resolve => release.push(resolve)),
    now: () => 2000,
  });
  const settle = async () => { for (let i = 0; i < 50; i++) await new Promise(setImmediate); };
  return { controller, data, sessionData, calls, release, settle, active: () => active };
}

test("navigation turns the proxy on, and it goes off after the gateway settles", async () => {
  const t = setup();
  await t.controller.onNavigate();
  await t.settle();
  assert.deepEqual(t.active(), servers(BATCH_SIZE));
  assert.equal(t.calls.alarmsCreated, 1);
  assert.equal(t.sessionData.status, "connecting");
  assert.equal(t.sessionData.country, "AR");
  assert.deepEqual(t.data.working, servers(BATCH_SIZE));

  const open = t.controller.onGatewayOpen();
  await t.settle();
  assert.deepEqual(t.active(), servers(BATCH_SIZE), "still on while settling");
  t.release.shift()();
  await open;
  assert.equal(t.active(), null);
  assert.equal(t.sessionData.status, "unlocked");
  assert.equal(t.sessionData.armed, false);
  assert.equal(t.calls.alarmsCleared, 1);
});

test("a failing batch moves to the next one", async () => {
  const good = servers(BATCH_SIZE * 2).slice(BATCH_SIZE);
  const t = setup({
    respond: async (url, _opts, active) => {
      if (active()[0] !== good[0]) throw new Error("dead");
      return { ok: true, text: async () => (url.includes("gateway") ? "gateway.discord.gg" : "loc=CL\n") };
    },
  });
  await t.controller.onNavigate();
  await t.settle();
  assert.deepEqual(t.active(), good);
  assert.deepEqual(t.data.working, good);
  assert.equal(t.sessionData.country, "CL");
});

test("a Brazilian exit or a blocked IP does not pass", async () => {
  for (const respond of [
    async url => ({ ok: true, text: async () => (url.includes("gateway") ? "gateway.discord.gg" : "loc=BR\n") }),
    async () => ({ ok: false, text: async () => "Access denied" }),
  ]) {
    const t = setup({ respond });
    await t.controller.onNavigate();
    await t.settle();
    assert.equal(t.active(), null, "proxy must be off");
    assert.equal(t.sessionData.status, "failed");
    assert.equal(t.sessionData.armed, false);
  }
});

test("when every proxy fails the proxy is turned off", async () => {
  const t = setup({ respond: async () => { throw new Error("dead"); } });
  await t.controller.onNavigate();
  await t.settle();
  assert.equal(t.active(), null);
  assert.equal(t.sessionData.status, "failed");
  assert.equal(t.calls.alarmsCleared, 1);
});

test("the working chain is tried first on the next load", async () => {
  const working = ["1.1.1.1:80"];
  const t = setup({ working });
  await t.controller.onNavigate();
  assert.deepEqual(t.calls.set[0], working);
  await t.settle();
  assert.deepEqual(t.active(), working);
});

test("the gateway opening stops the search and keeps the chain in use", async () => {
  let unblock;
  const t = setup({
    respond: async (url, _opts, active) => {
      await new Promise(resolve => { unblock = resolve; });
      throw new Error(`dead ${active()}`);
    },
  });
  await t.controller.onNavigate();
  await t.settle();
  const firstBatch = t.active();
  const open = t.controller.onGatewayOpen();
  await t.settle();
  unblock();
  await t.settle();
  assert.deepEqual(t.active(), firstBatch, "must not swap a chain that is already connected");
  t.release.shift()();
  await open;
  assert.equal(t.active(), null);
  assert.equal(t.sessionData.status, "unlocked");
});

test("own proxy is the only one used", async () => {
  const t = setup({ ownProxy: "5.5.5.5:8118" });
  await t.controller.onNavigate();
  await t.settle();
  assert.deepEqual(t.active(), ["5.5.5.5:8118"]);
  assert.deepEqual(t.data.working, []);
  assert.ok(t.calls.set.every(list => list.length === 1 && list[0] === "5.5.5.5:8118"));
});

test("disabled extension never turns the proxy on", async () => {
  const t = setup({ enabled: false });
  await t.controller.onNavigate();
  await t.controller.onGatewayOpen();
  await t.settle();
  assert.equal(t.calls.set.length, 0);
  assert.equal(t.sessionData.status, undefined);
});

test("disabling during a login turns the proxy off", async () => {
  const t = setup();
  await t.controller.onNavigate();
  await t.settle();
  await t.controller.setEnabled(false);
  assert.equal(t.active(), null);
  assert.equal(t.sessionData.status, "off");
});

test("a gateway connection with the proxy off asks for a reload", async () => {
  const t = setup();
  await t.controller.onGatewayOpen();
  assert.equal(t.sessionData.status, "reload");
  assert.equal(t.calls.set.length, 0);
});

test("the alarm and a browser restart always turn the proxy off", async () => {
  const t = setup();
  await t.controller.onNavigate();
  await t.settle();
  await t.controller.onAlarm();
  assert.equal(t.active(), null);
  assert.equal(t.sessionData.status, "failed");

  const restart = setup();
  await restart.controller.onNavigate();
  await restart.settle();
  await restart.controller.onBrowserStart();
  assert.equal(restart.active(), null);
  assert.equal(restart.sessionData.armed, false);
});

test("a stale list is refreshed and an empty download keeps the old one", async () => {
  const t = setup({
    respond: async (url, opts, active) => {
      if (url === provider("proxyscrape").url) {
        return { ok: true, json: async () => ({ proxies: [scrape("8.8.4.4", 80, "AR")] }) };
      }
      if (url === provider("proxifly").url) return { ok: false };
      return { ok: true, text: async () => (url.includes("gateway") ? "gateway.discord.gg" : "loc=AR\n") };
    },
  });
  assert.deepEqual(await t.controller.refreshCandidates(), ["8.8.4.4:80"]);
  assert.deepEqual(t.data.candidates, ["8.8.4.4:80"]);

  const down = setup({ respond: async () => ({ ok: false }) });
  assert.deepEqual(await down.controller.refreshCandidates(), []);
  assert.equal(down.data.candidates.length, BATCH_SIZE * 2);
});
