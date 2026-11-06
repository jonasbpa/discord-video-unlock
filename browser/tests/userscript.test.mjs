// Runs the userscript against a fake Discord page (webpack chunk array + Flux dispatcher).
// Usage: node --test browser/tests
import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import vm from "node:vm";

const source = readFileSync(new URL("../discord-video-unlock.user.js", import.meta.url), "utf8");

function fakePage({ shipExperiment = true } = {}) {
    const dispatched = [];
    const handlers = {};
    let dispatching = false;
    const dispatcher = {
        dispatch(action) {
            if (dispatching) throw new Error("Cannot dispatch in the middle of a dispatch");
            dispatching = true;
            try {
                dispatched.push(action);
                for (const h of handlers[action.type] ?? []) h(action);
            } finally {
                dispatching = false;
            }
        },
        subscribe(type, h) { (handlers[type] ??= []).push(h); },
        unsubscribe() {}
    };

    const wreq = {
        // Minified named export behind a getter, like Discord ships it.
        c: { 1: { exports: { foo: 1 } }, 2: { exports: Object.defineProperty({}, "Z", { get: () => dispatcher, enumerable: true }) } },
        // The script searches factory *source*, so the string must live in the function body.
        m: { 1: shipExperiment ? () => 'name:"2026-08-video-guard"' : () => 'name:"other"' }
    };
    const chunks = [];
    chunks.push = function (chunk) {
        const runtime = chunk[2];
        if (typeof runtime === "function") runtime(wreq);
        return Array.prototype.push.call(this, chunk);
    };

    const warnings = [];
    const errors = [];
    const context = {
        setInterval, clearInterval, setTimeout, Date, Symbol, Object, String,
        console: { log() {}, warn: m => warnings.push(m), error: m => errors.push(m) }
    };
    context.window = context;
    return { context, chunks, dispatcher, dispatched, warnings, errors };
}

const overrides = actions => actions.filter(a => a.type === "APEX_EXPERIMENT_SESSION_OVERRIDE_CREATE");
const tick = ms => new Promise(r => setTimeout(r, ms));

test("waits for webpack, applies override, re-applies on every CONNECTION_OPEN", async () => {
    const page = fakePage();
    vm.runInNewContext(source, page.context);

    await tick(300);
    assert.equal(overrides(page.dispatched).length, 0, "nothing before webpack exists");

    page.context.webpackChunkdiscord_app = page.chunks;
    await tick(300);
    assert.equal(overrides(page.dispatched).length, 1, "applied once webpack is found");
    // Spread: the action was created in the vm realm, with another Object.prototype.
    assert.deepEqual({ ...overrides(page.dispatched)[0] }, {
        type: "APEX_EXPERIMENT_SESSION_OVERRIDE_CREATE", experimentName: "2026-08-video-guard", variantId: 0
    });
    assert.equal(page.chunks.length, 0, "fake chunk removed again");

    page.dispatcher.dispatch({ type: "CONNECTION_OPEN" });
    page.dispatcher.dispatch({ type: "CONNECTION_OPEN" });
    await tick(20);
    assert.equal(overrides(page.dispatched).length, 3, "re-applied after each CONNECTION_OPEN, outside the dispatch");
    assert.deepEqual(page.errors, []);
    assert.deepEqual(page.warnings, []);
});

test("warns but still applies when the experiment name is not in the bundle", async () => {
    const page = fakePage({ shipExperiment: false });
    page.context.webpackChunkdiscord_app = page.chunks;
    vm.runInNewContext(source, page.context);
    await tick(300);
    assert.equal(overrides(page.dispatched).length, 1);
    assert.equal(page.warnings.length, 1);
});
