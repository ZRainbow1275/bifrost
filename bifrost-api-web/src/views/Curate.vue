<script setup lang="ts">
import { ref } from "vue";

import { marketplaceApi } from "@/api/marketplace";
import type { AdminActionResult } from "@/types/marketplace";

const plugin = ref("");
const version = ref("");
const decision = ref<"approve" | "reject">("approve");
const action = ref<"feature" | "deprecate" | "remove">("feature");
const result = ref<AdminActionResult | null>(null);
const error = ref("");
const loading = ref(false);

async function runApprove(): Promise<void> {
  loading.value = true;
  error.value = "";
  result.value = null;
  try {
    result.value = await marketplaceApi.approve(plugin.value.trim(), version.value.trim(), decision.value);
  } catch (err) {
    error.value = err instanceof Error ? err.message : "审批失败";
  } finally {
    loading.value = false;
  }
}

async function runCurate(): Promise<void> {
  loading.value = true;
  error.value = "";
  result.value = null;
  try {
    result.value = await marketplaceApi.curate(plugin.value.trim(), action.value);
  } catch (err) {
    error.value = err instanceof Error ? err.message : "治理失败";
  } finally {
    loading.value = false;
  }
}

async function rerender(): Promise<void> {
  loading.value = true;
  error.value = "";
  result.value = null;
  try {
    result.value = await marketplaceApi.rerender();
  } catch (err) {
    error.value = err instanceof Error ? err.message : "触发失败";
  } finally {
    loading.value = false;
  }
}
</script>

<template>
  <section class="content-section narrow">
    <div class="form-panel">
      <label>
        <span>Plugin</span>
        <input v-model="plugin" type="text" required />
      </label>
      <label>
        <span>Version</span>
        <input v-model="version" type="text" placeholder="0.1.0" />
      </label>

      <div class="split-row">
        <label>
          <span>Approve</span>
          <select v-model="decision">
            <option value="approve">approve</option>
            <option value="reject">reject</option>
          </select>
        </label>
        <button class="secondary-button" type="button" :disabled="loading || !plugin || !version" @click="runApprove">
          写入审批
        </button>
      </div>

      <div class="split-row">
        <label>
          <span>Curate</span>
          <select v-model="action">
            <option value="feature">feature</option>
            <option value="deprecate">deprecate</option>
            <option value="remove">remove</option>
          </select>
        </label>
        <button class="secondary-button" type="button" :disabled="loading || !plugin" @click="runCurate">
          更新治理标记
        </button>
      </div>

      <button class="primary-button" type="button" :disabled="loading" @click="rerender">
        手动 rerender
      </button>
      <p v-if="error" class="error-text">{{ error }}</p>
    </div>

    <div v-if="result" class="success-panel">
      <strong>{{ result.triggered ? "Render triggered" : "Action accepted" }}</strong>
      <span>Audit: {{ result.audit_id }}</span>
    </div>
  </section>
</template>
