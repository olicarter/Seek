import { A } from "@solidjs/router";
import { Show } from "solid-js";
import { api } from "./api";
import { Icon } from "./Icons";
import { media } from "./api";
import { useJam, usePosition } from "./jam";

/** A guest's player: the Jam's song, its controls when the host allows them, and the way to the queue. */
export function JamBar() {
  const [page, { mutate }] = useJam();
  const position = usePosition(() => page());
  const control = async (action: "play" | "pause" | "next" | "previous") => {
    try {
      mutate(await api.controlJam(action));
    } catch {
      // Refused or out of reach: the bar shows what's so on the next change.
    }
  };

  return (
    <Show when={page()?.nowPlaying}>
      {(song) => (
        <footer class="player jam-bar">
          <Show when={page()!.canControl} fallback={<span />}>
            <div class="player-controls">
              <button aria-label="Previous" onClick={() => control("previous")}><Icon name="previous" size={20} /></button>
              <button aria-label={page()!.playing ? "Pause" : "Play"} class="player-play"
                      onClick={() => control(page()!.playing ? "pause" : "play")}>
                <Icon name={page()!.playing ? "pause" : "play"} size={26} />
              </button>
              <button aria-label="Next" onClick={() => control("next")}><Icon name="next" size={20} /></button>
            </div>
          </Show>
          <A class="player-song" href="/jam">
            <img class="player-art" src={media(song().cover)} alt="" />
            <div class="player-text">
              <div class="player-title">{song().title}</div>
              <div class="player-artist">{song().artist} · added by {song().mine ? "you" : song().addedBy}</div>
            </div>
            <div class="player-progress">
              <div class="player-progress-fill" style={{ width: `${song().duration ? Math.min(position() / song().duration, 1) * 100 : 0}%` }} />
            </div>
          </A>
          <A class="jam-bar-queue" href="/jam">Up Next · {page()!.upNext.length}</A>
        </footer>
      )}
    </Show>
  );
}
