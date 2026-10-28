import { For, Show } from "solid-js";
import { live } from "../live";
import { api, changes } from "../api";
import { speed } from "../format";

export function Downloads() {
  const [downloads] = live(changes, api.downloads);
  return (
    <section>
      <h1>Downloads</h1>
      <Show when={downloads()?.length === 0}>
        <p class="empty">Nothing downloading.</p>
      </Show>
      <ul class="rows">
        <For each={downloads()}>
          {(download) => (
            <li class="row download">
              <div class="row-text">
                <div class="row-title">{download.name}</div>
                <div class="row-sub">{[download.album, download.user].join(" · ")}</div>
                <Show when={download.active}>
                  <progress value={download.progress} max="1" />
                </Show>
              </div>
              <div class="row-state">
                <div>{download.state}</div>
                <div class="row-sub">{download.active ? speed(download.speed) : ""}</div>
              </div>
            </li>
          )}
        </For>
      </ul>
    </section>
  );
}
