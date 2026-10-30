import { live } from "../live";
import { createMemo, createSignal, Show } from "solid-js";
import { albumHref, api, changes } from "../api";
import { Grid } from "../Tiles";

/** The library's albums, as Apple Music's Albums: covers filling the page, sorted as chosen. */
export function Library() {
  const [albums] = live(changes, api.library);
  const [sort, setSort] = createSignal<"title" | "artist" | "year">("artist");
  const sorted = createMemo(() => {
    const list = [...(albums() ?? [])];
    const by = sort();
    const text = (a: string, b: string) => a.localeCompare(b, undefined, { sensitivity: "base" });
    list.sort((a, b) =>
      by === "title" ? text(a.title, b.title)
        : by === "year" ? (b.year ?? 0) - (a.year ?? 0) || text(a.title, b.title)
          : text(a.artist, b.artist) || (a.year ?? 0) - (b.year ?? 0));
    return list.map((a) => ({ href: albumHref(a), title: a.title, subtitle: a.artist, artwork: a.artwork, preview: a.preview }));
  });
  return (
    <section>
      <div class="page-head">
        <h1>Albums</h1>
        <label class="sort">
          Sort by
          <select value={sort()} onChange={(e) => setSort(e.currentTarget.value as "title" | "artist" | "year")}>
            <option value="artist">Artist</option>
            <option value="title">Title</option>
            <option value="year">Year</option>
          </select>
        </label>
      </div>
      <Show when={albums()?.length === 0}>
        <p class="empty">Nothing here yet. Albums added from Search arrive here, and on your phone.</p>
      </Show>
      <Grid items={sorted()} />
    </section>
  );
}
