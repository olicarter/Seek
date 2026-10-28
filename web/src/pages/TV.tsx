import { useSearchParams } from "@solidjs/router";
import { createSignal, Show } from "solid-js";
import { api } from "../api";

/** Signs in a TV: it shows a code (and a QR code for this page with the code filled in). */
export function TV() {
  const [params] = useSearchParams<{ code?: string }>();
  const [code, setCode] = createSignal(params.code ?? "");
  const [done, setDone] = createSignal<string>();
  const [error, setError] = createSignal<string>();

  const approve = async (e: SubmitEvent) => {
    e.preventDefault();
    setError();
    try {
      const { name } = await api.approveDevice(code());
      setDone(name);
    } catch {
      setError("That code didn't work. Check it against the TV, or start again there for a new one.");
    }
  };

  return (
    <section>
      <h1>Sign In a TV</h1>
      <Show
        when={!done()}
        fallback={<p>Done: {done()} is signed in. You can close this page.</p>}
      >
        <form class="login" onSubmit={approve}>
          <input placeholder="Code on the TV" value={code()} autocapitalize="characters" autocomplete="off"
                 onInput={(e) => setCode(e.currentTarget.value)} />
          <button disabled={code().replace(/[^A-Za-z0-9]/g, "").length < 8}>Sign In the TV</button>
          <Show when={error()}><p class="error">{error()}</p></Show>
          <p class="empty">The TV gets its own sign-in, which Sign Out Everywhere in Settings ends.</p>
        </form>
      </Show>
    </section>
  );
}
