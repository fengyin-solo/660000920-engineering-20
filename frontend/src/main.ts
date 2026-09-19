import { createApp } from 'vue'
import { createPinia } from 'pinia'
import App from './App.vue'
import 'leaflet/dist/leaflet.css'
import { persistencePlugin } from './plugins/persistence'

const pinia = createPinia()
pinia.use(persistencePlugin)

createApp(App).use(pinia).mount('#app')
