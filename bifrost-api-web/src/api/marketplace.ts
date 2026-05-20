import { useSessionStore } from "@/stores/session";
import type {
  AdminActionResult,
  AdminUploadResult,
  ApiResponse,
  MarketplaceDiskData,
  MarketplaceListData,
  MarketplaceStatusData
} from "@/types/marketplace";

interface RequestOptions extends RequestInit {
  expectText?: boolean;
}

function responseMessage(payload: unknown): string {
  if (payload && typeof payload === "object" && "detail" in payload) {
    const detail = (payload as { detail?: unknown }).detail;
    if (typeof detail === "string") {
      return detail;
    }
  }
  return "请求失败";
}

function isJsonResponse(response: Response): boolean {
  const contentType = response.headers.get("content-type") ?? "";
  return contentType.includes("application/json") || contentType.includes("+json");
}

async function nonJsonResponseMessage(path: string, response: Response): Promise<string> {
  const contentType = response.headers.get("content-type") || "unknown content-type";
  const rawText = await response.text().catch(() => "");
  const sample = rawText.replace(/\s+/g, " ").trim().slice(0, 160);
  const suffix = sample ? `: ${sample}` : "";
  return `接口 ${path} 返回非 JSON 响应 (${response.status} ${contentType})${suffix}`;
}

async function requestJson<TData>(path: string, options: RequestOptions = {}): Promise<TData> {
  const session = useSessionStore();
  const headers = new Headers(options.headers);
  if (session.adminKey) {
    headers.set("X-Admin-Key", session.adminKey);
  }
  if (options.body && !(options.body instanceof FormData) && !headers.has("Content-Type")) {
    headers.set("Content-Type", "application/json");
  }

  const response = await fetch(path, { ...options, headers });
  if (options.expectText) {
    if (!response.ok) {
      throw new Error(await response.text());
    }
    return (await response.text()) as TData;
  }

  if (!isJsonResponse(response)) {
    throw new Error(await nonJsonResponseMessage(path, response));
  }

  const payload = (await response.json().catch(() => ({}))) as unknown;
  if (!response.ok) {
    throw new Error(responseMessage(payload));
  }
  const apiResponse = payload as ApiResponse<TData>;
  return apiResponse.data;
}

export const marketplaceApi = {
  status(): Promise<MarketplaceStatusData> {
    return requestJson<MarketplaceStatusData>("/marketplace/status");
  },
  list(): Promise<MarketplaceListData> {
    return requestJson<MarketplaceListData>("/marketplace/list");
  },
  disk(): Promise<MarketplaceDiskData> {
    return requestJson<MarketplaceDiskData>("/marketplace/disk");
  },
  logs(service: "render" | "schema-check" | "admin-audit", tail = 200): Promise<string> {
    const params = new URLSearchParams({ service, tail: String(tail) });
    return requestJson<string>(`/marketplace/logs?${params.toString()}`, { expectText: true });
  },
  upload(tarball: File, manifest: File): Promise<AdminUploadResult> {
    const form = new FormData();
    form.set("tarball", tarball);
    form.set("manifest", manifest);
    return requestJson<AdminUploadResult>("/marketplace/admin/upload", {
      method: "POST",
      body: form
    });
  },
  approve(plugin: string, version: string, decision: "approve" | "reject"): Promise<AdminActionResult> {
    return requestJson<AdminActionResult>("/marketplace/admin/approve", {
      method: "POST",
      body: JSON.stringify({ plugin, version, decision })
    });
  },
  curate(plugin: string, action: "feature" | "deprecate" | "remove"): Promise<AdminActionResult> {
    return requestJson<AdminActionResult>("/marketplace/admin/curate", {
      method: "POST",
      body: JSON.stringify({ plugin, action })
    });
  },
  rerender(): Promise<AdminActionResult> {
    return requestJson<AdminActionResult>("/marketplace/admin/rerender", {
      method: "POST",
      body: JSON.stringify({})
    });
  }
};
