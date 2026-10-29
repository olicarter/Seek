import { Show } from "solid-js";
import type { SoundQuality } from "./api";

/** TIDAL's tier as a capsule ("MAX"), holding its detail too when given ("MAX 24-bit, 96 kHz"). */
export function Quality(props: { quality?: SoundQuality; detail?: string }) {
  return (
    <Show when={props.quality}>
      <span class={`quality ${props.quality}`}>
        <b>{props.quality!.toUpperCase()}</b>
        <Show when={props.detail}><span class="quality-detail">{props.detail}</span></Show>
      </span>
    </Show>
  );
}
