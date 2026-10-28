import { A, useSearchParams } from "@solidjs/router";
import { For, Show } from "solid-js";
import { albumHref, api, changes } from "../api";
import { live } from "../live";

/** An artist's page, as in the app: their albums here, then what else they've released. */
export function Artist() {
  const [params] = useSearchParams<{ name: string }>();
  const [page] = live(() => [changes(), params.name ?? ""] as const, ([, name]) => api.artist(name));
  return (
    <Show when={page()} fallback={<p class="empty">Loading…</p>}>
      {(artist) => (
        <section>
          <h1>{artist().name}</h1>
          <div class="grid">
            <For each={artist().albums}>
              {(album) => (
                <A class="tile" href={albumHref(album)}>
                  <img src={album.artwork} alt="" loading="lazy" onError={(e) => e.currentTarget.classList.add("missing")} />
                  <div class="tile-title">{album.title}</div>
                  <div class="tile-sub">{album.year ?? ""}</div>
                </A>
              )}
            </For>
          </div>
          <For each={artist().sections}>
            {(section) => (
              <>
                <h2>{section.title}</h2>
                <div class="grid">
                  <For each={section.releases}>
                    {(release) => (
                      <A class="tile" href={albumHref({ artist: artist().name, title: release.title })}>
                        <img src={release.artwork} alt="" loading="lazy" onError={(e) => e.currentTarget.classList.add("missing")} />
                        <div class="tile-title">{release.title}</div>
                        <div class="tile-sub">{release.year}</div>
                      </A>
                    )}
                  </For>
                </div>
              </>
            )}
          </For>
        </section>
      )}
    </Show>
  );
}
