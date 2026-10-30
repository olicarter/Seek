import { live } from "../live";
import { createMemo, Show } from "solid-js";
import { api, artistHref, changes } from "../api";
import { Grid } from "../Tiles";

/** The library's artists, each shown with the cover of their newest album. */
export function Artists() {
  const [albums] = live(changes, api.library);
  const artists = createMemo(() => {
    const byArtist = new Map<string, { name: string; artwork?: string; preview?: string; year: number; count: number }>();
    for (const album of albums() ?? []) {
      const key = album.artist.toLowerCase();
      const known = byArtist.get(key);
      if (!known) byArtist.set(key, { name: album.artist, artwork: album.artwork, preview: album.preview, year: album.year ?? 0, count: 1 });
      else {
        known.count += 1;
        if ((album.year ?? 0) > known.year) Object.assign(known, { artwork: album.artwork, preview: album.preview, year: album.year ?? 0 });
      }
    }
    return [...byArtist.values()]
      .sort((a, b) => a.name.localeCompare(b.name, undefined, { sensitivity: "base" }))
      .map((a) => ({ href: artistHref(a.name), title: a.name, subtitle: a.count === 1 ? "1 album" : `${a.count} albums`,
                     artwork: a.artwork, preview: a.preview }));
  });
  return (
    <section>
      <div class="page-head"><h1>Artists</h1></div>
      <Show when={albums()?.length === 0}><p class="empty">Nothing here yet.</p></Show>
      <Grid items={artists()} round />
    </section>
  );
}
