import { A } from "@solidjs/router";
import { createSignal, Show } from "solid-js";
import { albumHref } from "./api";
import { duration } from "./format";
import { Icon } from "./Icons";
import { current, hasNext, length, next, playing, previous, seek, setVolume, time, toggle, volume } from "./player";

/**
 * The player, as Apple Music's on the web: the controls, then the song in a panel of its own
 * with its progress along the bottom (dragged to seek), then the volume.
 */
export function PlayerBar() {
  const [dragging, setDragging] = createSignal<number>();
  const shown = () => dragging() ?? time();
  const fraction = () => (length() > 0 ? Math.min(shown() / length(), 1) : 0);

  const position = (e: PointerEvent, bar: HTMLElement) => {
    const box = bar.getBoundingClientRect();
    return Math.min(Math.max((e.clientX - box.left) / box.width, 0), 1) * length();
  };

  return (
    <Show when={current()}>
      {(song) => (
        <footer class="player">
          <div class="player-controls">
            <button aria-label="Previous" onClick={previous}><Icon name="previous" size={20} /></button>
            <button aria-label={playing() ? "Pause" : "Play"} class="player-play" onClick={toggle}>
              <Icon name={playing() ? "pause" : "play"} size={26} />
            </button>
            <button aria-label="Next" disabled={!hasNext()} onClick={next}><Icon name="next" size={20} /></button>
          </div>
          <div class="player-song">
            <Show when={song().artwork} fallback={<div class="player-art" />}>
              <img class="player-art" src={song().artwork} alt="" />
            </Show>
            <div class="player-text">
              <div class="player-title">{song().title}</div>
              <div class="player-artist">
                <A href={albumHref({ artist: song().artist, title: song().album })}>{song().artist} — {song().album}</A>
              </div>
            </div>
            <span class="player-time start">{duration(shown())}</span>
            <span class="player-time end">-{duration(Math.max(length() - shown(), 0))}</span>
            <div
              class="player-progress"
              role="slider"
              aria-label="Position"
              aria-valuemin={0}
              aria-valuemax={length()}
              aria-valuenow={shown()}
              tabIndex={0}
              onPointerDown={(e) => {
                const bar = e.currentTarget;
                bar.setPointerCapture(e.pointerId);
                setDragging(position(e, bar));
              }}
              onPointerMove={(e) => dragging() !== undefined && setDragging(position(e, e.currentTarget))}
              onPointerUp={(e) => {
                seek(position(e, e.currentTarget));
                setDragging();
              }}
              onKeyDown={(e) => {
                if (e.key === "ArrowRight") seek(Math.min(time() + 5, length()));
                if (e.key === "ArrowLeft") seek(Math.max(time() - 5, 0));
              }}
            >
              <div class="player-progress-fill" style={{ width: `${fraction() * 100}%` }} />
            </div>
          </div>
          <label class="player-volume">
            <Icon name="volume" size={18} />
            <input type="range" min="0" max="1" step="0.01" value={volume()} aria-label="Volume"
                   onInput={(e) => setVolume(Number(e.currentTarget.value))} />
          </label>
        </footer>
      )}
    </Show>
  );
}
