import { A } from "@solidjs/router";
import { createEffect, createResource, createSignal, type ParentProps, Show } from "solid-js";
import { api, changes } from "./api";
import { PlayerBar } from "./PlayerBar";

/** The tabs, as in the app, the page, the player, and why an album wasn't added. */
export function App(props: ParentProps) {
  const [status] = createResource(changes, api.status);
  const [failure, setFailure] = createSignal<string>();

  // An album that couldn't be added says so once, wherever Add was pressed.
  createEffect(() => {
    changes();
    void api.takeFailure().then((taken) => taken.message && setFailure(taken.message));
  });

  return (
    <div class="app">
      <nav class="tabs">
        <A href="/" end>Library</A>
        <A href="/search">Search</A>
        <A href="/downloads">
          Downloads
          <Show when={(status()?.downloading ?? 0) > 0}>
            <span class="badge">{status()?.downloading}</span>
          </Show>
        </A>
        <A href="/settings">Settings</A>
      </nav>
      <main>{props.children}</main>
      <PlayerBar />
      <Show when={failure()}>
        <div class="toast" role="alert">
          <p>{failure()}</p>
          <button onClick={() => setFailure()}>OK</button>
        </div>
      </Show>
    </div>
  );
}
