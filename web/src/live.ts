import { createResource, type ResourceOptions, type ResourceSource, type Setter } from "solid-js";
import { createStore, reconcile } from "solid-js/store";

/**
 * A page from the server, fetched again whenever `source` changes, merged into what's shown
 * (by `id` where there is one) rather than replacing it: rows that didn't change aren't redrawn,
 * so a click mid-refresh still lands.
 */
export function live<S, T>(source: ResourceSource<S>, fetch: (source: S) => Promise<T>) {
  const storage: ResourceOptions<T, S>["storage"] = (initial) => {
    const [store, setStore] = createStore<{ value: T | undefined }>({ value: initial });
    const set = ((value: unknown) => {
      const next = typeof value === "function" ? (value as (prev: T | undefined) => T)(store.value) : (value as T);
      setStore("value", reconcile(next, { key: "id", merge: true }));
      return store.value;
    }) as Setter<T | undefined>;
    return [() => store.value, set];
  };
  return createResource(source, fetch, { storage });
}
