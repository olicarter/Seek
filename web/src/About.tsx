import { createSignal, Show } from "solid-js";

/** A few sentences about an album or artist: three lines, then MORE, as in Apple Music. */
export function About(props: { text?: string }) {
  const [open, setOpen] = createSignal(false);
  return (
    <Show when={props.text}>
      <p class="about" classList={{ open: open() }}>
        {props.text}
        <Show when={!open()}>
          <button class="more" onClick={() => setOpen(true)}>MORE</button>
        </Show>
      </p>
    </Show>
  );
}
