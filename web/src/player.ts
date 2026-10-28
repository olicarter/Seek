import { createSignal } from "solid-js";

/** A song the player can play: one in the library, by its file on the server. */
export type QueueItem = { file: string; title: string; artist: string; album: string; artwork?: string };

const audio = new Audio();
audio.preload = "auto";

const [queue, setQueue] = createSignal<QueueItem[]>([]);
const [index, setIndex] = createSignal(0);
const [playing, setPlaying] = createSignal(false);
const [time, setTime] = createSignal(0);
const [length, setLength] = createSignal(0);

audio.addEventListener("play", () => setPlaying(true));
audio.addEventListener("pause", () => setPlaying(false));
audio.addEventListener("timeupdate", () => setTime(audio.currentTime));
audio.addEventListener("durationchange", () => setLength(isFinite(audio.duration) ? audio.duration : 0));
audio.addEventListener("ended", () => next());

function load(i: number) {
  const item = queue()[i];
  if (!item) return;
  setIndex(i);
  audio.src = item.file;
  void audio.play();
  if ("mediaSession" in navigator) {
    navigator.mediaSession.metadata = new MediaMetadata({
      title: item.title,
      artist: item.artist,
      album: item.album,
      artwork: item.artwork ? [{ src: item.artwork }] : [],
    });
  }
}

export function play(items: QueueItem[], start = 0) {
  setQueue(items);
  load(start);
}

export function toggle() {
  if (!current()) return;
  if (audio.paused) void audio.play();
  else audio.pause();
}

export function next() {
  if (index() + 1 < queue().length) load(index() + 1);
  else {
    audio.pause();
    audio.currentTime = 0;
  }
}

export function previous() {
  // Like Apple Music: back to the start, unless it's only just begun.
  if (audio.currentTime > 3 || index() === 0) audio.currentTime = 0;
  else load(index() - 1);
}

export function seek(seconds: number) {
  audio.currentTime = seconds;
}

export const current = () => queue()[index()];
export { playing, time, length };

if ("mediaSession" in navigator) {
  navigator.mediaSession.setActionHandler("play", () => void audio.play());
  navigator.mediaSession.setActionHandler("pause", () => audio.pause());
  navigator.mediaSession.setActionHandler("nexttrack", next);
  navigator.mediaSession.setActionHandler("previoustrack", previous);
}
