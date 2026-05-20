<script setup lang="ts">
import { Box, FileUp, Gauge, Layers, LogOut, Settings2 } from "lucide-vue-next";
import { useRouter } from "vue-router";

import { useSessionStore } from "@/stores/session";

const session = useSessionStore();
const router = useRouter();

function logout(): void {
  session.clear();
  void router.push("/login");
}
</script>

<template>
  <div class="app-shell">
    <aside class="sidebar">
      <div class="brand">
        <div class="brand-mark">B</div>
        <div>
          <strong>Bifrost</strong>
          <span>Marketplace Panel</span>
        </div>
      </div>

      <nav class="nav-list" aria-label="Marketplace navigation">
        <RouterLink to="/plugins">
          <Layers :size="18" />
          <span>插件</span>
        </RouterLink>
        <RouterLink to="/status">
          <Gauge :size="18" />
          <span>状态</span>
        </RouterLink>
        <RouterLink to="/upload">
          <FileUp :size="18" />
          <span>上传</span>
        </RouterLink>
        <RouterLink to="/curate">
          <Settings2 :size="18" />
          <span>治理</span>
        </RouterLink>
      </nav>

      <button v-if="session.hasKey" class="ghost-button sidebar-action" type="button" @click="logout">
        <LogOut :size="17" />
        <span>退出</span>
      </button>
    </aside>

    <main class="main-surface">
      <header class="topbar">
        <div>
          <p class="eyebrow">Internal-only distribution</p>
          <h1>Claude Code 插件分发</h1>
        </div>
        <div class="topbar-status">
          <Box :size="18" />
          <span>{{ session.hasKey ? "Admin session" : "Locked" }}</span>
        </div>
      </header>
      <RouterView />
    </main>
  </div>
</template>
