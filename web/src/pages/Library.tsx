import { A } from "@solidjs/router";
import { live } from "../live";
import { For, Show } from "solid-js";
import { albumHref, api, changes } from "../api";

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
              <img src={album.artwork} alt="" loading="lazy" onError={(e) => e.currentTarget.classList.add("missing")} />
              <div class="tile-title">{album.title}</div>
              <div class="tile-sub">{album.artist}</div>
            </A>
          )}
        </For>
      </div>
    </section>
  );
}
