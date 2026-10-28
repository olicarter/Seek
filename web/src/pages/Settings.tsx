import { createSignal, Show } from "solid-js";
import { api, changes, isPaired, serverAddress, setCredential, setServerAddress } from "../api";
import { addPasskey, canUsePasskeys, deviceName } from "../passkeys";
import { For } from "solid-js";
import { live } from "../live";

export function Settings() {
  const [status, { mutate }] = live(changes, api.status);
  const [username, setUsername] = createSignal("");
  const [password, setPassword] = createSignal("");
  const [busy, setBusy] = createSignal(false);
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

  const signIn = async (e: SubmitEvent) => {
    e.preventDefault();
    setBusy(true);
    try {
      mutate(await api.login(username(), password()));
    } finally {
      setBusy(false);
      setPassword("");
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

      <h2>Soulseek</h2>
      <Show
        when={status()?.signedIn}
        fallback={
          <form class="login" onSubmit={signIn}>
            <input placeholder="Username" autocomplete="username" value={username()} onInput={(e) => setUsername(e.currentTarget.value)} />
            <input type="password" placeholder="Password" autocomplete="current-password" value={password()} onInput={(e) => setPassword(e.currentTarget.value)} />
            <button disabled={busy() || !username() || !password()}>{busy() ? "Signing In…" : "Sign In"}</button>
            <Show when={status()?.failure}><p class="error">{status()?.failure}</p></Show>
            <p class="empty">Kept in this Mac's keychain. Soulseek allows one sign-in per account, so the phone and this server take turns.</p>
          </form>
        }
      >
        <p>Signed in as <strong>{status()?.username}</strong> ({status()?.soulseek}).</p>
        <button onClick={async () => mutate(await api.logout())}>Sign Out</button>
      </Show>

      <h2>Bandcamp</h2>
      <Show
        when={status()?.bandcamp}
        fallback={
          <>
            <button disabled={status()?.bandcampSigningIn} onClick={async () => mutate(await api.bandcampSignIn())}>
              {status()?.bandcampSigningIn ? "Waiting for Sign-In…" : "Sign In"}
            </button>
            <p class="empty">
              Bandcamp's sign-in page opens in a window on the Mac running the server. Seek keeps Bandcamp's session there,
              never your password, so your purchases show up in Search and add from Bandcamp.
            </p>
          </>
        }
      >
        <p>Signed in as <strong>{status()?.bandcamp}</strong>.</p>
        <button onClick={async () => mutate(await api.bandcampSignOut())}>Sign Out</button>
      </Show>
    </section>
  );
}
