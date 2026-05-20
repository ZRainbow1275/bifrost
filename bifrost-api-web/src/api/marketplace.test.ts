import { createPinia, setActivePinia } from "pinia";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";

import { configureUnauthorizedHandler, marketplaceApi } from "./marketplace";
import { useSessionStore } from "@/stores/session";

function createMemoryStorage(): Storage {
  const values = new Map<string, string>();
  return {
    get length() {
      return values.size;
    },
    clear(): void {
      values.clear();
    },
    getItem(key: string): string | null {
      return values.get(key) ?? null;
    },
    key(index: number): string | null {
      return Array.from(values.keys())[index] ?? null;
    },
    removeItem(key: string): void {
      values.delete(key);
    },
    setItem(key: string, value: string): void {
      values.set(key, value);
    }
  };
}

describe("marketplaceApi", () => {
  let storage: Storage;

  beforeEach(() => {
    storage = createMemoryStorage();
    vi.stubGlobal("window", { sessionStorage: storage });
    setActivePinia(createPinia());
  });

  afterEach(() => {
    configureUnauthorizedHandler(null);
    vi.unstubAllGlobals();
  });

  it("sends X-Admin-Key from session storage", async () => {
    useSessionStore().setKey("local-admin-key");
    let observedHeaders: Headers | undefined;
    const fetchMock = vi.fn(async (_input: string | URL | Request, init?: RequestInit) => {
      observedHeaders = init?.headers as Headers | undefined;
      return new Response(JSON.stringify({ success: true, data: { plugins: [] } }), {
        headers: { "Content-Type": "application/json" }
      });
    });
    vi.stubGlobal("fetch", fetchMock);

    await marketplaceApi.list();

    expect(observedHeaders).toBeInstanceOf(Headers);
    expect(observedHeaders?.get("X-Admin-Key")).toBe("local-admin-key");
  });

  it("rejects SPA fallback HTML returned by an API endpoint", async () => {
    vi.stubGlobal(
      "fetch",
      vi.fn(async () =>
        new Response("<!doctype html><html><body>panel shell</body></html>", {
          status: 200,
          headers: { "Content-Type": "text/html" }
        })
      )
    );

    await expect(marketplaceApi.status()).rejects.toThrow(
      "接口 /marketplace/status 返回非 JSON 响应"
    );
  });

  it("rejects success=false API envelopes", async () => {
    vi.stubGlobal(
      "fetch",
      vi.fn(async () =>
        new Response(JSON.stringify({ success: false, message: "render rejected", data: null }), {
          headers: { "Content-Type": "application/json" }
        })
      )
    );

    await expect(marketplaceApi.list()).rejects.toThrow("render rejected");
  });

  it("clears the session and calls the unauthorized handler on 403", async () => {
    const session = useSessionStore();
    session.setKey("expired-admin-key");
    const handler = vi.fn();
    configureUnauthorizedHandler(handler);
    vi.stubGlobal(
      "fetch",
      vi.fn(async () =>
        new Response(JSON.stringify({ detail: "无效管理密钥" }), {
          status: 403,
          headers: { "Content-Type": "application/json" }
        })
      )
    );

    await expect(marketplaceApi.status()).rejects.toThrow("无效管理密钥");

    expect(session.adminKey).toBe("");
    expect(storage.getItem("bifrost.marketplace.adminKey")).toBeNull();
    expect(handler).toHaveBeenCalledTimes(1);
  });

  it("clears the session on non-JSON 403 responses", async () => {
    const session = useSessionStore();
    session.setKey("expired-admin-key");
    const handler = vi.fn();
    configureUnauthorizedHandler(handler);
    vi.stubGlobal(
      "fetch",
      vi.fn(async () =>
        new Response("panel requires VPN/private access", {
          status: 403,
          headers: { "Content-Type": "text/plain" }
        })
      )
    );

    await expect(marketplaceApi.status()).rejects.toThrow("接口 /marketplace/status 返回非 JSON 响应");

    expect(session.adminKey).toBe("");
    expect(handler).toHaveBeenCalledTimes(1);
  });

  it("rejects malformed marketplace list payloads", async () => {
    vi.stubGlobal(
      "fetch",
      vi.fn(async () =>
        new Response(JSON.stringify({ success: true, data: { plugins: [{ name: "missing-source" }] } }), {
          headers: { "Content-Type": "application/json" }
        })
      )
    );

    await expect(marketplaceApi.list()).rejects.toThrow("接口 /marketplace/list 返回数据结构不符合预期");
  });
});
