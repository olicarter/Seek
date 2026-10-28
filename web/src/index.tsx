import { render } from "solid-js/web";
import { Route, Router } from "@solidjs/router";
import { App } from "./App";
import { Library } from "./pages/Library";
import { Search } from "./pages/Search";
import { Album } from "./pages/Album";
import { Artist } from "./pages/Artist";
import { Downloads } from "./pages/Downloads";
import { Settings } from "./pages/Settings";
import "./styles.css";

render(
  () => (
    <Router root={App}>
      <Route path="/" component={Library} />
      <Route path="/search" component={Search} />
      <Route path="/album" component={Album} />
      <Route path="/artist" component={Artist} />
      <Route path="/downloads" component={Downloads} />
      <Route path="/settings" component={Settings} />
    </Router>
  ),
  document.getElementById("root")!,
);
