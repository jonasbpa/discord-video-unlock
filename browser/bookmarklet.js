/* Bookmarklet source. index.html turns this file into the "javascript:" link, so keep it
   self-contained and use block comments only. Same logic as the userscript, but it runs on
   an already loaded page, so webpack is there and no polling is needed. */
(() => {
    const EXPERIMENT = "2026-08-video-guard";
    const chunks = window.webpackChunkdiscord_app;
    if (!chunks) {
        alert("Abra o Discord (discord.com/app), espere carregar e clique de novo.");
        return;
    }

    let wreq = null;
    chunks.push([[Symbol("DiscordVideoUnlock")], {}, r => { wreq = r; }]);
    chunks.pop();

    let dispatcher = null;
    const isDispatcher = x => x && typeof x.dispatch === "function"
        && typeof x.subscribe === "function" && typeof x.unsubscribe === "function";
    for (const mod of Object.values((wreq && wreq.c) || {})) {
        const e = mod && mod.exports;
        if (!e || (typeof e !== "object" && typeof e !== "function")) continue;
        if (isDispatcher(e)) { dispatcher = e; break; }
        for (const key of Object.keys(e)) {
            let x;
            try { x = e[key]; } catch { continue; }
            if (isDispatcher(x)) { dispatcher = x; break; }
        }
        if (dispatcher) break;
    }
    if (!dispatcher) {
        alert("Não deu: o Discord mudou por dentro. Veja se há versão nova em github.com/jonasbpa/discord-video-unlock");
        return;
    }

    const apply = () => dispatcher.dispatch({
        type: "APEX_EXPERIMENT_SESSION_OVERRIDE_CREATE",
        experimentName: EXPERIMENT,
        variantId: 0
    });
    if (!window.__discordVideoUnlock) {
        window.__discordVideoUnlock = true;
        /* Reconnects refill the experiment store; deferred because Flux forbids nested dispatch. */
        dispatcher.subscribe("CONNECTION_OPEN", () => setTimeout(apply, 0));
    }
    apply();
    alert("Vídeo liberado! Se o botão ainda estiver bloqueado, saia e entre de novo no canal de voz. Ao recarregar a página, clique de novo.");
})();
