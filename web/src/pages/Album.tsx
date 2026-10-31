import { A, useParams, useSearchParams } from "@solidjs/router";
import { live } from "../live";
import { createMemo, For, Show } from "solid-js";
import { albumHref, api, artistHref, changes, fromPath, isGuest, media, type AlbumPage, type AlbumRef, type Song } from "../api";
import { tell } from "../jam";
import { duration } from "../format";
import { Cover } from "../Cover";
import { Icon } from "../Icons";
import { Quality } from "../Quality";
import { About } from "../About";
import { Shelf, type TileItem } from "../Tiles";
import { current, play, playing, type QueueItem } from "../player";

/**
 * The album page, as Apple Music's on the web: the cover with the album's details and buttons
 * beside it, the songs across the page, then more by the artist. The same for albums in the
 * library and ones that aren't (as in the app), and tinted with the cover's colour.
 */
export function Album() {
  const params = useParams<{ artist: string; title: string }>();
  const [search] = useSearchParams<{ release?: string }>();
  const ref = (): AlbumRef => ({ artist: fromPath(params.artist), title: fromPath(params.title), release: search.release });
  const [page, { mutate }] = live(() => [changes(), ref()] as const, ([, r]) => api.album(r),
                                  ([, r]) => `album|${r.artist}|${r.title}|${r.release ?? ""}`);
  const [artist] = live(() => page()?.artist, (name) => api.artist(name), (name) => `artist|${name}`);

  const queue = (album: AlbumPage): QueueItem[] =>
    album.songs.filter((s) => s.file).map((s) => ({
      file: media(s.file!), title: s.title, artist: s.artist ?? album.artist, album: album.title, artwork: media(album.artwork),
    }));

  const playFrom = (album: AlbumPage, song?: Song) => {
    const items = queue(album);
    const start = song ? items.findIndex((i) => i.file === media(song.file)) : 0;
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

  // A guest in a Jam picks songs for its queue rather than playing them here.
  const addToJam = async (song: Song) => {
    try {
      await api.addToJam(song.file!);
      tell(`Added “${song.title}” to the Jam`);
    } catch {
      tell(`“${song.title}” can't be added right now`);
    }
  };

  // The artist's other albums and releases, this one left out.
  const more = createMemo((): TileItem[] => {
    const page = artist();
    const album = ref();
    if (!page) return [];
    const same = (title: string) => title.toLowerCase() === album.title.toLowerCase();
    return page.sections.flatMap((s) => s.releases)
      .filter((r) => !same(r.title))
      .map((r) => ({
        href: albumHref({ artist: r.artist ?? page.name, title: r.title }), title: r.title,
        subtitle: r.year ? String(r.year) : undefined, artwork: r.artwork, preview: r.preview, inLibrary: r.inLibrary,
      }));
  });

  const isCurrent = (song: Song) => !!song.file && current()?.file === media(song.file);
  const discs = (album: AlbumPage) => new Set(album.songs.map((s) => s.disc)).size > 1;

  return (
    <Show when={page()} fallback={<p class="empty">Loading…</p>}>
      {(album) => (
        <section class="album" style={album().tint ? { "--tint": album().tint } : {}}>
          <header class="album-header">
            <Cover class="album-art" src={album().artwork} preview={album().preview} />
            <div class="album-info">
              <h1 class="album-title">{album().title}</h1>
              <A class="album-artist" href={artistHref(album().artist)}>{album().artist}</A>
              <div class="album-meta">
                <Show when={album().year}><span>{album().year}</span></Show>
                <Quality quality={album().quality} detail={album().qualityDetail} />
              </div>
              <About text={album().about} />
              <Show when={!album().inLibrary && album().listed && !album().copies && !album().bandcamp?.owned}>
                <p class="album-note">{album().lookingForCopies ? "Looking on Soulseek…" : "No copies on Soulseek right now."}</p>
              </Show>
              <Show when={album().bandcamp?.owned}>
                <p class="album-note">In your Bandcamp collection{album().bandcamp?.downloading !== undefined ? " · adding…" : ""}</p>
              </Show>
              <Show when={isGuest}>
                <p class="album-note">Pick a song to add it to the Jam.</p>
              </Show>
              <div class="album-actions" hidden={isGuest}>
                {/* As in the app: a round shuffle button, a wide white Play, then round buttons. */}
                <button class="circle" aria-label="Shuffle" title="Shuffle" disabled={!queue(album()).length} onClick={() => shuffle(album())}>
                  <Icon name="shuffle" size={20} />
                </button>
                <button class="pill play" disabled={!queue(album()).length} onClick={() => playFrom(album())}>
                  <Icon name="play" size={18} />Play
                </button>
                <Show
                  when={album().adding}
                  fallback={
                    <button class="circle" disabled={!album().canAdd} onClick={add}
                            aria-label={album().inLibrary && !album().canAdd ? "In Library" : "Add to Library"}
                            title={album().inLibrary && !album().canAdd ? "In Library" : "Add to Library"}>
                      <Icon name={album().inLibrary && !album().canAdd ? "check" : "plus"} size={18} />
                    </button>
                  }
                >
                  <span class="circle spinner" aria-label="Adding" />
                </Show>
                <Show when={album().bandcamp && !album().bandcamp!.owned}>
                  <a class="pill bandcamp" href={album().bandcamp!.page} target="_blank" rel="noopener" onClick={() => void api.buying()}>
                    Buy on Bandcamp{album().bandcamp!.price ? ` · ${album().bandcamp!.price}` : ""}
                  </a>
                </Show>
              </div>
            </div>
          </header>

          <ol class="songs">
            <For each={album().songs}>
              {(song, i) => (
                <>
                  <Show when={discs(album()) && (i() === 0 || album().songs[i() - 1].disc !== song.disc)}>
                    <li class="disc">Disc {song.disc}</li>
                  </Show>
                  <li
                    classList={{ song: true, missing: !song.file, playable: !!song.file, current: isCurrent(song) }}
                    title={isGuest ? (song.file ? "Add to the Jam" : undefined)
                      : song.kind === "missing" && song.file ? "Not in your library: plays from Soulseek" : undefined}
                    onClick={() => song.file && (isGuest ? addToJam(song) : playFrom(album(), song))}
                  >
                    <span class="song-number">
                      <Show when={isCurrent(song) && playing()} fallback={
                        <>
                          <span class="number">{song.number ?? ""}</span>
                          <Show when={song.file}><span class="hover-play"><Icon name={isGuest ? "plus" : "play"} size={13} /></span></Show>
                        </>
                      }>
                        <span class="bars" aria-label="Playing"><i /><i /><i /></span>
                      </Show>
                    </span>
                    <span class="song-title">
                      {song.title}
                      <Show when={song.artist}><span class="song-artist">{song.artist}</span></Show>
                    </span>
                    <span class="song-tempo">{song.tempoAndKey ?? ""}</span>
                    <span class="song-end">
                      <Show when={song.progress !== undefined} fallback={<span class="song-duration">{duration(song.duration)}</span>}>
                        <progress value={song.progress} max="1" />
                      </Show>
                    </span>
                  </li>
                </>
              )}
            </For>
          </ol>
          <p class="album-footer">
            <Show when={album().released}>
              {/* Apple dates releases at midnight in California: the day is the UTC one. */}
              {new Date(`${album().released}T00:00:00Z`).toLocaleDateString(undefined, { dateStyle: "long", timeZone: "UTC" })}
              <br />
            </Show>
            {album().footer}
            <Show when={album().copyright}>
              <br />
              {album().copyright}
            </Show>
          </p>
          <Shelf title={`More by ${album().artist}`} items={more()} />
        </section>
      )}
    </Show>
  );
}
