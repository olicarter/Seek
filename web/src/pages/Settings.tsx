import { createSignal, Show } from "solid-js";
import { api, changes, isPaired, serverAddress, setCredential, setServerAddress } from "../api";
import { addPasskey, canUsePasskeys, deviceName } from "../passkeys";
import { For } from "solid-js";
import { live } from "../live";

export function Settings() {
  const [status] = live(changes, api.status);
  const [address, setAddress] = createSignal(serverAddress());
  const [auth] = live(changes, api.auth);
  const [passkeys, { refetch: refetchPasskeys }] = live(changes, () => api.passkeys().catch(() => []));
  const [passkeyError, setPasskeyError] = createSignal<string>();

  const add = async () => {
    setPasskeyError();
    try {
      await addPasskey(deviceName());
    } catch (e) {
      if (!(e instanceof DOMException && e.name === "NotAllowedError")) setPasskeyError(e instanceof Error ? e.message : String(e));
    }
  };


  return (
    <section>
      <h1>Settings</h1>
      <h2>Server</h2>
      <form class="login" onSubmit={(e) => { e.preventDefault(); setServerAddress(address()); }}>
        <input placeholder="This page's own address" value={address()} onInput={(e) => setAddress(e.currentTarget.value)} />
        <button>Save</button>
        <p class="empty">Seek on your Mac, at its Tailscale address (https://…ts.net). Leave empty when the Mac serves this page.</p>
        <Show when={!isPaired()}>
          <p class="empty">Not paired yet: open localhost:8765/pair on the Mac.</p>
        </Show>
      </form>
      <h2>Passkeys</h2>
      <Show when={auth()?.signedIn && !auth()?.local} fallback={
        <p class="empty">{auth()?.local ? "This Mac doesn't need one. Add passkeys from Seek on 4n.studio." : "Sign in first."}</p>
      }>
        <ul class="rows">
          <For each={passkeys()}>
            {(passkey) => (
              <li class="row">
                <div class="row-text">
                  <div class="row-title">{passkey.name}</div>
                  <div class="row-sub">
                    Added {new Date(passkey.created).toLocaleDateString()}
                    {passkey.lastUsed ? ` · last used ${new Date(passkey.lastUsed).toLocaleDateString()}` : ""}
                  </div>
                </div>
                <button class="link" onClick={async () => { await api.removePasskey(passkey.id); await refetchPasskeys(); }}>Remove</button>
              </li>
            )}
          </For>
        </ul>
        <Show when={canUsePasskeys()} fallback={<p class="empty">Passkeys can be added at 4n.studio/seek/web.</p>}>
          <button onClick={add}>Add Passkey</button>
        </Show>
        <Show when={passkeyError()}><p class="error">{passkeyError()}</p></Show>
        <p class="empty">
          {(passkeys()?.length ?? 0) > 0
            ? "Every device signs in with a passkey. On one without yours, use your phone: the browser shows a code to scan."
            : "Add one and pairing links stop working: from then on, every device signs in with a passkey."}
        </p>
        <button class="link" onClick={async () => { await api.signOut(); setCredential(null); }}>Sign Out</button>
        <button class="link" onClick={async () => { await api.signOutEverywhere(); setCredential(null); }}>Sign Out Everywhere</button>
      </Show>

      <h2>Soulseek and Bandcamp</h2>
      <p class="empty">
        {status()?.username ? `Soulseek: ${status()?.username}. ` : "Soulseek isn't signed in. "}
        {status()?.bandcamp ? `Bandcamp: ${status()?.bandcamp}. ` : ""}
        Seek on your Mac signs in to these: change them in its Settings.
      </p>
    </section>
  );
}
