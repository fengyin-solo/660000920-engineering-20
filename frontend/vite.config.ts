import { defineConfig } from 'vite'
import vue from '@vitejs/plugin-vue'

const backendPort = process.env.BACKEND_PORT || '8080'
const frontendPort = Number(process.env.FRONTEND_PORT || 5173)

export default defineConfig({
  plugins: [vue()],
  server: {
    port: frontendPort,
    strictPort: true,
    proxy: { '/api': `http://localhost:${backendPort}` },
  },
})
