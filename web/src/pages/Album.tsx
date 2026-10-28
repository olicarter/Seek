import { A, useSearchParams } from "@solidjs/router";
import { live } from "../live";
import { For, Show } from "solid-js";
import { api, artistHref, changes, type AlbumPage, type AlbumRef, type Song } from "../api";
import { duration } from "../format";
import { current, play, type QueueItem } from "../player";

/** The album page, the same for albums in the library and ones that aren't (as in the app). */
export function Album() {
  const [params] = useSearchParams<{ artist: string; title: string; release?: string }>();
  const ref = (): AlbumRef => ({ artist: params.artist ?? "", title: params.title ?? "", release: params.release });
  const [page, { mutate }] = live(() => [changes(), ref()] as const, ([, r]) => api.album(r));

  const queue = (album: AlbumPage): QueueItem[] =>
    album.songs.filter((s) => s.file).map((s) => ({
      file: s.file!, title: s.title, artist: s.artist ?? album.artist, album: album.title, artwork: album.artwork,
    }));

  const playFrom = (album: AlbumPage, song?: Song) => {
    const items = queue(album);
    const start = song ? items.findIndex((i) => i.file === song.file) : 0;
    if (items.length) play(items, Math.max(start, 0));
  };

  const shuffle = (album: AlbumPage) => {
    const items = [...queue(album)];
    for (let i = items.length - 1; i > 0; i--) {
      const j = Math.floor(Math.random() * (i + 1));
      [items[i], items[j]] = [items[j], items[i]];
    }
    if (items.length) play(items);
  };

  const add = async () => mutate(await api.add(ref()));

  return (
    <Show when={page()} fallback={<p class="empty">Loading…</p>}>
      {(album) => (
        <section class="album">
          <header class="album-header">
            <Show when={album().artwork} fallback={<div class="album-art" />}>
              <img class="album-art" src={album().artwork} alt="" />
            </Show>
            <h1 class="album-title">{album().title}</h1>
            <A class="album-artist" href={artistHref(album().artist)}>{album().artist}</A>
            <Show when={album().year}><div class="album-year">{album().year}</div></Show>
            <div class="album-actions">
              <button class="round" aria-label="Shuffle" disabled={!queue(album()).length} onClick={() => shuffle(album())}>⤮</button>
              <button class="play" disabled={!queue(album()).length} onClick={() => playFrom(album())}>▶ Play</button>
              <Show
                when={album().adding}
                fallback={
                  <button class="round" aria-label={album().inLibrary && !album().canAdd ? "In Library" : "Add to Library"}
                          disabled={!album().canAdd} onClick={add}>
                    {album().inLibrary && !album().canAdd ? "✓" : "+"}
                  </button>
                }
              >
                <span class="round spinner" aria-label="Adding" />
              </Show>
            </div>
            <Show when={album().bandcamp}>
              {(bandcamp) => (
                <Show
                  when={!bandcamp().owned}
                  fallback={<p class="album-note">In your Bandcamp collection{bandcamp().downloading !== undefined ? " · adding…" : ""}</p>}
                >
                  <a class="buy" href={bandcamp().page} target="_blank" rel="noopener" onClick={() => void api.buying()}>
                    Buy on Bandcamp{bandcamp().price ? ` · ${bandcamp().price}` : ""}
                  </a>
                </Show>
              )}
            </Show>
            <Show when={!album().inLibrary && album().listed && !album().copies && !album().bandcamp?.owned}>
              <p class="album-note">{album().lookingForCopies ? "Looking on Soulseek…" : "No copies on Soulseek right now."}</p>
            </Show>
          </header>

          <ol class="songs">
            <For each={album().songs}>
              {(song) => (
                <li
                  classList={{ song: true, missing: song.kind !== "have", playable: !!song.file, current: !!song.file && current()?.file === song.file }}
                  title={song.kind === "missing" && song.file ? "Not in your library: plays from Soulseek" : undefined}
                  onClick={() => song.file && playFrom(album(), song)}
                >
                  <span class="song-number">{song.number ?? ""}</span>
                  <span class="song-title">
                    {song.title}
                    <Show when={song.artist}><span class="song-artist">{song.artist}</span></Show>
                  </span>
                  <Show when={song.progress !== undefined} fallback={<span class="song-duration">{duration(song.duration)}</span>}>
                    <progress value={song.progress} max="1" />
                  </Show>
                </li>
              )}
            </For>
          </ol>
          <p class="album-footer">{album().footer}</p>
        </section>
      )}
    </Show>
  );
}
