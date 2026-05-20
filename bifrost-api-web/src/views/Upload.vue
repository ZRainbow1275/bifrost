<script setup lang="ts">
import { ref } from "vue";

import { marketplaceApi } from "@/api/marketplace";
import type { AdminUploadResult } from "@/types/marketplace";

const tarball = ref<File | null>(null);
const manifest = ref<File | null>(null);
const loading = ref(false);
const error = ref("");
const result = ref<AdminUploadResult | null>(null);

function updateTarball(event: Event): void {
  const input = event.target as HTMLInputElement;
  tarball.value = input.files?.item(0) ?? null;
}

function updateManifest(event: Event): void {
  const input = event.target as HTMLInputElement;
  manifest.value = input.files?.item(0) ?? null;
}

async function submit(): Promise<void> {
  error.value = "";
  result.value = null;
  if (!tarball.value || !manifest.value) {
    error.value = "需要同时选择 tarball 和 manifest.yaml";
    return;
  }
  loading.value = true;
  try {
    result.value = await marketplaceApi.upload(tarball.value, manifest.value);
  } catch (err) {
    error.value = err instanceof Error ? err.message : "上传失败";
  } finally {
    loading.value = false;
  }
}
</script>

<template>
  <section class="content-section narrow">
    <form class="form-panel" @submit.prevent="submit">
      <label>
        <span>Plugin tarball</span>
        <input type="file" accept=".tar,.tgz,.gz" required @change="updateTarball" />
      </label>
      <label>
        <span>manifest.yaml</span>
        <input type="file" accept=".yaml,.yml" required @change="updateManifest" />
      </label>
      <p v-if="error" class="error-text">{{ error }}</p>
      <button class="primary-button" type="submit" :disabled="loading">
        {{ loading ? "上传中" : "上传并触发 render" }}
      </button>
    </form>

    <div v-if="result" class="success-panel">
      <strong>{{ result.tag_created }}</strong>
      <span>Audit: {{ result.audit_id }}</span>
    </div>
  </section>
</template>
