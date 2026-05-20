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
const statusLoading = ref(false);
const diskLoading = ref(false);
const logsLoading = ref(false);
const statusError = ref("");
const diskError = ref("");
const logsError = ref("");

const loading = computed(() => statusLoading.value || diskLoading.value || logsLoading.value);

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

const probeLabel = computed(() => {
  if (!status.value) {
    return "未知";
  }
  return status.value.up ? "UP" : "DOWN";
});

const pluginCountLabel = computed(() => {
  if (!status.value) {
    return "未记录";
  }
  return String(status.value.plugin_count);
});

const diskLabel = computed(() => {
  if (!disk.value) {
    return "未记录";
  }
  return formatMegabytes(totalDisk.value);
});

const upstreamLabel = computed(() => {
  if (!status.value) {
    return "未知";
  }
  return status.value.upstream_alert ? "ALERT" : "OK";
});

const stateErrorLabel = computed(() => {
  if (!status.value) {
    return "状态未加载";
  }
  return status.value.state_error ?? "无";
});

const logFallback = computed(() => {
  if (logsLoading.value) {
    return "Loading logs...";
  }
  if (logsError.value) {
    return "日志不可用。";
  }
  return "No logs returned.";
});

async function loadStatus(): Promise<void> {
  statusLoading.value = true;
  statusError.value = "";
  try {
    status.value = await marketplaceApi.status();
  } catch (err) {
    statusError.value = err instanceof Error ? err.message : "状态加载失败";
  } finally {
    statusLoading.value = false;
  }
}

async function loadDisk(): Promise<void> {
  diskLoading.value = true;
  diskError.value = "";
  try {
    disk.value = await marketplaceApi.disk();
  } catch (err) {
    diskError.value = err instanceof Error ? err.message : "磁盘加载失败";
  } finally {
    diskLoading.value = false;
  }
}

async function loadLogs(): Promise<void> {
  logsLoading.value = true;
  logsError.value = "";
  try {
    logs.value = await marketplaceApi.logs(logService.value, 200);
  } catch (err) {
    logs.value = "";
    logsError.value = err instanceof Error ? err.message : "日志加载失败";
  } finally {
    logsLoading.value = false;
  }
}

async function load(): Promise<void> {
  await Promise.all([loadStatus(), loadDisk(), loadLogs()]);
}

function selectLogService(service: "render" | "schema-check" | "admin-audit"): void {
  logService.value = service;
  void loadLogs();
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

    <div v-if="statusError || diskError || logsError" class="error-stack">
      <p v-if="statusError" class="error-text">Status: {{ statusError }}</p>
      <p v-if="diskError" class="error-text">Disk: {{ diskError }}</p>
      <p v-if="logsError" class="error-text">Logs: {{ logsError }}</p>
    </div>

    <div class="metrics-grid">
      <div class="metric">
        <span>Probe</span>
        <strong>{{ probeLabel }}</strong>
      </div>
      <div class="metric">
        <span>Plugins</span>
        <strong>{{ pluginCountLabel }}</strong>
      </div>
      <div class="metric">
        <span>Disk</span>
        <strong>{{ diskLabel }}</strong>
      </div>
      <div class="metric">
        <span>Upstream</span>
        <strong>{{ upstreamLabel }}</strong>
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
      <dd>{{ stateErrorLabel }}</dd>
    </dl>

    <pre class="log-pane">{{ logs || logFallback }}</pre>
  </section>
</template>
