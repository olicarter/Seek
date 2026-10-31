import { createSignal } from "solid-js";

// The server's pages (Server/Pages.swift), as JSON.

export type Status = {
  soulseek: string;
  username?: string;
  signedIn: boolean;
  downloading: number;
  failure?: string;
  bandcamp?: string;
};

/** TIDAL's tiers (tidal.com/sound-quality): max is lossless above 16-bit, 44.1 kHz. */
export type SoundQuality = "max" | "high" | "low";

export type Release = {
  id: string;
  artist: string;
  title: string;
  year?: number;
  kind?: string;
  artwork?: string;
  copies: number;
  lossless: boolean;
  quality?: SoundQuality;
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
  quality?: SoundQuality;
  /** "128 · 8A". */
  tempoAndKey?: string;
};

export type AlbumPage = {
  artist: string;
  title: string;
  year?: number;
  artwork?: string;
  preview?: string;
  songs: Song[];
  footer: string;
  /** "2026-07-31" and the ℗ line, when Apple or Bandcamp give them. */
  released?: string;
  copyright?: string;
  /** The page's colour from the cover, "#1e3f6e". */
  tint?: string;
  /** A few sentences about the album, once written. */
  about?: string;
  quality?: SoundQuality;
  /** "24-bit, 96 kHz". */
  qualityDetail?: string;
  listed: boolean;
  inLibrary: boolean;
  canAdd: boolean;
  adding: boolean;
  lookingForCopies: boolean;
  copies: number;
  bandcamp?: { owned: boolean; page?: string; price?: string; downloading?: number };
};

export type ArtistPage = {
  name: string;
  /** A few sentences about them, once written. */
  about?: string;
  albums: LibraryAlbum[];
  sections: {
    title: string;
    /** `inLibrary`: the library's album, under `artist` (its own album artist). */
    releases: { title: string; year: number; artwork?: string; inLibrary?: boolean; artist?: string; preview?: string }[];
  }[];
};

export type LibraryAlbum = { artist: string; title: string; year?: number; artwork: string; preview?: string; songs: number };

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

const SERVER_KEY = "seek.server";
const PAIRING_KEY = "seek.key";

function stored(name: string): string | null {
  try {
    return localStorage.getItem(name);
  } catch {
    return null;
  }
}

// The pairing link (from /pair on the Mac) ends #key=…: kept, then taken out of the address.
const pairing = new URLSearchParams(location.hash.slice(1)).get("key");
if (pairing) {
  try {
    localStorage.setItem(PAIRING_KEY, pairing);
  } catch {
    // Not kept: this page can still use it until it's closed.
  }
  history.replaceState(null, "", location.pathname + location.search);
}
// A Jam's link ends #jam=…: this browser is a guest in it, with only what guests can see.
const JAM_KEY = "seek.jam";
const GUEST_KEY = "seek.guest";
const joining = new URLSearchParams(location.hash.slice(1)).get("jam");
if (joining) {
  try {
    if (joining !== localStorage.getItem(JAM_KEY)) localStorage.removeItem(GUEST_KEY);
    localStorage.setItem(JAM_KEY, joining);
  } catch {
    // Not kept: a guest until the page closes.
  }
  history.replaceState(null, "", location.pathname + location.search);
}
const jamKey = joining ?? stored(JAM_KEY);
/** This browser is a guest in someone's Jam, rather than Seek's owner. */
export const isGuest = jamKey !== null;
let guest = isGuest ? stored(GUEST_KEY) : null;
export const guestID = () => guest;

/** Out of the Jam (it ended, or leaving it): back to Seek as before. */
export function leaveJam() {
  try {
    localStorage.removeItem(JAM_KEY);
    localStorage.removeItem(GUEST_KEY);
  } catch {
    // Nothing kept.
  }
  location.replace(import.meta.env.BASE_URL);
}

const key = jamKey ?? pairing ?? stored(PAIRING_KEY);

/**
 * Keeps what lets this browser in: its session after signing in with a passkey (or nothing,
 * signing out), then reloads so everything asks with it.
 */
export function setCredential(credential: string | null) {
  try {
    if (credential) localStorage.setItem(PAIRING_KEY, credential);
    else localStorage.removeItem(PAIRING_KEY);
  } catch {
    // Not kept: signed in until the page closes.
  }
  location.reload();
}

/** Whether this browser has the server's key (or doesn't need one: the Mac serving the page). */
export const isPaired = () => key !== null || !serverAddress();

/**
 * Where the server on the Mac is. The Mac serves the site itself at its own address; the copy on
 * 4n.studio is built with the Mac's tailnet address, which Settings can change for this browser.
 */
export function serverAddress(): string {
  // Storage can be off (a private window): the built-in address, then.
  return (stored(SERVER_KEY) ?? import.meta.env.VITE_SEEK_SERVER ?? "").replace(/\/$/, "");
}

export function setServerAddress(address: string) {
  try {
    if (address.trim()) localStorage.setItem(SERVER_KEY, address.trim());
    else localStorage.removeItem(SERVER_KEY);
  } catch {
    // Not kept, but used until the page reloads.
  }
  location.reload();
}

/** A path on the server (`/api/…`, `/files/…`) as an address; others (Apple's, Bandcamp's art) as they are. */
export function media(path: string): string;
export function media(path?: string): string | undefined;
export function media(path?: string): string | undefined {
  if (!path?.startsWith("/")) return path;
  // Audio, images and the event stream can't send headers: the key goes in the address.
  const withKey = key ? `${path}${path.includes("?") ? "&" : "?"}key=${encodeURIComponent(key)}` : path;
  return serverAddress() + withKey;
}

/** The server said this browser isn't paired. */
export class NotPaired extends Error {}

function headers(extra: Record<string, string> = {}): Record<string, string> {
  const withKey = key ? { ...extra, "X-Seek-Key": key } : extra;
  return guest ? { ...withKey, "X-Seek-Guest": guest } : withKey;
}

/** The Jam this browser is a guest in has ended. */
export class JamEnded extends Error {}

function check(response: Response, path: string) {
  if (isGuest && (response.status === 401 || (response.status === 404 && path.startsWith("/api/jam")))) throw new JamEnded();
  if (response.status === 401) throw new NotPaired();
  if (!response.ok) throw new Error(`${path}: ${response.status}`);
}

async function get<T>(path: string): Promise<T> {
  const response = await fetch(serverAddress() + path, { headers: headers() });
  check(response, path);
  return response.json();
}

async function post<T>(path: string, body?: unknown): Promise<T> {
  const response = await fetch(serverAddress() + path, {
    method: "POST",
    headers: headers({ "Content-Type": "application/json" }),
    body: body === undefined ? undefined : JSON.stringify(body),
  });
  check(response, path);
  return response.json();
}

function albumQuery(ref: AlbumRef): string {
  const params = new URLSearchParams({ artist: ref.artist, title: ref.title });
  if (ref.release) params.set("release", ref.release);
  // Spaces as %20, not "+": the router reads links back without turning "+" into spaces (a
  // real "+" is already %2B).
  return params.toString().replaceAll("+", "%20");
}

export type JamItem = {
  id: string;
  title: string;
  artist: string;
  album: string;
  albumArtist: string;
  cover?: string;
  duration: number;
  addedBy: string;
  mine: boolean;
};

export type JamPage = {
  me?: string;
  isHost: boolean;
  canControl: boolean;
  guestsCanControl: boolean;
  people: string[];
  nowPlaying?: JamItem;
  playing: boolean;
  finished: boolean;
  position: number;
  upNext: JamItem[];
  played: JamItem[];
  link?: string;
};

export type AuthInfo = { passkeys: boolean; signedIn: boolean; local: boolean };
export type Passkey = { id: string; name: string; created: string; lastUsed?: string };

export const api = {
  auth: () => get<AuthInfo>("/api/auth"),
  passkeys: () => get<Passkey[]>("/api/auth/passkeys"),
  removePasskey: (id: string) => post<{ ok: boolean }>("/api/auth/passkeys/remove", { id }),
  signOut: () => post<{ ok: boolean }>("/api/auth/signout"),
  approveDevice: (code: string) => post<{ name: string }>("/api/auth/device/approve", { code }),
  signOutEverywhere: () => post<{ ok: boolean }>("/api/auth/signout-everywhere"),
  beginSignIn: () => post<{ challenge: string; site: string }>("/api/auth/signin/begin"),
  finishSignIn: (answer: object) => post<{ session: string }>("/api/auth/signin/finish", answer),
  beginRegister: () => post<{ challenge: string; userID: string; site: string }>("/api/auth/register/begin"),
  finishRegister: (answer: object) => post<{ session: string }>("/api/auth/register/finish", answer),
  // Guests don't see the Mac's accounts: Soulseek is just there for them.
  status: () => isGuest ? Promise.resolve<Status>({ soulseek: "", signedIn: true, downloading: 0 }) : get<Status>("/api/status"),
  jam: () => get<JamPage>("/api/jam"),
  joinJam: async (name: string) => {
    const joined = await post<{ guest: string }>("/api/jam/join", { name });
    guest = joined.guest;
    try {
      localStorage.setItem(GUEST_KEY, joined.guest);
    } catch {
      // A guest until the page closes.
    }
    return joined;
  },
  addToJam: (file: string) => post<JamPage>("/api/jam/add", { file }),
  removeFromJam: (id: string) => post<JamPage>("/api/jam/remove", { id }),
  controlJam: (action: "play" | "pause" | "next" | "previous") => post<JamPage>("/api/jam/control", { action }),
  jamSettings: (guestsCanControl: boolean) => post<JamPage>("/api/jam/settings", { guestsCanControl }),
  moveInJam: (id: string, place: number) => post<JamPage>("/api/jam/move", { id, place }),
  endJam: () => post<{ ok: boolean }>("/api/jam/end"),
  search: (query: string) => post<SearchPage>("/api/search", { query }),
  searchPage: () => get<SearchPage>("/api/search"),
  album: (ref: AlbumRef) => get<AlbumPage>(`/api/album?${albumQuery(ref)}`),
  add: (ref: AlbumRef) => post<AlbumPage>("/api/album/add", ref),
  library: () => get<LibraryAlbum[]>("/api/library"),
  downloads: () => get<Download[]>("/api/downloads"),
  takeFailure: () => post<{ message?: string }>("/api/failure/take"),
  artist: (name: string) => get<ArtistPage>(`/api/artist?name=${encodeURIComponent(name)}`),
  buying: () => post<{ ok: boolean }>("/api/bandcamp/buying"),
};

/** A part of the path as written, from the router (which leaves it encoded). */
export function fromPath(part: string | undefined): string {
  try {
    return decodeURIComponent(part ?? "");
  } catch {
    return part ?? "";
  }
}

/** One part of a path: "AC/DC" can't split it. */
const segment = (text: string) => encodeURIComponent(text);

/** `/artists/<artist>/albums/<title>`, and the search result it came from when there is one. */
export function albumHref(ref: AlbumRef): string {
  const path = `/artists/${segment(ref.artist)}/albums/${segment(ref.title)}`;
  return ref.release ? `${path}?release=${encodeURIComponent(ref.release)}` : path;
}

/** `/artists/<name>`. */
export function artistHref(name: string): string {
  return `/artists/${segment(name)}`;
}

/**
 * Bumped whenever the server says something shown may have changed: pages refetch on it.
 * At most every half second, so a busy search or download doesn't refetch constantly.
 */
// From 1: a resource with a falsy source never fetches, so a page would wait for the first event.
const [changes, setChanges] = createSignal(1);
export { changes };

let pending: number | undefined;
function connect() {
  const events = new EventSource(media("/api/events"));
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
