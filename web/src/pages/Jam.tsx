import { A } from "@solidjs/router";
import { createSignal, For, Show } from "solid-js";
import { api, guestID, isGuest, leaveJam, type JamItem, type JamPage } from "../api";
import { duration } from "../format";
import { Cover } from "../Cover";
import { Icon } from "../Icons";
import { ended, tell, useJam, usePosition } from "../jam";

/**
 * A Jam: what's playing on the host's speaker, the controls (when the host allows them), and the
 * queue with who added each song. Guests join here with their name first; the host sees the
 * link to share, whether guests can control playback, and ending it.
 */
export function Jam() {
  const [page, { mutate, refetch }] = useJam();
  const position = usePosition(() => page());
  const [name, setName] = createSignal("");
  const [joining, setJoining] = createSignal(false);

  const join = async (e: SubmitEvent) => {
    e.preventDefault();
    setJoining(true);
    try {
      await api.joinJam(name().trim());
      await refetch();
    } finally {
      setJoining(false);
    }
  };

  const act = async (change: () => Promise<JamPage>) => {
    try {
      mutate(await change());
    } catch (error) {
      tell(error instanceof Error && error.message.includes("403") ? "The host hasn't allowed that." : "That didn't work. Try again.");
    }
  };

  const copy = async (link: string) => {
    try {
      await navigator.clipboard.writeText(link);
      tell("Link copied");
    } catch {
      tell(link);
    }
  };

  const row = (item: JamItem, jam: JamPage, removable: boolean) => (
    <li class="jam-row">
      <Cover class="jam-row-art" src={item.cover} lazy />
      <span class="jam-row-text">
        <span class="row-title">{item.title}</span>
        <span class="row-sub">{item.artist} · added by {item.mine ? "you" : item.addedBy}</span>
      </span>
      <span class="song-duration">{duration(item.duration)}</span>
      <Show when={removable && (item.mine || jam.isHost)}>
        <button class="jam-remove" aria-label={`Remove ${item.title}`} title="Remove" onClick={() => act(() => api.removeFromJam(item.id))}>×</button>
      </Show>
    </li>
  );

  return (
    <section class="jam">
      <div class="page-head"><h1>Jam</h1></div>
      <Show when={!ended()} fallback={
        <div class="jam-ended">
          <p>{isGuest ? "This Jam has ended." : "No Jam is on. Start one from Seek on your iPhone, iPad or Mac."}</p>
          <Show when={isGuest}><button class="pill play" onClick={leaveJam}>OK</button></Show>
        </div>
      }>
        <Show when={page()} fallback={<p class="empty">Loading…</p>}>
          {(jam) => (
            <Show when={!isGuest || guestID()} fallback={
              <form class="jam-join" onSubmit={join}>
                <p>{jam().people[0]} invited you to listen together. Add songs to the queue from their library or Soulseek.</p>
                <input placeholder="Your name" value={name()} maxLength={40} autofocus onInput={(e) => setName(e.currentTarget.value)} />
                <button class="pill play" disabled={joining()}>Join</button>
              </form>
            }>
              <div class="jam-now">
                <Show when={jam().nowPlaying} fallback={<p class="empty">Nothing's playing yet. Add a song to start.</p>}>
                  {(song) => (
                    <>
                      <Cover class="jam-art" src={song().cover} />
                      <div class="jam-now-info">
                        <p class="jam-title">{song().title}</p>
                        <p class="jam-artist">{song().artist} · {song().album}</p>
                        <p class="row-sub">Added by {song().mine ? "you" : song().addedBy}</p>
                        <div class="jam-progress">
                          <span>{duration(position())}</span>
                          <progress value={position()} max={song().duration || 1} />
                          <span>{duration(song().duration)}</span>
                        </div>
                        <Show when={jam().canControl} fallback={<p class="row-sub">The host controls playback.</p>}>
                          <div class="jam-controls">
                            <button aria-label="Previous" onClick={() => act(() => api.controlJam("previous"))}><Icon name="previous" size={24} /></button>
                            <button class="jam-play" aria-label={jam().playing ? "Pause" : "Play"}
                                    onClick={() => act(() => api.controlJam(jam().playing ? "pause" : "play"))}>
                              <Icon name={jam().playing ? "pause" : "play"} size={30} />
                            </button>
                            <button aria-label="Next" onClick={() => act(() => api.controlJam("next"))}><Icon name="next" size={24} /></button>
                          </div>
                        </Show>
                      </div>
                    </>
                  )}
                </Show>
              </div>

              <p class="jam-add">
                <Icon name="plus" size={16} /> Add songs from <A href="/albums">Albums</A>, <A href="/artists">Artists</A> or <A href="/search">Search</A>: pick a song on an album.
              </p>

              <h2>Up Next</h2>
              <Show when={jam().upNext.length} fallback={<p class="empty">Nothing queued.</p>}>
                <ol class="jam-list"><For each={jam().upNext}>{(item) => row(item, jam(), true)}</For></ol>
              </Show>

              <Show when={jam().isHost}>
                <h2>Guests</h2>
                <div class="jam-host">
                  <Show when={jam().link}>
                    {(link) => <button class="pill" onClick={() => copy(link())}>Copy Link to Join</button>}
                  </Show>
                  <label class="setting">
                    <input type="checkbox" checked={jam().guestsCanControl} onChange={(e) => act(() => api.jamSettings(e.currentTarget.checked))} />
                    Guests can play, pause and skip
                  </label>
                  <button class="pill danger" onClick={async () => { await api.endJam(); await refetch(); }}>End Jam</button>
                </div>
              </Show>
              <p class="row-sub jam-people">In the Jam: {jam().people.join(", ")}</p>

              <Show when={jam().played.length}>
                <h2>Played</h2>
                <ol class="jam-list played"><For each={[...jam().played].reverse()}>{(item) => row(item, jam(), false)}</For></ol>
              </Show>

              <Show when={isGuest}><button class="link jam-leave" onClick={leaveJam}>Leave the Jam</button></Show>
            </Show>
          )}
        </Show>
      </Show>
    </section>
  );
}
