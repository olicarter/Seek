import { A, useNavigate, useSearchParams } from "@solidjs/router";
import { live } from "../live";
import { createEffect, createSignal, For, on, Show } from "solid-js";
import { albumHref, api, changes } from "../api";

export function Search() {
  const [params] = useSearchParams<{ q?: string }>();
  const navigate = useNavigate();
  const [text, setText] = createSignal(params.q ?? "");
  const [page] = live(changes, api.searchPage);
  const [status] = live(changes, api.status);

  // A search in the address (a link, or coming back) runs unless it's the one on the server.
  createEffect(on(() => params.q, (q) => {
    if (q && q !== page()?.query) void api.search(q);
  }));

  const submit = (e: SubmitEvent) => {
    e.preventDefault();
    const q = text().trim();
    if (!q) return;
    navigate(`/search?q=${encodeURIComponent(q)}`);
    void api.search(q);
  };

  return (
    <section>
      <h1>Search</h1>
      <form class="search" onSubmit={submit}>
        <input type="search" placeholder="Artists, albums, songs" value={text()} onInput={(e) => setText(e.currentTarget.value)} autofocus />
      </form>
      <Show when={status() && !status()!.signedIn}>
        <p class="empty">
          <A href="/settings">Sign in to Soulseek</A> to include other people's music.
        </p>
      </Show>
      <Show when={page()?.query}>
        <Show when={(page()?.releases.length ?? 0) > 0} fallback={<p class="empty">{page()?.searching ? "Searching…" : "Nothing found."}</p>}>
          <h2>Releases</h2>
          <ul class="rows">
            <For each={page()?.releases}>
              {(release) => (
                <li>
                  <A class="row" href={albumHref({ artist: release.artist, title: release.title, release: release.id })}>
                    <Show when={release.artwork} fallback={<div class="row-art" />}>
                      <img class="row-art" src={release.artwork} alt="" loading="lazy" />
                    </Show>
                    <div class="row-text">
                      <div class="row-title">{release.title}</div>
                      <div class="row-sub">
                        {[release.kind, release.artist, release.year].filter(Boolean).join(" · ")}
                      </div>
                      <div class="row-badges">
                        <Show when={release.inLibrary}><span class="badge-pill">In Library</span></Show>
                        <Show when={release.adding}><span class="badge-pill">Adding…</span></Show>
                        <Show when={release.copies > 0}>
                          <span class="badge-pill quiet">
                            {release.copies} {release.copies === 1 ? "copy" : "copies"}{release.lossless ? " · lossless" : ""}
                          </span>
                        </Show>
                        <Show when={release.bandcamp}><span class="badge-pill bandcamp">Bandcamp</span></Show>
                      </div>
                    </div>
                  </A>
                </li>
              )}
            </For>
          </ul>
          <Show when={page()?.searching}><p class="empty">Still looking…</p></Show>
        </Show>
      </Show>
    </section>
  );
}
