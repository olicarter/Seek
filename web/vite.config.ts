import { defineConfig } from "vite";
import solid from "vite-plugin-solid";

// In development the site runs here and the server (seek-server) answers /api and /files.
// SEEK_BASE: where the site lives, e.g. /seek/web/ on 4n.studio.
export default defineConfig({
  base: process.env.SEEK_BASE ?? "/",
  plugins: [solid()],
  server: {
    proxy: {
      "/api": "http://localhost:8765",
      "/files": "http://localhost:8765",
    },
  },
});
