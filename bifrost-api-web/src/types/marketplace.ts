export interface ApiResponse<TData> {
  success: boolean;
  data: TData;
  message?: string;
}

export type MarketplaceSource = string | Record<string, unknown>;

export interface MarketplacePlugin {
  name: string;
  source: MarketplaceSource;
  description?: string;
  version?: string;
  author?: {
    name?: string;
    email?: string;
  };
  license?: string;
  keywords?: string[];
  category?: string;
  strict?: boolean;
  metadata?: Record<string, unknown>;
}

export interface MarketplaceListData {
  plugins: MarketplacePlugin[];
  name?: string;
  version?: string;
  metadata?: Record<string, unknown>;
}

export interface MarketplaceStatusData {
  up: boolean;
  status_code: number;
  last_render_ts?: string | null;
  latest_git_head?: string | null;
  plugin_count: number;
  upstream_alert: boolean;
  upstream_last_check_ts?: string | null;
  render_script_version?: string | null;
  state_error?: string | null;
}

export interface MarketplaceDiskData {
  var_lib_git_mirrors_bifrost_internal_plugins_mb: number;
  var_lib_dist_plugins_mb: number;
  var_log_marketplace_mb: number;
}

export interface AdminUploadResult {
  tag_created: string;
  render_triggered: boolean;
  audit_id: string;
  stdout_snip?: string;
}

export interface AdminActionResult {
  ok?: boolean;
  triggered?: boolean;
  audit_id: string;
}
