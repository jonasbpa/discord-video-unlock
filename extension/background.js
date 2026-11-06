import { createController } from "./controller.js";
import { buildPac, isDiscordAppUrl, isGatewayUrl, isProxiedHost, isValidServer } from "./lib.js";

const api = globalThis.browser ?? globalThis.chrome;
const ALARM = "dvu-disarm";
const isFirefox = typeof api.proxy.onRequest !== "undefined";

const BADGES = {
  idle: ["", "#5865f2"],
  off: ["off", "#6d6f78"],
  searching: ["...", "#f0b232"],
  connecting: ["...", "#f0b232"],
  unlocked: ["ok", "#23a55a"],
  failed: ["x", "#f23f43"],
  reload: ["F5", "#f0b232"],
};

const areaApi = area => ({
  get: () => area.get(null),
  set: values => area.set(values),
});

// Firefox has no PAC-by-data in proxy.settings, so it routes through proxy.onRequest instead.
const proxyApi = isFirefox
  ? {
      set: servers => api.storage.session.set({ proxyChain: servers }),
      clear: () => api.storage.session.set({ proxyChain: [] }),
    }
  : {
      set: servers => api.proxy.settings.set({
        scope: "regular",
        value: { mode: "pac_script", pacScript: { data: buildPac(servers), mandatory: true } },
      }),
      clear: () => api.proxy.settings.clear({ scope: "regular" }),
    };

const controller = createController({
  proxy: proxyApi,
  store: areaApi(api.storage.local),
  session: areaApi(api.storage.session),
  alarms: {
    create: minutes => api.alarms.create(ALARM, { delayInMinutes: minutes }),
    clear: () => api.alarms.clear(ALARM),
  },
  ui: {
    show(status) {
      const [text, color] = BADGES[status] ?? BADGES.idle;
      api.action.setBadgeText({ text });
      api.action.setBadgeBackgroundColor({ color });
    },
  },
  fetchFn: (...args) => fetch(...args),
  wait: ms => new Promise(resolve => setTimeout(resolve, ms)),
});

if (isFirefox) {
  api.proxy.onRequest.addListener(async request => {
    const { proxyChain = [] } = await api.storage.session.get("proxyChain");
    if (!proxyChain.length || !isProxiedHost(new URL(request.url).hostname)) return { type: "direct" };
    return proxyChain.map(server => {
      const [host, port] = server.split(":");
      return { type: "http", host, port: Number(port) };
    });
  }, { urls: ["*://*.discord.com/*", "*://discord.com/*", "*://*.discord.gg/*", "*://discordapp.com/*", "*://*.discordapp.com/*", "*://www.cloudflare.com/*"] });
}

api.runtime.onStartup.addListener(() => controller.onBrowserStart());
api.runtime.onInstalled.addListener(() => controller.onInstalled());
api.alarms.onAlarm.addListener(alarm => {
  if (alarm.name === ALARM) controller.onAlarm();
});

// Top frame only, and before the page exists, so the proxy is on when it opens the gateway.
api.webNavigation.onBeforeNavigate.addListener(details => {
  if (details.frameId === 0 && isDiscordAppUrl(details.url)) controller.onNavigate();
}, { url: [{ hostSuffix: "discord.com" }] });

api.webRequest.onHeadersReceived.addListener(details => {
  if (details.statusCode === 101 && isGatewayUrl(details.url)) controller.onGatewayOpen();
}, { urls: ["wss://*.discord.gg/*"], types: ["websocket"] });

async function reloadDiscordTabs() {
  const tabs = await api.tabs.query({ url: ["https://discord.com/*", "https://*.discord.com/*"] });
  const appTabs = tabs.filter(tab => isDiscordAppUrl(tab.url));
  if (!appTabs.length) {
    await api.tabs.create({ url: "https://discord.com/app" });
    return;
  }
  await Promise.all(appTabs.map(tab => api.tabs.reload(tab.id)));
}

async function getState() {
  const [store, session] = await Promise.all([api.storage.local.get(null), api.storage.session.get(null)]);
  const control = isFirefox ? null : await api.proxy.settings.get({});
  return {
    enabled: store.enabled ?? true,
    ownProxy: store.ownProxy ?? "",
    status: session.status ?? "idle",
    country: session.country ?? null,
    // Another proxy extension, such as FoxyProxy, can hold the setting and silently win.
    blocked: control?.levelOfControl === "controlled_by_other_extensions",
  };
}

api.runtime.onMessage.addListener((message, _sender, respond) => {
  (async () => {
    if (message.type === "setEnabled") await controller.setEnabled(Boolean(message.enabled));
    if (message.type === "reload") await reloadDiscordTabs();
    if (message.type === "setOwnProxy") {
      const value = String(message.value ?? "").trim();
      if (value && !isValidServer(value)) return respond({ error: "invalid" });
      await controller.setOwnProxy(value);
    }
    respond(await getState());
  })().catch(err => respond({ error: String(err) }));
  return true;
});
