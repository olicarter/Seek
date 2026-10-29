import { A } from "@solidjs/router";
import { live } from "../live";
import { For, Show } from "solid-js";
import { albumHref, api, changes } from "../api";
import { Cover } from "../Cover";

export function Library() {
  const [albums] = live(changes, api.library);
  return (
    <section>
      <h1>Library</h1>
      <Show when={albums()?.length === 0}>
        <p class="empty">Nothing here yet. Albums added from Search arrive here, and on your phone.</p>
      </Show>
      <div class="grid">
        <For each={albums()}>
          {(album) => (
            <A class="tile" href={albumHref(album)}>
              <Cover src={album.artwork} preview={album.preview} lazy />
              <div class="tile-title">{album.title}</div>
              <div class="tile-sub">{album.artist}</div>
            </A>
          )}
        </For>
      </div>
    </section>
  );
}
