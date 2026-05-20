<script setup lang="ts">
import { RefreshCw, Search } from "lucide-vue-next";
import { computed, onMounted, ref } from "vue";

import { marketplaceApi } from "@/api/marketplace";
import { sourceLabel } from "@/lib/format";
import type { MarketplaceListData, MarketplacePlugin } from "@/types/marketplace";

const data = ref<MarketplaceListData | null>(null);
const loading = ref(false);
const error = ref("");
const query = ref("");

const plugins = computed<MarketplacePlugin[]>(() => data.value?.plugins ?? []);
const filteredPlugins = computed(() => {
  const needle = query.value.trim().toLowerCase();
  if (!needle) {
    return plugins.value;
  }
  return plugins.value.filter((plugin) => {
    const text = [
      plugin.name,
      plugin.description ?? "",
      plugin.version ?? "",
      plugin.category ?? "",
      ...(plugin.keywords ?? [])
    ]
      .join(" ")
      .toLowerCase();
    return text.includes(needle);
  });
});

async function load(): Promise<void> {
  loading.value = true;
  error.value = "";
  try {
    data.value = await marketplaceApi.list();
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
    <div class="section-toolbar">
      <div class="search-box">
        <Search :size="18" />
        <input v-model="query" type="search" placeholder="搜索插件、版本、分类" />
      </div>
      <button class="icon-button" type="button" :disabled="loading" title="刷新" @click="load">
        <RefreshCw :size="18" />
      </button>
    </div>

    <p v-if="error" class="error-text">{{ error }}</p>

    <div class="plugin-grid">
      <RouterLink
        v-for="plugin in filteredPlugins"
        :key="plugin.name"
        class="plugin-card"
        :to="`/plugins/${encodeURIComponent(plugin.name)}`"
      >
        <div class="plugin-card-head">
          <strong>{{ plugin.name }}</strong>
          <span>{{ plugin.version ?? "unversioned" }}</span>
        </div>
        <p>{{ plugin.description ?? "No description" }}</p>
        <dl>
          <dt>Source</dt>
          <dd>{{ sourceLabel(plugin.source) }}</dd>
          <dt>License</dt>
          <dd>{{ plugin.license ?? "未声明" }}</dd>
        </dl>
      </RouterLink>
    </div>

    <div v-if="!loading && !error && filteredPlugins.length === 0" class="empty-state">
      <strong>没有匹配的插件</strong>
      <span>当前 marketplace 返回空列表，或搜索条件过窄。</span>
    </div>
  </section>
</template>
