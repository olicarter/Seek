import { Show } from "solid-js";
import { media } from "./api";

/**
 * An album cover: its tiny preview (from the page itself) shown pixelated straight away, then
 * the cover over it, which arrives as a progressive JPEG and sharpens as it loads.
 */
export function Cover(props: { src?: string; preview?: string; class?: string; lazy?: boolean }) {
  return (
    <div class={`cover ${props.class ?? ""}`} style={props.preview ? { "background-image": `url(${props.preview})` } : {}}>
      <Show when={props.src}>
        <img src={media(props.src)} alt="" loading={props.lazy ? "lazy" : undefined}
             onError={(e) => e.currentTarget.classList.add("missing")} />
      </Show>
    </div>
  );
}
