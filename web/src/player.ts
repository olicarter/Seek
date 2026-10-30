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

/**
 * Compressed copies (AAC, about 128 kbit/s) instead of the files themselves, which at 24-bit
 * need well over a megabit a second: chosen in Settings, or switched to when songs keep stalling.
 */
const savedChoice = (() => {
  try {
    return localStorage.getItem("seek.compressed");
  } catch {
    return null;
  }
})();
const [compressed, setCompressedSignal] = createSignal(savedChoice === "on");
/** Switched to because playback kept stalling, rather than chosen. */
const [compressedForSpeed, setCompressedForSpeed] = createSignal(false);

export function setCompressed(on: boolean) {
  setCompressedSignal(on);
  setCompressedForSpeed(false);
  try {
    localStorage.setItem("seek.compressed", on ? "on" : "off");
  } catch {
    // Private browsing: the choice lasts this visit.
  }
  reloadAtSamePlace();
}

/** The compressed copy of a library song's address (`/files/…`); others are left as they are. */
function compressedAddress(file: string): string {
  try {
    const url = new URL(file, location.href);
    if (!url.pathname.startsWith("/files/")) return file;
    const address = new URL("/api/compressed", url.origin);
    address.searchParams.set("path", decodeURIComponent(url.pathname.slice("/files/".length)));
    const key = url.searchParams.get("key");
    if (key) address.searchParams.set("key", key);
    return address.toString();
  } catch {
    return file;
  }
}

function address(item: QueueItem): string {
  return compressed() ? compressedAddress(item.file) : item.file;
}

function reloadAtSamePlace() {
  const item = current();
  if (!item || audio.src === new URL(address(item), location.href).toString()) return;
  const at = audio.currentTime;
  const wasPlaying = !audio.paused;
  audio.src = address(item);
  audio.addEventListener("loadedmetadata", () => (audio.currentTime = at), { once: true });
  if (wasPlaying) void audio.play();
}

// Stalls: waiting for data after a song has started. Two within a minute, or one longer than
// five seconds, and the rest plays compressed.
let started = false;
let waitingSince = 0;
let stalls: number[] = [];
audio.addEventListener("waiting", () => {
  if (started) waitingSince = Date.now();
});
audio.addEventListener("playing", () => {
  if (!started) {
    started = true;
    return;
  }
  if (!waitingSince) return;
  const waited = Date.now() - waitingSince;
  waitingSince = 0;
  if (waited < 1000 || compressed()) return;
  const now = Date.now();
  stalls = [...stalls.filter((at) => now - at < 60_000), now];
  if (stalls.length >= 2 || waited > 5000) {
    setCompressedSignal(true);
    setCompressedForSpeed(true);
    reloadAtSamePlace();
  }
});

audio.addEventListener("play", () => setPlaying(true));
audio.addEventListener("pause", () => setPlaying(false));
audio.addEventListener("timeupdate", () => setTime(audio.currentTime));
audio.addEventListener("durationchange", () => setLength(isFinite(audio.duration) ? audio.duration : 0));
audio.addEventListener("ended", () => next());

/** `at`: where in the song to start; `autoplay` false leaves it paused there. */
function load(i: number, { at = 0, autoplay = true }: { at?: number; autoplay?: boolean } = {}) {
  const item = queue()[i];
  if (!item) return;
  setIndex(i);
  started = false;
  waitingSince = 0;
  audio.src = address(item);
  if (at > 0) audio.addEventListener("loadedmetadata", () => (audio.currentTime = at), { once: true });
  // Browsers refuse sound that starts without a click (after a reload, say): then it waits, paused.
  if (autoplay) void audio.play().catch(() => setPlaying(false));
  save();
  // The next song's compressed copy is made while this one plays.
  const following = queue()[i + 1];
  if (compressed() && following) void fetch(compressedAddress(following.file), { headers: { Range: "bytes=0-0" } }).catch(() => {});
  if ("mediaSession" in navigator) {
    navigator.mediaSession.metadata = new MediaMetadata({
      title: item.title,
      artist: item.artist,
      album: item.album,
      artwork: item.artwork ? [{ src: item.artwork }] : [],
    });
  }
}

// What's playing, kept so a reload carries on from the same place in the same song.
const STATE = "seek.playing";
let lastSaved = 0;
function save() {
  lastSaved = Date.now();
  try {
    if (!queue().length) localStorage.removeItem(STATE);
    else localStorage.setItem(STATE, JSON.stringify({ queue: queue(), index: index(), time: audio.currentTime, playing: !audio.paused }));
  } catch {
    // Storage off: a reload starts afresh.
  }
}
audio.addEventListener("timeupdate", () => Date.now() - lastSaved > 2000 && save());
audio.addEventListener("play", save);
audio.addEventListener("pause", () => {
  // A page being closed pauses its audio first: that pause isn't the listener's.
  if (document.visibilityState !== "hidden") save();
});
window.addEventListener("pagehide", save);

(() => {
  let state: { queue: QueueItem[]; index: number; time: number; playing: boolean } | undefined;
  try {
    state = JSON.parse(localStorage.getItem(STATE) ?? "null") ?? undefined;
  } catch {
    state = undefined;
  }
  if (!state?.queue?.length || !state.queue[state.index]) return;
  setQueue(state.queue);
  load(state.index, { at: state.time, autoplay: state.playing });
})();

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

const savedVolume = (() => {
  try {
    return Number(localStorage.getItem("seek.volume") ?? "1");
  } catch {
    return 1;
  }
})();
const [volume, setVolumeSignal] = createSignal(Number.isFinite(savedVolume) ? Math.min(Math.max(savedVolume, 0), 1) : 1);
audio.volume = volume();

export function setVolume(value: number) {
  const clamped = Math.min(Math.max(value, 0), 1);
  setVolumeSignal(clamped);
  audio.volume = clamped;
  try {
    localStorage.setItem("seek.volume", String(clamped));
  } catch {
    // Kept for this visit only.
  }
}

/** Whether there's a song before or after this one, for the player's buttons. */
export const hasNext = () => index() + 1 < queue().length;

export const current = () => queue()[index()];
export { playing, time, length, compressed, compressedForSpeed, volume, queue, index };

if ("mediaSession" in navigator) {
  navigator.mediaSession.setActionHandler("play", () => void audio.play());
  navigator.mediaSession.setActionHandler("pause", () => audio.pause());
  navigator.mediaSession.setActionHandler("nexttrack", next);
  navigator.mediaSession.setActionHandler("previoustrack", previous);
}
