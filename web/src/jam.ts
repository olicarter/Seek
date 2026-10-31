import { createResource, createRoot, createSignal, onCleanup } from "solid-js";
import { api, changes, isGuest, JamEnded, type JamPage } from "./api";

/** The Jam, refetched whenever the server says something changed (and so shared by every part showing it). */
const [ended, setEnded] = createSignal(false);
export { ended };

let resource: ReturnType<typeof createResource<JamPage | undefined, number>> | undefined;

export function useJam() {
  if (!resource) {
    // Its own root: it outlives whichever part of the page first asked for it.
    resource = createRoot(() => createResource(changes, async () => {
      try {
        const page = await api.jam();
        setEnded(false);
        return page;
      } catch (error) {
        // Ended (or none): for a guest that's the end of it; the owner just sees none.
        if (error instanceof JamEnded || !isGuest) setEnded(true);
        return undefined;
      }
    }));
  }
  return resource;
}

/** Where the song playing is, moving on each second while it plays (from the speaker's last report). */
export function usePosition(page: () => JamPage | undefined) {
  const [now, setNow] = createSignal(Date.now());
  const timer = window.setInterval(() => setNow(Date.now()), 1000);
  onCleanup(() => window.clearInterval(timer));
  let fetchedAt = Date.now();
  let lastPage: JamPage | undefined;
  return () => {
    const jam = page();
    if (jam !== lastPage) {
      lastPage = jam;
      fetchedAt = Date.now();
    }
    if (!jam?.nowPlaying) return 0;
    const at = jam.position + (jam.playing ? (now() - fetchedAt) / 1000 : 0);
    return Math.min(at, jam.nowPlaying.duration || at);
  };
}

/** Says something for a moment ("Added …"). */
const [notice, setNotice] = createSignal<string>();
export { notice };
let hiding: number | undefined;
export function tell(message: string) {
  setNotice(message);
  window.clearTimeout(hiding);
  hiding = window.setTimeout(() => setNotice(), 2500);
}
