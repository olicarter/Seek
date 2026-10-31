/** The few symbols the site uses, drawn rather than typed, so they look the same everywhere. */
const paths: Record<string, string> = {
  play: "M8 5.5v13a1 1 0 0 0 1.5.86l10.4-6.5a1 1 0 0 0 0-1.72L9.5 4.64A1 1 0 0 0 8 5.5Z",
  pause: "M7 5h3.2v14H7zM13.8 5H17v14h-3.2z",
  next: "M5 6.2v11.6a.8.8 0 0 0 1.2.7L13 14v3.8a.8.8 0 0 0 1.2.7l8-5.8a.8.8 0 0 0 0-1.4l-8-5.8a.8.8 0 0 0-1.2.7V10L6.2 5.5a.8.8 0 0 0-1.2.7Z",
  previous: "M19 6.2v11.6a.8.8 0 0 1-1.2.7L11 14v3.8a.8.8 0 0 1-1.2.7l-8-5.8a.8.8 0 0 1 0-1.4l8-5.8a.8.8 0 0 1 1.2.7V10l6.8-4.5a.8.8 0 0 1 1.2.7Z",
  shuffle: "M3 7h3.5c2 0 3.2 1 4.3 2.6l2.4 4.8C14.3 16 15.5 17 17.5 17H21m0 0-2.5-2.5M21 17l-2.5 2.5M3 17h3.5c1.4 0 2.4-.5 3.2-1.4M21 7h-3.5c-1.4 0-2.4.5-3.2 1.4M21 7l-2.5-2.5M21 7l-2.5 2.5",
  plus: "M12 5v14M5 12h14",
  check: "M5 12.5 10 17.5 19 7",
  search: "M10.5 18a7.5 7.5 0 1 1 5.3-2.2L21 21",
  albums: "M4 4h7v7H4zM13 4h7v7h-7zM4 13h7v7H4zM13 13h7v7h-7z",
  artists: "M12 12a4 4 0 1 0 0-8 4 4 0 0 0 0 8Zm-7.5 8a7.5 7.5 0 0 1 15 0",
  downloads: "M12 4v11m0 0-4.5-4.5M12 15l4.5-4.5M5 19.5h14",
  settings: "M12 15.2a3.2 3.2 0 1 0 0-6.4 3.2 3.2 0 0 0 0 6.4Zm7.4-3.2a7.6 7.6 0 0 0-.1-1.3l2-1.6-2-3.4-2.4 1a7.4 7.4 0 0 0-2.2-1.3L14.4 3h-4l-.3 2.4a7.4 7.4 0 0 0-2.2 1.3l-2.4-1-2 3.4 2 1.6a7.6 7.6 0 0 0 0 2.6l-2 1.6 2 3.4 2.4-1a7.4 7.4 0 0 0 2.2 1.3l.3 2.4h4l.3-2.4a7.4 7.4 0 0 0 2.2-1.3l2.4 1 2-3.4-2-1.6c.1-.4.1-.9.1-1.3Z",
  jam: "M9 11a3.2 3.2 0 1 0 0-6.4A3.2 3.2 0 0 0 9 11Zm-6 8.5a6 6 0 0 1 12 0M16.5 5.5a6 6 0 0 1 0 6M19 3a9.5 9.5 0 0 1 0 11",
  volume: "M4 9.5v5h3.5L12 18.5v-13L7.5 9.5H4Zm11.5-1a4.5 4.5 0 0 1 0 7M18 6a8 8 0 0 1 0 12",
};

const filled = new Set(["play", "pause", "next", "previous"]);

export function Icon(props: { name: keyof typeof paths | string; size?: number }) {
  const solid = filled.has(props.name);
  return (
    <svg width={props.size ?? 20} height={props.size ?? 20} viewBox="0 0 24 24" aria-hidden="true"
         fill={solid ? "currentColor" : "none"} stroke={solid ? "none" : "currentColor"} stroke-width="1.8"
         stroke-linecap="round" stroke-linejoin="round">
      <path d={paths[props.name]} />
    </svg>
  );
}
