<script setup lang="ts">
import { KeyRound } from "lucide-vue-next";
import { ref } from "vue";
import { useRoute, useRouter } from "vue-router";

import { marketplaceApi } from "@/api/marketplace";
import { useSessionStore } from "@/stores/session";

const session = useSessionStore();
const route = useRoute();
const router = useRouter();

const key = ref("");
const loading = ref(false);
const error = ref("");

async function submit(): Promise<void> {
  error.value = "";
  loading.value = true;
  const candidate = key.value.trim();
  session.setKey(candidate);
  try {
    await marketplaceApi.status();
    const next = typeof route.query.next === "string" ? route.query.next : "/plugins";
    await router.push(next);
  } catch (err) {
    session.clear();
    error.value = err instanceof Error ? err.message : "登录失败";
  } finally {
    loading.value = false;
  }
}
</script>

<template>
  <section class="login-layout">
    <form class="auth-panel" @submit.prevent="submit">
      <div class="auth-icon">
        <KeyRound :size="24" />
      </div>
      <h2>管理员验证</h2>
      <label>
        <span>X-Admin-Key</span>
        <input v-model="key" autocomplete="off" type="password" required />
      </label>
      <p v-if="error" class="error-text">{{ error }}</p>
      <button class="primary-button" type="submit" :disabled="loading">
        {{ loading ? "验证中" : "登录" }}
      </button>
    </form>
  </section>
</template>
