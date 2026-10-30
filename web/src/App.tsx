import { A, useLocation, useNavigate } from "@solidjs/router";
import { createEffect, createResource, createSignal, type ParentProps, Show } from "solid-js";
import { api, changes, NotPaired, serverAddress } from "./api";
import { Icon } from "./Icons";
import { PlayerBar } from "./PlayerBar";
import { SignIn } from "./SignIn";

/**
 * The page around every page, as Apple Music's on the web: a sidebar with search and the
 * library, the page beside it, and the player floating over the bottom. On a phone's width the
 * sidebar becomes a tab bar.
 */
export function App(props: ParentProps) {
  const [status] = createResource(changes, api.status);
  // Reading a resource that failed throws: the server's status only while it's answering.
  const reached = () => (status.error ? undefined : status());
  const [failure, setFailure] = createSignal<string>();
  const navigate = useNavigate();
  const location = useLocation();
  const [query, setQuery] = createSignal("");

  // An album that couldn't be added says so once, wherever Add was pressed.
  createEffect(() => {
    changes();
    api.takeFailure().then((taken) => taken.message && setFailure(taken.message)).catch(() => {});
  });

  const search = (e: SubmitEvent) => {
    e.preventDefault();
    const q = query().trim();
    if (q) navigate(`/search?q=${encodeURIComponent(q)}`);
  };

  const downloading = () => reached()?.downloading ?? 0;

  return (
    <div class="app">
      <aside class="sidebar">
        <A class="wordmark" href="/">Seek</A>
        <form class="sidebar-search" onSubmit={search}>
          <Icon name="search" size={15} />
          <input type="search" placeholder="Search" value={query()} onInput={(e) => setQuery(e.currentTarget.value)}
                 onFocus={() => location.pathname !== "/search" && !query() && navigate("/search")} />
        </form>
        <nav>
          <p class="sidebar-heading">Library</p>
          <A href="/" end><Icon name="albums" size={18} />Albums</A>
          <A href="/artists"><Icon name="artists" size={18} />Artists</A>
          <p class="sidebar-heading">Seek</p>
          <A href="/search" class="only-narrow"><Icon name="search" size={18} />Search</A>
          <A href="/downloads">
            <Icon name="downloads" size={18} />Downloads
            <Show when={downloading() > 0}><span class="badge">{downloading()}</span></Show>
          </A>
          <A href="/settings"><Icon name="settings" size={18} />Settings</A>
        </nav>
      </aside>
      <div class="content">
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
      </div>
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
