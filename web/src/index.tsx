import { render } from "solid-js/web";
import { Route, Router } from "@solidjs/router";
import { App } from "./App";
import { Library } from "./pages/Library";
import { Search } from "./pages/Search";
import { Album } from "./pages/Album";
import { Artist } from "./pages/Artist";
import { Downloads } from "./pages/Downloads";
import { Settings } from "./pages/Settings";
import { TV } from "./pages/TV";
import "./styles.css";

render(
  () => (
    <Router root={App} base={import.meta.env.BASE_URL.replace(/\/$/, "")}>
      <Route path="/" component={Library} />
      <Route path="/search" component={Search} />
      <Route path="/album" component={Album} />
      <Route path="/artist" component={Artist} />
      <Route path="/downloads" component={Downloads} />
      <Route path="/settings" component={Settings} />
      <Route path="/tv" component={TV} />
    </Router>
  ),
  document.getElementById("root")!,
);
