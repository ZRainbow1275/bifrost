export function formatDate(value: string | null | undefined): string {
  if (!value) {
    return "未记录";
  }
  const date = new Date(value);
  if (Number.isNaN(date.getTime())) {
    return value;
  }
  return new Intl.DateTimeFormat("zh-CN", {
    dateStyle: "medium",
    timeStyle: "medium"
  }).format(date);
}

export function formatMegabytes(value: number): string {
  if (!Number.isFinite(value) || value <= 0) {
    return "0 MB";
  }
  if (value >= 1024) {
    return `${(value / 1024).toFixed(1)} GB`;
  }
  return `${Math.round(value)} MB`;
}

export function sourceLabel(source: string | Record<string, unknown>): string {
  if (typeof source === "string") {
    return source;
  }
  const discriminator = source.source;
  if (typeof discriminator === "string") {
    return discriminator;
  }
  return "object";
}
