import { createRouter, createWebHistory, type RouteLocationNormalized } from "vue-router";

import Browse from "./views/Browse.vue";
import Curate from "./views/Curate.vue";
import Login from "./views/Login.vue";
import PluginDetail from "./views/PluginDetail.vue";
import Status from "./views/Status.vue";
import Upload from "./views/Upload.vue";
import { useSessionStore } from "./stores/session";

const routes = [
  { path: "/login", component: Login },
  { path: "/plugins", component: Browse, meta: { requiresAdmin: true } },
  { path: "/plugins/:name", component: PluginDetail, meta: { requiresAdmin: true } },
  { path: "/upload", component: Upload, meta: { requiresAdmin: true } },
  { path: "/curate", component: Curate, meta: { requiresAdmin: true } },
  { path: "/status", component: Status, meta: { requiresAdmin: true } },
  { path: "/:pathMatch(.*)*", redirect: "/plugins" }
] as const;

export const router = createRouter({
  history: createWebHistory(),
  routes: [...routes]
});

router.beforeEach((to: RouteLocationNormalized) => {
  const session = useSessionStore();
  if (to.meta.requiresAdmin === true && !session.hasKey) {
    return { path: "/login", query: { next: to.fullPath } };
  }
  if (to.path === "/login" && session.hasKey) {
    return { path: "/plugins" };
  }
  return true;
});
