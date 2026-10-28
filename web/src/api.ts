import { createSignal } from "solid-js";

// The server's pages (Server/Pages.swift), as JSON.

export type Status = {
  soulseek: string;
  username?: string;
  signedIn: boolean;
  downloading: number;
  failure?: string;
};

export type Release = {
  id: string;
  artist: string;
  title: string;
  year?: number;
  kind?: string;
  artwork?: string;
  copies: number;
  lossless: boolean;
  bandcamp: boolean;
  inLibrary: boolean;
  adding: boolean;
};

export type SearchPage = { query: string; searching: boolean; releases: Release[] };

export type Song = {
  kind: "have" | "missing" | "arriving";
  number?: number;
  disc: number;
  title: string;
  artist?: string;
  duration?: number;
  file?: string;
  available: boolean;
  progress?: number;
  lossless?: boolean;
};

export type AlbumPage = {
  artist: string;
  title: string;
  year?: number;
  artwork?: string;
  songs: Song[];
  footer: string;
  listed: boolean;
  inLibrary: boolean;
  canAdd: boolean;
  adding: boolean;
  lookingForCopies: boolean;
  copies: number;
};

export type LibraryAlbum = { artist: string; title: string; year?: number; artwork: string; songs: number };

export type Download = {
  id: string;
  name: string;
  album: string;
  user: string;
  state: string;
  active: boolean;
  progress: number;
  speed: number;
};

/** Which album page to open: by name, and the search result it came from, if any. */
export type AlbumRef = { artist: string; title: string; release?: string };

async function get<T>(path: string): Promise<T> {
  const response = await fetch(path);
  if (!response.ok) throw new Error(`${path}: ${response.status}`);
  return response.json();
}

async function post<T>(path: string, body?: unknown): Promise<T> {
  const response = await fetch(path, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: body === undefined ? undefined : JSON.stringify(body),
  });
  if (!response.ok) throw new Error(`${path}: ${response.status}`);
  return response.json();
}

function albumQuery(ref: AlbumRef): string {
  const params = new URLSearchParams({ artist: ref.artist, title: ref.title });
  if (ref.release) params.set("release", ref.release);
  return params.toString();
}

export const api = {
  status: () => get<Status>("/api/status"),
  login: (username: string, password: string) => post<Status>("/api/login", { username, password }),
  logout: () => post<Status>("/api/logout"),
  search: (query: string) => post<SearchPage>("/api/search", { query }),
  searchPage: () => get<SearchPage>("/api/search"),
  album: (ref: AlbumRef) => get<AlbumPage>(`/api/album?${albumQuery(ref)}`),
  add: (ref: AlbumRef) => post<AlbumPage>("/api/album/add", ref),
  library: () => get<LibraryAlbum[]>("/api/library"),
  downloads: () => get<Download[]>("/api/downloads"),
  takeFailure: () => post<{ message?: string }>("/api/failure/take"),
};

export function albumHref(ref: AlbumRef): string {
  return `/album?${albumQuery(ref)}`;
}

/**
 * Bumped whenever the server says something shown may have changed: pages refetch on it.
 * At most every half second, so a busy search or download doesn't refetch constantly.
 */
const [changes, setChanges] = createSignal(0);
export { changes };

let pending: number | undefined;
function connect() {
  const events = new EventSource("/api/events");
  events.onmessage = () => {
    if (pending !== undefined) return;
    pending = window.setTimeout(() => {
      pending = undefined;
      setChanges((n) => n + 1);
    }, 500);
  };
  events.onerror = () => {
    events.close();
    window.setTimeout(connect, 2000);
  };
}
connect();
