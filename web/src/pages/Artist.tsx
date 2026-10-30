import { useSearchParams } from "@solidjs/router";
import { For, Show } from "solid-js";
import { albumHref, api, changes } from "../api";
import { live } from "../live";
import { Grid, Shelf } from "../Tiles";

/** An artist's page, as in the app: their albums here, then what else they've released. */
export function Artist() {
  const [params] = useSearchParams<{ name: string }>();
  const [page] = live(() => [changes(), params.name ?? ""] as const, ([, name]) => api.artist(name));
  return (
    <Show when={page()} fallback={<p class="empty">Loading…</p>}>
      {(artist) => (
        <section>
          <div class="page-head"><h1 class="artist-name">{artist().name}</h1></div>
          <Show when={artist().albums.length}>
            <h2>In Your Library</h2>
            <Grid items={artist().albums.map((a) => ({
              href: albumHref(a), title: a.title, subtitle: a.year ? String(a.year) : undefined, artwork: a.artwork, preview: a.preview,
            }))} />
          </Show>
          <For each={artist().sections}>
            {(section) => (
              <Shelf title={section.title} items={section.releases.map((r) => ({
                href: albumHref({ artist: artist().name, title: r.title }), title: r.title, subtitle: String(r.year), artwork: r.artwork,
              }))} />
            )}
          </For>
        </section>
      )}
    </Show>
  );
}
