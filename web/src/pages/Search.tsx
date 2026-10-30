import { useNavigate, useSearchParams } from "@solidjs/router";
import { live } from "../live";
import { createEffect, createSignal, on, onMount, Show } from "solid-js";
import { albumHref, api, changes } from "../api";
import { Quality } from "../Quality";
import { Grid } from "../Tiles";

export function Search() {
  const [params] = useSearchParams<{ q?: string }>();
  const navigate = useNavigate();
  const [text, setText] = createSignal(params.q ?? "");
  const [page] = live(changes, api.searchPage);
  const [status] = live(changes, api.status);

  // A search in the address (a link, or coming back) runs unless it's the one on the server.
  createEffect(on(() => params.q, (q) => {
    if (q !== undefined) setText(q);
    if (q && q !== page()?.query) void api.search(q);
  }));

  // Opening Search with nothing typed is for typing: straight into the field (autofocus only
  // works on a page's first load, not on moving between the site's pages).
  let field: HTMLInputElement | undefined;
  onMount(() => {
    if (!text()) field?.focus();
  });

  const submit = (e: SubmitEvent) => {
    e.preventDefault();
    const q = text().trim();
    if (!q) return;
    navigate(`/search?q=${encodeURIComponent(q)}`);
    void api.search(q);
  };

  return (
    <section>
      <div class="page-head"><h1>Search</h1></div>
      {/* The sidebar has the search field; a phone's width, where it's a tab bar, has this one. */}
      <form class="search only-narrow" onSubmit={submit}>
        <input ref={field} type="search" placeholder="Artists, albums, songs" value={text()} onInput={(e) => setText(e.currentTarget.value)} />
      </form>
      <Show when={status() && !status()!.signedIn}>
        <p class="empty">
          Sign in to Soulseek in Seek on your Mac to include other people's music.
        </p>
      </Show>
      <Show when={page()?.query}>
        <Show when={(page()?.releases.length ?? 0) > 0} fallback={<p class="empty">{page()?.searching ? "Searching…" : "Nothing found."}</p>}>
          <h2>Releases</h2>
          <Grid items={(page()?.releases ?? []).map((release) => ({
            href: albumHref({ artist: release.artist, title: release.title, release: release.id }),
            title: release.title,
            subtitle: [release.kind, release.artist, release.year].filter(Boolean).join(" · "),
            artwork: release.artwork,
            badges: (
              <>
                <Show when={release.inLibrary}><span class="badge-pill">In Library</span></Show>
                <Show when={release.adding}><span class="badge-pill">Adding…</span></Show>
                <Show when={release.copies > 0}>
                  <span class="badge-pill quiet">{release.copies} {release.copies === 1 ? "copy" : "copies"}</span>
                </Show>
                <Quality quality={release.quality} />
                <Show when={release.bandcamp}><span class="badge-pill bandcamp">Bandcamp</span></Show>
              </>
            ),
          }))} />
          <Show when={page()?.searching}><p class="empty">Still looking…</p></Show>
        </Show>
      </Show>
    </section>
  );
}
