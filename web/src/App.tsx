import { A } from "@solidjs/router";
import { createEffect, createResource, createSignal, type ParentProps, Show } from "solid-js";
import { api, changes, NotPaired, serverAddress } from "./api";
import { PlayerBar } from "./PlayerBar";
import { SignIn } from "./SignIn";

/** The tabs, as in the app, the page, the player, and why an album wasn't added. */
export function App(props: ParentProps) {
  const [status] = createResource(changes, api.status);
  // Reading a resource that failed throws: the server's status only while it's answering.
  const reached = () => (status.error ? undefined : status());
  const [failure, setFailure] = createSignal<string>();

  // An album that couldn't be added says so once, wherever Add was pressed.
  createEffect(() => {
    changes();
    api.takeFailure().then((taken) => taken.message && setFailure(taken.message)).catch(() => {});
  });

  return (
    <div class="app">
      <nav class="tabs">
        <A href="/" end>Library</A>
        <A href="/search">Search</A>
        <A href="/downloads">
          Downloads
          <Show when={(reached()?.downloading ?? 0) > 0}>
            <span class="badge">{reached()?.downloading}</span>
          </Show>
        </A>
        <A href="/settings">Settings</A>
      </nav>
      <Show when={status.error instanceof NotPaired}>
        <SignIn />
      </Show>
      <Show when={status.error && !(status.error instanceof NotPaired)}>
        <p class="offline">
          Can't reach Seek on your Mac{serverAddress() ? ` at ${serverAddress()}` : ""}. Check it's running.{" "}
          <A href="/settings">Change the address</A>
        </p>
      </Show>
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
