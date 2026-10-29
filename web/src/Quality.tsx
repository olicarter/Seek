import { Show } from "solid-js";
import type { SoundQuality } from "./api";

/** TIDAL's tier as a badge ("MAX"), with its detail after it when given ("24-bit, 96 kHz"). */
export function Quality(props: { quality?: SoundQuality; detail?: string }) {
  return (
    <Show when={props.quality}>
      <span class="quality-wrap">
        <span class={`quality ${props.quality}`}>{props.quality!.toUpperCase()}</span>
        <Show when={props.detail}><span class="quality-detail">{props.detail}</span></Show>
      </span>
    </Show>
  );
}
