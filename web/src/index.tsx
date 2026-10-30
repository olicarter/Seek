import { render } from "solid-js/web";
import { Navigate, Route, Router, useSearchParams } from "@solidjs/router";
import { albumHref, artistHref } from "./api";
import { App } from "./App";
import { Library } from "./pages/Library";
import { Search } from "./pages/Search";
import { Album } from "./pages/Album";
import { Artist } from "./pages/Artist";
import { Artists } from "./pages/Artists";
import { Downloads } from "./pages/Downloads";
import { Settings } from "./pages/Settings";
import { TV } from "./pages/TV";
import "./styles.css";

function OldAlbumLink() {
  const [params] = useSearchParams<{ artist?: string; title?: string; release?: string }>();
  return <Navigate href={albumHref({ artist: params.artist ?? "", title: params.title ?? "", release: params.release })} />;
}

function OldArtistLink() {
  const [params] = useSearchParams<{ name?: string }>();
  return <Navigate href={artistHref(params.name ?? "")} />;
}

render(
  () => (
    <Router root={App} base={import.meta.env.BASE_URL.replace(/\/$/, "")}>
      <Route path="/" component={() => <Navigate href="/albums" />} />
      <Route path="/albums" component={Library} />
      <Route path="/artists" component={Artists} />
      <Route path="/artists/:artist" component={Artist} />
      <Route path="/artists/:artist/albums/:title" component={Album} />
      <Route path="/search" component={Search} />
      <Route path="/downloads" component={Downloads} />
      <Route path="/settings" component={Settings} />
      <Route path="/tv" component={TV} />
      {/* Links from before (?artist=…&title=…), forwarded. */}
      <Route path="/album" component={OldAlbumLink} />
      <Route path="/artist" component={OldArtistLink} />
    </Router>
  ),
  document.getElementById("root")!,
);
