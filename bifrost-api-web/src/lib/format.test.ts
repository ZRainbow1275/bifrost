import { describe, expect, it } from "vitest";

import { formatMegabytes, sourceLabel } from "./format";

describe("format helpers", () => {
  it("formats disk usage in MB and GB", () => {
    expect(formatMegabytes(0)).toBe("0 MB");
    expect(formatMegabytes(42)).toBe("42 MB");
    expect(formatMegabytes(1536)).toBe("1.5 GB");
  });

  it("labels marketplace source variants", () => {
    expect(sourceLabel("./plugins/hello-world-skill")).toBe("./plugins/hello-world-skill");
    expect(sourceLabel({ source: "url", url: "https://example.test/repo.git" })).toBe("url");
    expect(sourceLabel({ url: "https://example.test/repo.git" })).toBe("object");
  });
});
