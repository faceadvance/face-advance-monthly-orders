import { defineConfig } from "vite";
import { execSync } from "node:child_process";

// เวอร์ชั่นแอป = git commit hash ตอน build (ตรงกับ hash ใน CHANGELOG → ดีบักง่าย)
// dev/ไม่มี git → ใช้ "dev" (ตอน dev จะไม่เจอ mismatch เพราะฝั่ง server ก็คืนค่าเดียวกัน)
const APP_VER = (() => {
  try { return execSync("git rev-parse --short HEAD", { stdio: ["ignore", "pipe", "ignore"] }).toString().trim() || "dev"; }
  catch { return "dev"; }
})();

// base "" = relative paths → deploy บน GitHub Pages ทีหลังได้เลย
export default defineConfig({
  base: "",
  define: { __APP_VERSION__: JSON.stringify(APP_VER) },
  plugins: [
    {
      name: "fa-version-json",
      // build: เขียน dist/version.json (ไฟล์จิ๋ว ~20 bytes) ให้ client มาเทียบเวอร์ชั่น
      generateBundle() {
        this.emitFile({ type: "asset", fileName: "version.json", source: JSON.stringify({ v: APP_VER }) });
      },
      // dev: เสิร์ฟ /version.json ให้เหมือน prod (เทสได้ตั้งแต่ local)
      configureServer(server) {
        server.middlewares.use("/version.json", (_req, res) => {
          res.setHeader("Content-Type", "application/json");
          res.setHeader("Cache-Control", "no-store");
          res.end(JSON.stringify({ v: APP_VER }));
        });
      },
    },
  ],
  server: {
    host: "127.0.0.1",
    port: 5173,
  },
});
