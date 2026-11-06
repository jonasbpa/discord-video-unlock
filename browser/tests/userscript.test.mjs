// Usage: node --test "browser/tests/*.test.mjs"
import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import vm from "node:vm";
import { fakePage, overrides, tick } from "./fake-discord.mjs";

const source = readFileSync(new URL("../discord-video-unlock.user.js", import.meta.url), "utf8");

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

test("declares auto-update URLs pointing at the published file", () => {
    for (const key of ["@updateURL", "@downloadURL"]) {
        assert.match(source, new RegExp(`${key}\\s+https://raw\\.githubusercontent\\.com/jonasbpa/discord-video-unlock/main/browser/discord-video-unlock\\.user\\.js`));
    }
});
