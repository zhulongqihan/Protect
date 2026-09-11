window.PROTECT_SAMPLE_CLEANUP = {
  schemaVersion: 1,
  runId: "demo-20260912-0900",
  generatedAt: "2026-09-12T09:00:00+08:00",
  candidates: [
    {
      id: "demo-cache-001",
      category: "cache",
      path: "C:\\Users\\<user>\\AppData\\Local\\ExampleApp\\Cache\\old-cache.bin",
      bytes: 4294967296,
      lastWriteUtc: "2026-07-01T02:00:00Z",
      risk: "low",
      action: "permanent",
      reversible: false,
      reason: "应用缓存，可由应用重新生成。",
      fingerprint: { size: 4294967296, lastWriteUtc: "2026-07-01T02:00:00Z" }
    },
    {
      id: "demo-large-001",
      category: "large-file",
      path: "F:\\Projects\\<project>\\archive.zip",
      bytes: 2147483648,
      lastWriteUtc: "2025-12-01T02:00:00Z",
      risk: "high",
      action: "review",
      reversible: true,
      reason: "大文件，无法仅凭路径判断是否还能删除。",
      fingerprint: { size: 2147483648, lastWriteUtc: "2025-12-01T02:00:00Z" }
    }
  ]
};
