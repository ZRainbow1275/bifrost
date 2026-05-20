<script setup lang="ts">
import { computed, onMounted, ref } from "vue";
import { useRoute } from "vue-router";

import { marketplaceApi } from "@/api/marketplace";
import { sourceLabel } from "@/lib/format";
import type { MarketplacePlugin } from "@/types/marketplace";

const route = useRoute();
const plugin = ref<MarketplacePlugin | null>(null);
const loading = ref(false);
const error = ref("");

const pluginName = computed(() => String(route.params.name ?? ""));

async function load(): Promise<void> {
  loading.value = true;
  error.value = "";
  try {
    const data = await marketplaceApi.list();
    plugin.value = data.plugins.find((candidate) => candidate.name === pluginName.value) ?? null;
  } catch (err) {
    error.value = err instanceof Error ? err.message : "加载失败";
  } finally {
    loading.value = false;
  }
}

onMounted(() => {
  void load();
});
</script>

<template>
  <section class="content-section">
    <RouterLink class="text-link" to="/plugins">返回插件列表</RouterLink>
    <p v-if="error" class="error-text">{{ error }}</p>
    <div v-if="plugin" class="detail-layout">
      <div>
        <p class="eyebrow">Plugin</p>
        <h2>{{ plugin.name }}</h2>
        <p class="muted">{{ plugin.description ?? "No description" }}</p>
      </div>
      <dl class="detail-list">
        <dt>Version</dt>
        <dd>{{ plugin.version ?? "unversioned" }}</dd>
        <dt>Source</dt>
        <dd>{{ sourceLabel(plugin.source) }}</dd>
        <dt>Category</dt>
        <dd>{{ plugin.category ?? "未分类" }}</dd>
        <dt>License</dt>
        <dd>{{ plugin.license ?? "未声明" }}</dd>
      </dl>
    </div>
    <div v-else-if="!loading" class="empty-state">
      <strong>插件不存在</strong>
      <span>{{ pluginName }} 不在当前 marketplace.json 中。</span>
    </div>
  </section>
</template>
