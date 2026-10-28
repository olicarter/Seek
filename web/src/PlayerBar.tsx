import { Show } from "solid-js";
import { current, length, next, playing, previous, seek, time, toggle } from "./player";
import { duration } from "./format";

export function PlayerBar() {
  return (
    <Show when={current()}>
      {(song) => (
        <footer class="player">
          <Show when={song().artwork} fallback={<div class="player-art" />}>
            <img class="player-art" src={song().artwork} alt="" />
          </Show>
          <div class="player-song">
            <div class="player-title">{song().title}</div>
            <div class="player-artist">{song().artist}</div>
          </div>
          <div class="player-controls">
            <button aria-label="Previous" onClick={previous}>⏮</button>
            <button aria-label={playing() ? "Pause" : "Play"} class="player-play" onClick={toggle}>
              {playing() ? "⏸" : "▶"}
            </button>
            <button aria-label="Next" onClick={next}>⏭</button>
          </div>
          <div class="player-time">
            <span>{duration(time())}</span>
            <input
              type="range"
              min="0"
              max={length() || 1}
              step="0.5"
              value={time()}
              onInput={(e) => seek(Number(e.currentTarget.value))}
              aria-label="Position"
            />
            <span>{duration(length())}</span>
          </div>
        </footer>
      )}
    </Show>
  );
}
