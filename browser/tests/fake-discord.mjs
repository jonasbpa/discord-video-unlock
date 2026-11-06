// Minimal fake of discord.com: webpack chunk array + Flux dispatcher that, like the real one,
// refuses a dispatch from inside another dispatch.
export function fakePage({ shipExperiment = true } = {}) {
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
        // The scripts search factory *source*, so the string must live in the function body.
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
    const alerts = [];
    const context = {
        setInterval, clearInterval, setTimeout, Date, Symbol, Object, String,
        alert: m => alerts.push(m),
        console: { log() {}, warn: m => warnings.push(m), error: m => errors.push(m) }
    };
    context.window = context;
    return { context, chunks, dispatcher, dispatched, warnings, errors, alerts };
}

export const overrides = actions => actions.filter(a => a.type === "APEX_EXPERIMENT_SESSION_OVERRIDE_CREATE");
export const tick = ms => new Promise(r => setTimeout(r, ms));
