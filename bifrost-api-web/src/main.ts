import { createPinia } from "pinia";
import { createApp } from "vue";

import App from "./App.vue";
import { configureUnauthorizedHandler } from "./api/marketplace";
import { router } from "./router";
import "./styles.css";

const app = createApp(App);

app.use(createPinia());
app.use(router);

configureUnauthorizedHandler(() => {
  const current = router.currentRoute.value;
  if (current.path !== "/login") {
    void router.push({ path: "/login", query: { next: current.fullPath } });
  }
});

app.mount("#app");
