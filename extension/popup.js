const api = globalThis.browser ?? globalThis.chrome;

const MESSAGES = {
  idle: "Pronto. Abra ou recarregue o Discord para liberar.",
  off: "Desativada.",
  searching: "Procurando um proxy...",
  connecting: "Conectando o Discord pelo proxy...",
  unlocked: "Liberado! O proxy já foi desligado.",
  failed: "Nenhum proxy funcionou agora. Tente de novo em alguns minutos.",
  reload: "O Discord reconectou sem o proxy. Recarregue a página para liberar de novo.",
};

const $ = id => document.getElementById(id);

function render(state) {
  if (state.error) return;
  const country = state.country && ["connecting", "unlocked"].includes(state.status) ? ` (saída: ${state.country})` : "";
  $("status").textContent = (MESSAGES[state.status] ?? MESSAGES.idle) + country;
  $("enabled").checked = state.enabled;
  $("reload").disabled = !state.enabled;
  $("blocked").hidden = !state.blocked;
  if (document.activeElement !== $("own-proxy")) $("own-proxy").value = state.ownProxy;
}

const send = message => api.runtime.sendMessage(message);
const refresh = async () => render(await send({ type: "getState" }));

$("reload").addEventListener("click", async () => render(await send({ type: "reload" })));
$("enabled").addEventListener("change", async event => render(await send({ type: "setEnabled", enabled: event.target.checked })));
$("own-proxy").addEventListener("change", async event => {
  const state = await send({ type: "setOwnProxy", value: event.target.value });
  $("own-proxy-hint").textContent = state.error
    ? "Endereço inválido. Use um IP público no formato ip:porta."
    : "Vazio usa os proxies públicos gratuitos.";
  render(state);
});

refresh();
setInterval(refresh, 1000);
