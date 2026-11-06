// Fetches free proxy lists, tests the candidates and writes proxies.json and proxy.pac to the output
// directory. Exits non-zero without writing anything if nothing works, so the published list survives.
//
//   node proxies/update.mjs <output-dir> [max-candidates]
import { mkdir, writeFile } from "node:fs/promises";
import path from "node:path";
import { checkProxy } from "./check.mjs";
import { PROVIDERS, buildList, buildPac, mergeCandidates, selectProxies } from "./lib.mjs";

const [outDir, maxArg] = process.argv.slice(2);
if (!outDir) throw new Error("usage: update.mjs <output-dir> [max-candidates]");
const maxCandidates = Number(maxArg ?? 3000);

// A tunnel abandoned after its check timed out can still fail later; it must not end the run.
process.on("uncaughtException", err => console.warn(`ignored: ${err.message}`));

const lists = await Promise.all(PROVIDERS.map(async provider => {
  try {
    const res = await fetch(provider.url, { signal: AbortSignal.timeout(60_000) });
    if (!res.ok) throw new Error(`HTTP ${res.status}`);
    const list = provider.parse(await res.json());
    console.log(`${provider.name}: ${list.filter(Boolean).length} candidates`);
    return list;
  } catch (err) {
    console.warn(`${provider.name}: failed (${err.message})`);
    return [];
  }
}));

const candidates = mergeCandidates(lists).sort(() => Math.random() - 0.5).slice(0, maxCandidates);
console.log(`testing ${candidates.length} candidates`);

const proxies = await selectProxies(candidates, checkProxy, { concurrency: 100 });
if (!proxies.length) {
  console.error("no working proxy found; keeping the published list");
  process.exit(1);
}
for (const p of proxies) console.log(`${p.server} ${p.country} ${p.latencyMs}ms`);

await mkdir(outDir, { recursive: true });
await writeFile(path.join(outDir, "proxies.json"), buildList(proxies));
await writeFile(path.join(outDir, "proxy.pac"), buildPac(proxies));
process.exit(0); // abandoned tunnels must not hold the process open
