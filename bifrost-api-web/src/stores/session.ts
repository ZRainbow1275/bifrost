import { defineStore } from "pinia";
import { computed, ref } from "vue";

const STORAGE_KEY = "bifrost.marketplace.adminKey";

export const useSessionStore = defineStore("session", () => {
  const storage = window.sessionStorage;
  const adminKey = ref<string>(storage.getItem(STORAGE_KEY) ?? "");
  const hasKey = computed(() => adminKey.value.trim().length > 0);

  function setKey(value: string): void {
    adminKey.value = value.trim();
    if (adminKey.value) {
      storage.setItem(STORAGE_KEY, adminKey.value);
    } else {
      storage.removeItem(STORAGE_KEY);
    }
  }

  function clear(): void {
    adminKey.value = "";
    storage.removeItem(STORAGE_KEY);
  }

  return { adminKey, hasKey, setKey, clear };
});
