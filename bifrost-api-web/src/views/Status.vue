<script setup lang="ts">
import { RefreshCw } from "lucide-vue-next";
import { computed, onMounted, ref } from "vue";

import { marketplaceApi } from "@/api/marketplace";
import { formatDate, formatMegabytes } from "@/lib/format";
import type { MarketplaceDiskData, MarketplaceStatusData } from "@/types/marketplace";

const status = ref<MarketplaceStatusData | null>(null);
const disk = ref<MarketplaceDiskData | null>(null);
const logs = ref("");
const logService = ref<"render" | "schema-check" | "admin-audit">("render");
const loading = ref(false);
const error = ref("");

const totalDisk = computed(() => {
  if (!disk.value) {
    return 0;
  }
  return (
    disk.value.var_lib_git_mirrors_bifrost_internal_plugins_mb +
    disk.value.var_lib_dist_plugins_mb +
    disk.value.var_log_marketplace_mb
  );
});

async function load(): Promise<void> {
  loading.value = true;
  error.value = "";
  try {
    const [nextStatus, nextDisk] = await Promise.all([marketplaceApi.status(), marketplaceApi.disk()]);
    status.value = nextStatus;
    disk.value = nextDisk;
    logs.value = await marketplaceApi.logs(logService.value, 200);
  } catch (err) {
    error.value = err instanceof Error ? err.message : "加载失败";
  } finally {
    loading.value = false;
  }
}

function selectLogService(service: "render" | "schema-check" | "admin-audit"): void {
  logService.value = service;
  void load();
}

onMounted(() => {
  void load();
});
</script>

<template>
  <section class="content-section">
    <div class="section-toolbar">
      <div class="segmented">
        <button type="button" :class="{ active: logService === 'render' }" @click="selectLogService('render')">Render</button>
        <button type="button" :class="{ active: logService === 'schema-check' }" @click="selectLogService('schema-check')">Schema</button>
        <button type="button" :class="{ active: logService === 'admin-audit' }" @click="selectLogService('admin-audit')">Audit</button>
      </div>
      <button class="icon-button" type="button" :disabled="loading" title="刷新" @click="load">
        <RefreshCw :size="18" />
      </button>
    </div>

    <p v-if="error" class="error-text">{{ error }}</p>

    <div class="metrics-grid">
      <div class="metric">
        <span>Probe</span>
        <strong>{{ status?.up ? "UP" : "DOWN" }}</strong>
      </div>
      <div class="metric">
        <span>Plugins</span>
        <strong>{{ status?.plugin_count ?? 0 }}</strong>
      </div>
      <div class="metric">
        <span>Disk</span>
        <strong>{{ formatMegabytes(totalDisk) }}</strong>
      </div>
      <div class="metric">
        <span>Upstream</span>
        <strong>{{ status?.upstream_alert ? "ALERT" : "OK" }}</strong>
      </div>
    </div>

    <dl class="detail-list">
      <dt>Last render</dt>
      <dd>{{ formatDate(status?.last_render_ts) }}</dd>
      <dt>Latest git head</dt>
      <dd>{{ status?.latest_git_head ?? "未记录" }}</dd>
      <dt>Last upstream check</dt>
      <dd>{{ formatDate(status?.upstream_last_check_ts) }}</dd>
      <dt>State error</dt>
      <dd>{{ status?.state_error ?? "无" }}</dd>
    </dl>

    <pre class="log-pane">{{ logs || "No logs returned." }}</pre>
  </section>
</template>
