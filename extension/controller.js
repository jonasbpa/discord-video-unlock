// Holds the proxy on only while Discord logs in, then turns it off. Browser APIs are injected so the
// logic can be tested. The proxy must never stay on: every path out of `arm` ends in `disarm`, and an
// alarm covers the case where the service worker dies in between.
import { PROVIDERS, parseTraceCountry, rankCandidates } from "./lib.js";

export const BATCH_SIZE = 8;
export const MAX_BATCHES = 8;
export const VERIFY_TIMEOUT_MS = 12_000;
export const SETTLE_MS = 10_000;
export const ARM_TIMEOUT_MINUTES = 2;
export const LIST_MAX_AGE_MS = 3 * 60 * 60 * 1000;

// `proxy`: { set(servers), clear() }, `store`: { get(), set(values) } for persistent data,
// `session`: same, cleared with the browser, `alarms`: { create(minutes), clear() },
// `ui`: { show(status) }, `fetchFn`, `wait(ms)`, `now()`.
export function createController({ proxy, store, session, alarms, ui, fetchFn, wait, now = Date.now }) {
  let run = 0; // Identifies the current arm(): a newer one or a gateway connection stops the old loop.

  async function setStatus(status, extra = {}) {
    await session.set({ status, ...extra });
    ui.show(status);
  }

  async function refreshCandidates() {
    const lists = await Promise.all(PROVIDERS.map(async provider => {
      try {
        const res = await fetchFn(provider.url);
        return res.ok ? provider.parse(await res.json()) : [];
      } catch {
        return [];
      }
    }));
    const candidates = rankCandidates(lists.flat()).map(e => e.server);
    if (candidates.length) await store.set({ candidates, candidatesAt: now() });
    return candidates;
  }

  async function getCandidates() {
    const { candidates = [], candidatesAt = 0 } = await store.get();
    if (candidates.length && now() - candidatesAt < LIST_MAX_AGE_MS) return candidates;
    const fresh = await refreshCandidates();
    return fresh.length ? fresh : candidates;
  }

  // Goes through the same chain the page uses, with anonymous requests only. Certificate errors make
  // fetch fail, which rejects proxies that intercept TLS.
  async function verify() {
    const get = async url => {
      const res = await fetchFn(url, {
        credentials: "omit", cache: "no-store", signal: AbortSignal.timeout(VERIFY_TIMEOUT_MS),
      });
      return { ok: res.ok, body: await res.text() };
    };
    try {
      const api = await get("https://discord.com/api/v9/gateway");
      if (!api.ok || !api.body.includes("gateway.discord.gg")) return null;
      const country = parseTraceCountry((await get("https://www.cloudflare.com/cdn-cgi/trace")).body);
      return country && country !== "BR" ? country : null;
    } catch {
      return null;
    }
  }

  async function searchLoop(current, ownProxy) {
    let { working = [] } = await store.get();
    const candidates = ownProxy ? [ownProxy] : await getCandidates();
    if (current !== run) return;

    const fresh = candidates.filter(s => !working.includes(s));
    const batches = ownProxy ? [[ownProxy]] : [];
    if (!ownProxy) {
      if (working.length) batches.push(working);
      for (let i = 0; i < MAX_BATCHES && i * BATCH_SIZE < fresh.length; i++) {
        batches.push(fresh.slice(i * BATCH_SIZE, (i + 1) * BATCH_SIZE));
      }
    }

    for (const batch of batches) {
      if (current !== run) return;
      await proxy.set(batch);
      const country = await verify();
      if (current !== run) return;
      if (country) {
        if (!ownProxy) await store.set({ working: batch });
        await setStatus("connecting", { country });
        return;
      }
    }
    if (current === run) await disarm("failed");
  }

  async function arm() {
    const { enabled = true, ownProxy = "" } = await store.get();
    if (!enabled) return;
    const current = ++run;
    await session.set({ armed: true, gatewaySeen: false, country: null });
    await alarms.create(ARM_TIMEOUT_MINUTES);
    await setStatus("searching");

    // Applied before any network wait: the page opens its gateway connection within seconds.
    const { working = [], candidates = [] } = await store.get();
    const initial = ownProxy ? [ownProxy] : working.length ? working : candidates.slice(0, BATCH_SIZE);
    if (initial.length) await proxy.set(initial);

    searchLoop(current, ownProxy).catch(() => disarm("failed"));
  }

  async function disarm(status) {
    run++;
    await proxy.clear();
    await alarms.clear();
    await session.set({ armed: false });
    await setStatus(status);
  }

  async function onNavigate() {
    await arm();
  }

  // The gateway handshake finished. Discord still needs a moment to authenticate through the proxy.
  async function onGatewayOpen() {
    const { armed = false, gatewaySeen = false } = await session.get();
    const { enabled = true } = await store.get();
    if (!enabled) return;
    if (!armed) {
      // A reconnect from the real IP, which can bring the restriction back.
      await setStatus("reload");
      return;
    }
    if (gatewaySeen) return;
    run++; // Keep the chain that just worked.
    await session.set({ gatewaySeen: true });
    await wait(SETTLE_MS);
    const state = await session.get();
    if (state.armed && state.gatewaySeen) await disarm("unlocked");
  }

  async function onAlarm() {
    const { armed = false } = await session.get();
    await disarm(armed ? "failed" : "idle");
  }

  // A browser restart keeps proxy settings but loses the session, so anything found here is stale.
  async function onBrowserStart() {
    run++;
    await proxy.clear();
    await alarms.clear();
    await session.set({ armed: false });
    await setStatus("idle");
  }

  async function onInstalled() {
    await onBrowserStart();
    await refreshCandidates();
  }

  async function setEnabled(enabled) {
    await store.set({ enabled });
    if (!enabled) await disarm("off");
    else await setStatus("idle");
  }

  async function setOwnProxy(ownProxy) {
    await store.set({ ownProxy, working: [] });
  }

  return { arm, disarm, onNavigate, onGatewayOpen, onAlarm, onBrowserStart, onInstalled, setEnabled, setOwnProxy, refreshCandidates };
}
