import { createResource, createSignal, Show } from "solid-js";
import { api } from "../api";

export function Settings() {
  const [status, { mutate }] = createResource(api.status);
  const [username, setUsername] = createSignal("");
  const [password, setPassword] = createSignal("");
  const [busy, setBusy] = createSignal(false);

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
    </section>
  );
}
