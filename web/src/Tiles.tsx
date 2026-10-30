import { A } from "@solidjs/router";
import { For, type JSX, Show } from "solid-js";
import { Cover } from "./Cover";
import { Icon } from "./Icons";

export type TileItem = {
  href: string; title: string; subtitle?: string; artwork?: string; preview?: string; badges?: JSX.Element;
  /** Marked on the cover, as on artist pages. */
  inLibrary?: boolean;
};

/** An album as a cover with its name under it, as in Apple Music's grids and shelves. */
export function Tile(props: { item: TileItem; round?: boolean }) {
  return (
    <A class="tile" classList={{ round: props.round }} href={props.item.href}>
      <div class="tile-cover">
        <Cover src={props.item.artwork} preview={props.item.preview} lazy />
        <Show when={props.item.inLibrary}>
          <span class="in-library" title="In Library" aria-label="In Library">
            <Icon name="check" size={13} />
          </span>
        </Show>
      </div>
      <div class="tile-title">{props.item.title}</div>
      <Show when={props.item.subtitle}><div class="tile-sub">{props.item.subtitle}</div></Show>
      <Show when={props.item.badges}><div class="tile-badges">{props.item.badges}</div></Show>
    </A>
  );
}

/** Covers filling the width, as many to a row as fit. */
export function Grid(props: { items: TileItem[]; round?: boolean }) {
  return (
    <div class="grid">
      <For each={props.items}>{(item) => <Tile item={item} round={props.round} />}</For>
    </div>
  );
}

/** A row of covers that scrolls sideways ("More by …"). */
export function Shelf(props: { title: string; items: TileItem[] }) {
  return (
    <Show when={props.items.length}>
      <section class="shelf">
        <h2>{props.title}</h2>
        <div class="shelf-row">
          <For each={props.items}>{(item) => <Tile item={item} />}</For>
        </div>
      </section>
    </Show>
  );
}
