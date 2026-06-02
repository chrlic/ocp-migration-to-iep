import { defineConfig } from 'vite'
import vue from '@vitejs/plugin-vue'

// In dev, proxy /api to the Go backend (run `go run .` separately or port-forward
// the in-cluster backend to :8080). In prod the Go server serves the built SPA.
export default defineConfig({
  plugins: [vue()],
  server: {
    proxy: {
      '/api': { target: 'http://localhost:8080', changeOrigin: true },
    },
  },
  build: { outDir: 'dist' },
})
