import { fileURLToPath, URL } from "node:url";

import vue from "@vitejs/plugin-vue";
import { defineConfig } from "vite";

const apiTarget = process.env.BIFROST_PANEL_API_TARGET ?? "http://127.0.0.1:8000";

export default defineConfig({
  plugins: [vue()],
  resolve: {
    alias: {
      "@": fileURLToPath(new URL("./src", import.meta.url))
    }
  },
  build: {
    outDir: "dist",
    sourcemap: true,
    rollupOptions: {
      output: {
        manualChunks: {
          vue: ["vue", "vue-router", "pinia"],
          icons: ["lucide-vue-next"]
        }
      }
    }
  },
  server: {
    proxy: {
      "/api": {
        target: apiTarget,
        changeOrigin: true
      },
      "/marketplace": {
        target: apiTarget,
        changeOrigin: true
      }
    }
  },
  test: {
    environment: "node",
    include: ["src/**/*.test.ts"]
  }
});
