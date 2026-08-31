import { defineConfig } from "vite";

// base "" = relative paths → deploy บน GitHub Pages ทีหลังได้เลย
export default defineConfig({
  base: "",
  server: {
    host: "127.0.0.1",
    port: 5173,
  },
});
