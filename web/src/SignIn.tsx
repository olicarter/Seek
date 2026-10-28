import { createResource, createSignal, Show } from "solid-js";
import { api } from "./api";
import { canUsePasskeys, signIn } from "./passkeys";

/** Shown while this browser isn't in: sign in with a passkey (or, before there is one, pair). */
export function SignIn() {
  const [auth] = createResource(() => api.auth().catch(() => undefined));
  const [error, setError] = createSignal<string>();
  const [busy, setBusy] = createSignal(false);

  const start = async () => {
    setBusy(true);
    setError();
    try {
      await signIn();
    } catch (e) {
      // Cancelling the passkey prompt isn't worth a message.
      if (!(e instanceof DOMException && e.name === "NotAllowedError")) setError(e instanceof Error ? e.message : String(e));
    } finally {
      setBusy(false);
    }
  };

  return (
    <div class="offline signin">
      <Show
        when={auth()?.passkeys}
        fallback={
          <p>
            This browser isn't paired with Seek yet. On the Mac running Seek, open <strong>localhost:8765/pair</strong>,
            then scan its code or open its link here. Then add a passkey in Settings.
          </p>
        }
      >
        <Show
          when={canUsePasskeys()}
          fallback={<p>Sign in to Seek at <a href="https://4n.studio/seek/web/">4n.studio/seek/web</a>, where your passkey works.</p>}
        >
          <p>Sign in to Seek with your passkey. On a device without it, choose to use your phone and scan the code.</p>
          <button disabled={busy()} onClick={start}>{busy() ? "Signing In…" : "Sign In with Passkey"}</button>
          <Show when={error()}><p class="error">{error()}</p></Show>
        </Show>
      </Show>
    </div>
  );
}
