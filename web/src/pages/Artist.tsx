import { useParams } from "@solidjs/router";
import { For, Show } from "solid-js";
import { albumHref, api, changes, fromPath, type ArtistPage } from "../api";
import { live } from "../live";
import { Grid, type TileItem } from "../Tiles";
import { About } from "../About";

/**
 * An artist's page, as in the app: everything they've released under Apple Music's headings,
 * the albums in the library where they'd be anyway, marked as in the library.
 */
export function Artist() {
  const params = useParams<{ artist: string }>();
  const [page] = live(() => [changes(), fromPath(params.artist)] as const, ([, name]) => api.artist(name), ([, name]) => `artist|${name}`);
  const items = (artist: ArtistPage, releases: ArtistPage["sections"][number]["releases"]): TileItem[] =>
    releases.map((r) => ({
      href: albumHref({ artist: r.artist ?? artist.name, title: r.title }),
      title: r.title,
      subtitle: r.year ? String(r.year) : undefined,
      artwork: r.artwork,
      preview: r.preview,
      inLibrary: r.inLibrary,
    }));
  return (
    <Show when={page()} fallback={<p class="empty">Loading…</p>}>
      {(artist) => (
        <section>
          <div class="page-head"><h1 class="artist-name">{artist().name}</h1></div>
          <div class="artist-about"><About text={artist().about} /></div>
          <For each={artist().sections}>
            {(section) => (
              <>
                <h2>{section.title}</h2>
                <Grid items={items(artist(), section.releases)} />
              </>
            )}
          </For>
          <Show when={!artist().sections.length}><p class="empty">Nothing found for this artist.</p></Show>
        </section>
      )}
    </Show>
  );
}
