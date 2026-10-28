import { defineConfig } from "vite";
import solid from "vite-plugin-solid";

// In development the site runs here and the server (seek-server) answers /api and /files.
export default defineConfig({
  plugins: [solid()],
  server: {
    proxy: {
      "/api": "http://localhost:8765",
      "/files": "http://localhost:8765",
    },
  },
});
