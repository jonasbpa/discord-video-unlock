import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import vm from "node:vm";
import { fakePage, overrides, tick } from "./fake-discord.mjs";

const source = readFileSync(new URL("../bookmarklet.js", import.meta.url), "utf8").trim();
// What the browser runs after index.html builds the link: "javascript:" + encodeURIComponent(source).
const href = "javascript:" + encodeURIComponent(source);
const run = context => vm.runInNewContext(decodeURIComponent(href.slice("javascript:".length)), context);

test("survives the javascript: URL round trip and evaluates to undefined (no navigation)", () => {
    const page = fakePage();
    page.context.webpackChunkdiscord_app = page.chunks;
    assert.equal(run(page.context), undefined);
});

test("applies once per click and subscribes to CONNECTION_OPEN only once", async () => {
    const page = fakePage();
    page.context.webpackChunkdiscord_app = page.chunks;
    run(page.context);
    run(page.context);
    assert.equal(overrides(page.dispatched).length, 2);
    assert.equal(page.chunks.length, 0, "fake chunk removed again");
    assert.equal(page.alerts.length, 2);
    assert.match(page.alerts[0], /liberado/);

    page.dispatcher.dispatch({ type: "CONNECTION_OPEN" });
    await tick(20);
    assert.equal(overrides(page.dispatched).length, 3, "one re-apply per reconnect, not one per click");
});

test("tells the user to open Discord when clicked elsewhere", () => {
    const page = fakePage();
    run(page.context);
    assert.equal(page.dispatched.length, 0);
    assert.match(page.alerts[0], /Abra o Discord/);
});
