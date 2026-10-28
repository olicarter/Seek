import { createSignal, Show } from "solid-js";
import { api, changes, serverAddress, setServerAddress } from "../api";
import { live } from "../live";

export function Settings() {
  const [status, { mutate }] = live(changes, api.status);
  const [username, setUsername] = createSignal("");
  const [password, setPassword] = createSignal("");
  const [busy, setBusy] = createSignal(false);
  const [address, setAddress] = createSignal(serverAddress());

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
      </form>
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
