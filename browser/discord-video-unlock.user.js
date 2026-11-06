// ==UserScript==
// @name         Discord Video Unlock (web)
// @namespace    discord-video-unlock
// @version      0.1.0
// @description  Keeps the 2026-08-video-guard experiment on its control bucket on every gateway connection.
// @match        https://discord.com/*
// @match        https://ptb.discord.com/*
// @match        https://canary.discord.com/*
// @run-at       document-start
// @grant        none
// @sandbox      raw
// @inject-into  page
// ==/UserScript==

(() => {
    "use strict";

    const EXPERIMENT = "2026-08-video-guard";
    const POLL_MS = 250;
    const GIVE_UP_MS = 120_000;
    const TAG = "[DiscordVideoUnlock]";

    // @grant none runs in the page realm; unsafeWindow is only defined by some managers.
    const page = typeof unsafeWindow !== "undefined" ? unsafeWindow : window;

    // Same trick client mods use: push a fake chunk whose runtime callback receives
    // __webpack_require__, then drop the fake chunk again.
    function getWebpackRequire() {
        const chunks = page.webpackChunkdiscord_app;
        if (!chunks || typeof chunks.push !== "function") return null;
        let wreq = null;
        chunks.push([[Symbol("DiscordVideoUnlock")], {}, r => { wreq = r; }]);
        chunks.pop();
        return wreq && wreq.c ? wreq : null;
    }

    function* exportCandidates(exports) {
        if (!exports || (typeof exports !== "object" && typeof exports !== "function")) return;
        yield exports;
        // Discord ships minified named exports (getters); a lazy getter can throw.
        for (const key of Object.keys(exports)) {
            try { yield exports[key]; } catch { /* ignore */ }
        }
    }

    function findDispatcher(wreq) {
        for (const mod of Object.values(wreq.c)) {
            for (const x of exportCandidates(mod && mod.exports)) {
                if (x && typeof x.dispatch === "function" && typeof x.subscribe === "function"
                    && typeof x.unsubscribe === "function") {
                    return x;
                }
            }
        }
        return null;
    }

    function experimentShipped(wreq) {
        const factories = wreq.m || {};
        return Object.keys(factories).some(id => {
            try { return String(factories[id]).includes(EXPERIMENT); } catch { return false; }
        });
    }

    function applyOverride(dispatcher) {
        dispatcher.dispatch({
            type: "APEX_EXPERIMENT_SESSION_OVERRIDE_CREATE",
            experimentName: EXPERIMENT,
            variantId: 0
        });
        console.log(`${TAG} override applied to ${EXPERIMENT}`);
    }

    function attach(wreq, dispatcher) {
        if (!experimentShipped(wreq)) {
            console.warn(`${TAG} "${EXPERIMENT}" not found in the bundle; it may have been renamed. Applying anyway.`);
        }
        // The experiment store is filled after the gateway authenticates, which would overwrite an
        // earlier override; CONNECTION_OPEN fires after that and again on every reconnect.
        // Deferred because Flux refuses a dispatch from inside another dispatch.
        dispatcher.subscribe("CONNECTION_OPEN", () => setTimeout(() => applyOverride(dispatcher), 0));
        applyOverride(dispatcher);
    }

    const started = Date.now();
    const timer = setInterval(() => {
        try {
            const wreq = getWebpackRequire();
            const dispatcher = wreq && findDispatcher(wreq);
            if (dispatcher) {
                clearInterval(timer);
                attach(wreq, dispatcher);
            } else if (Date.now() - started > GIVE_UP_MS) {
                clearInterval(timer);
                console.error(`${TAG} Flux dispatcher not found, giving up`);
            }
        } catch (err) {
            clearInterval(timer);
            console.error(`${TAG} failed`, err);
        }
    }, POLL_MS);
})();
