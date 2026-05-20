import { useSessionStore } from "@/stores/session";
import type {
  AdminActionResult,
  AdminUploadResult,
  ApiResponse,
  MarketplaceDiskData,
  MarketplaceListData,
  MarketplacePlugin,
  MarketplaceSource,
  MarketplaceStatusData
} from "@/types/marketplace";

type UnauthorizedHandler = () => void;
type DataValidator<TData> = (data: unknown) => data is TData;

interface RequestOptions extends RequestInit {
  expectText?: boolean;
  validate?: DataValidator<unknown>;
}

let unauthorizedHandler: UnauthorizedHandler | null = null;

export function configureUnauthorizedHandler(handler: UnauthorizedHandler | null): void {
  unauthorizedHandler = handler;
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return value !== null && typeof value === "object" && !Array.isArray(value);
}

function responseMessage(payload: unknown): string {
  if (isRecord(payload)) {
    const detail = payload.detail;
    if (typeof detail === "string") {
      return detail;
    }
    const message = payload.message;
    if (typeof message === "string" && message.trim()) {
      return message;
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

function handleUnauthorizedStatus(status: number): void {
  if (status !== 401 && status !== 403) {
    return;
  }
  useSessionStore().clear();
  unauthorizedHandler?.();
}

function isApiResponse<TData>(payload: unknown): payload is ApiResponse<TData> {
  return isRecord(payload) && typeof payload.success === "boolean" && "data" in payload;
}

function unwrapApiResponse<TData>(
  path: string,
  payload: unknown,
  validate?: DataValidator<TData>
): TData {
  if (!isApiResponse<TData>(payload)) {
    throw new Error(`接口 ${path} 返回数据包结构不符合预期`);
  }
  if (!payload.success) {
    throw new Error(responseMessage(payload));
  }
  if (validate && !validate(payload.data)) {
    throw new Error(`接口 ${path} 返回数据结构不符合预期`);
  }
  return payload.data;
}

function isOptionalString(value: unknown): value is string | undefined {
  return value === undefined || typeof value === "string";
}

function isOptionalStringOrNull(value: unknown): value is string | null | undefined {
  return value === undefined || value === null || typeof value === "string";
}

function isMarketplaceSource(value: unknown): value is MarketplaceSource {
  return typeof value === "string" || isRecord(value);
}

function isMarketplacePlugin(value: unknown): value is MarketplacePlugin {
  if (!isRecord(value)) {
    return false;
  }
  if (typeof value.name !== "string" || !isMarketplaceSource(value.source)) {
    return false;
  }
  if (!isOptionalString(value.description) || !isOptionalString(value.version)) {
    return false;
  }
  if (!isOptionalString(value.license) || !isOptionalString(value.category)) {
    return false;
  }
  if (value.keywords !== undefined && !Array.isArray(value.keywords)) {
    return false;
  }
  return value.keywords === undefined || value.keywords.every((item) => typeof item === "string");
}

function isMarketplaceListData(value: unknown): value is MarketplaceListData {
  return isRecord(value) && Array.isArray(value.plugins) && value.plugins.every(isMarketplacePlugin);
}

function isMarketplaceStatusData(value: unknown): value is MarketplaceStatusData {
  return (
    isRecord(value) &&
    typeof value.up === "boolean" &&
    typeof value.status_code === "number" &&
    typeof value.plugin_count === "number" &&
    typeof value.upstream_alert === "boolean" &&
    isOptionalStringOrNull(value.last_render_ts) &&
    isOptionalStringOrNull(value.latest_git_head) &&
    isOptionalStringOrNull(value.upstream_last_check_ts) &&
    isOptionalStringOrNull(value.render_script_version) &&
    isOptionalStringOrNull(value.state_error)
  );
}

function isMarketplaceDiskData(value: unknown): value is MarketplaceDiskData {
  return (
    isRecord(value) &&
    typeof value.var_lib_git_mirrors_bifrost_internal_plugins_mb === "number" &&
    typeof value.var_lib_dist_plugins_mb === "number" &&
    typeof value.var_log_marketplace_mb === "number"
  );
}

function isAdminUploadResult(value: unknown): value is AdminUploadResult {
  return (
    isRecord(value) &&
    typeof value.tag_created === "string" &&
    typeof value.render_triggered === "boolean" &&
    typeof value.audit_id === "string" &&
    (value.stdout_snip === undefined || typeof value.stdout_snip === "string")
  );
}

function isAdminActionResult(value: unknown): value is AdminActionResult {
  return (
    isRecord(value) &&
    typeof value.audit_id === "string" &&
    (value.ok === undefined || typeof value.ok === "boolean") &&
    (value.triggered === undefined || typeof value.triggered === "boolean")
  );
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
      handleUnauthorizedStatus(response.status);
      const text = await response.text().catch(() => "");
      throw new Error(text || `请求失败 (${response.status})`);
    }
    return (await response.text()) as TData;
  }

  if (!isJsonResponse(response)) {
    if (!response.ok) {
      handleUnauthorizedStatus(response.status);
    }
    throw new Error(await nonJsonResponseMessage(path, response));
  }

  const payload = (await response.json().catch(() => ({}))) as unknown;
  if (!response.ok) {
    handleUnauthorizedStatus(response.status);
    throw new Error(responseMessage(payload));
  }
  return unwrapApiResponse<TData>(path, payload, options.validate as DataValidator<TData> | undefined);
}

export const marketplaceApi = {
  status(): Promise<MarketplaceStatusData> {
    return requestJson<MarketplaceStatusData>("/marketplace/status", { validate: isMarketplaceStatusData });
  },
  list(): Promise<MarketplaceListData> {
    return requestJson<MarketplaceListData>("/marketplace/list", { validate: isMarketplaceListData });
  },
  disk(): Promise<MarketplaceDiskData> {
    return requestJson<MarketplaceDiskData>("/marketplace/disk", { validate: isMarketplaceDiskData });
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
      body: form,
      validate: isAdminUploadResult
    });
  },
  approve(plugin: string, version: string, decision: "approve" | "reject"): Promise<AdminActionResult> {
    return requestJson<AdminActionResult>("/marketplace/admin/approve", {
      method: "POST",
      body: JSON.stringify({ plugin, version, decision }),
      validate: isAdminActionResult
    });
  },
  curate(plugin: string, action: "feature" | "deprecate" | "remove"): Promise<AdminActionResult> {
    return requestJson<AdminActionResult>("/marketplace/admin/curate", {
      method: "POST",
      body: JSON.stringify({ plugin, action }),
      validate: isAdminActionResult
    });
  },
  rerender(): Promise<AdminActionResult> {
    return requestJson<AdminActionResult>("/marketplace/admin/rerender", {
      method: "POST",
      body: JSON.stringify({}),
      validate: isAdminActionResult
    });
  }
};
