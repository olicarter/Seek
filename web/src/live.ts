import { createResource, type ResourceOptions, type ResourceSource, type Setter } from "solid-js";
import { createStore, reconcile } from "solid-js/store";

/**
 * Pages seen before, kept in the browser (memory, and storage so a reload has them too): shown
 * at once when they're opened again while the server's fresh copy loads.
 */
const remembered = new Map<string, unknown>();
const STORE = "seek.pages";
const LIMIT = 150;

function loadStored(): [string, unknown][] {
  try {
    return JSON.parse(localStorage.getItem(STORE) ?? "[]");
  } catch {
    return [];
  }
}
for (const [key, value] of loadStored()) remembered.set(key, value);

let saveQueued = false;
function remember(key: string, value: unknown) {
  remembered.delete(key);
  remembered.set(key, value);
  while (remembered.size > LIMIT) remembered.delete(remembered.keys().next().value!);
  // Written once things settle, not for every page as it arrives.
  if (saveQueued) return;
  saveQueued = true;
  setTimeout(() => {
    saveQueued = false;
    try {
      localStorage.setItem(STORE, JSON.stringify([...remembered]));
    } catch {
      // Storage full or off: kept in memory for this visit.
    }
  }, 1000);
}

/**
 * A page from the server, fetched again whenever `source` changes, merged into what's shown
 * (by `id` where there is one) rather than replacing it: rows that didn't change aren't redrawn,
 * so a click mid-refresh still lands. When the server can't be reached, the last answer stays
 * (the banner at the top says why); it's never an error a page has to handle.
 *
 * `cache`: names the page for `source`, to keep it and show it straight away next time.
 */
export function live<S, T>(source: ResourceSource<S>, fetch: (source: S) => Promise<T>, cache?: (source: S) => string) {
  const storage: ResourceOptions<T, S>["storage"] = (initial) => {
    const [store, setStore] = createStore<{ value: T | undefined }>({ value: initial });
    const set = ((value: unknown) => {
      const next = typeof value === "function" ? (value as (prev: T | undefined) => T)(store.value) : (value as T);
      setStore("value", reconcile(next, { key: "id", merge: true }));
      return store.value;
    }) as Setter<T | undefined>;
    return [() => store.value, set];
  };
  let last: T | undefined;
  let latest = 0;
  let mutate: Setter<T | undefined> | undefined;
  const fetchKeepingLast = (s: S): T | Promise<T> => {
    const key = cache?.(s);
    const asked = ++latest;
    const fresh = fetch(s).then(
      (value) => {
        if (key) remember(key, value);
        if (asked === latest) last = value;
        return value;
      },
      () => last as T,
    );
    const known = key !== undefined ? (remembered.get(key) as T | undefined) : undefined;
    if (known === undefined) return fresh;
    // The kept copy now; the fresh one over it when it comes, unless another page was opened since.
    void fresh.then((value) => asked === latest && value !== undefined && mutate?.(() => value));
    last = known;
    return known;
  };
  const resource = createResource(source, fetchKeepingLast, { storage });
  mutate = resource[1].mutate;
  return resource;
}
