window.PROTECT_SAMPLE_STATUS = {
  schemaVersion: 1,
  demo: true,
  runId: "demo-20260912-0900",
  generatedAt: "2026-09-12T09:00:00+08:00",
  host: {
    computerName: "DEMO-DESKTOP",
    os: "Windows 11 Pro",
    lastBoot: "2026-09-11T08:10:00+08:00",
    uptimeHours: 24.8
  },
  overall: {
    status: "attention",
    label: "需要关注",
    summary: "系统可以正常使用，但 C 盘空间和按需防护需要你看一眼。",
    reasons: [
      "C 盘可用空间低于 20% 健康线。",
      "当前没有启用日常常驻杀毒，这是你选择的策略。",
      "备份状态需要以管理员权限重新核验。"
    ]
  },
  disks: [
    {
      id: "disk-c",
      mountPoint: "C:",
      label: "系统盘",
      totalBytes: 322122547200,
      freeBytes: 30064771072,
      freePercent: 9.3,
      status: "critical",
      physicalDisk: "SSD 0"
    },
    {
      id: "disk-d",
      mountPoint: "D:",
      label: "数据分区",
      totalBytes: 161061273600,
      freeBytes: 137438953472,
      freePercent: 85.3,
      status: "pass",
      physicalDisk: "SSD 0"
    },
    {
      id: "disk-f",
      mountPoint: "F:",
      label: "资料盘",
      totalBytes: 1000195956736,
      freeBytes: 137438953472,
      freePercent: 13.7,
      status: "attention",
      physicalDisk: "SSD 1"
    }
  ],
  cleanup: {
    candidateCount: 18,
    candidateBytes: 42152755200,
    approvedCount: 0,
    approvedBytes: 0,
    status: "awaiting-review",
    categories: [
      { name: "可重建缓存", count: 8, bytes: 17179869184 },
      { name: "临时文件", count: 5, bytes: 5368709120 },
      { name: "大文件待审", count: 5, bytes: 19604123648 }
    ]
  },
  protection: {
    firewall: {
      status: "pass",
      summary: "Domain、Private、Public 防火墙配置文件均已启用。"
    },
    antivirus: {
      status: "attention",
      summary: "360 和 Defender 已被系统识别，但没有日常常驻实时防护。",
      policy: "按需防护"
    },
    updates: {
      status: "pass",
      summary: "Windows Update 服务正在运行，最近一次更新已记录。"
    },
    backup: {
      status: "unknown",
      summary: "当前权限不足，无法确认备份和还原点状态。"
    },
    storageHealth: {
      status: "pass",
      summary: "系统报告物理 SSD 健康。"
    }
  },
  checks: [
    {
      id: "storage.c.free-space",
      category: "storage",
      status: "critical",
      title: "C 盘空间",
      summary: "还需要释放约 31 GB 才能达到 20% 健康线。",
      evidence: ["剩余 28.0 GB / 300.0 GB", "可用率 9.3%"],
      checkedAt: "2026-09-12T09:00:00+08:00"
    },
    {
      id: "storage.f.free-space",
      category: "storage",
      status: "attention",
      title: "F 盘空间",
      summary: "还需要释放约 49 GB 才能达到 20% 健康线。",
      evidence: ["剩余 128.0 GB / 931.5 GB", "可用率 13.7%"],
      checkedAt: "2026-09-12T09:00:00+08:00"
    },
    {
      id: "security.firewall",
      category: "protection",
      status: "pass",
      title: "防火墙",
      summary: "三个网络配置文件均已启用。",
      evidence: ["Domain: enabled", "Private: enabled", "Public: enabled"],
      checkedAt: "2026-09-12T09:00:00+08:00"
    },
    {
      id: "security.antivirus",
      category: "protection",
      status: "attention",
      title: "常驻杀毒",
      summary: "按你的设置保持关闭，页面会提醒你定期手动扫描。",
      evidence: ["360: registered", "Defender: real-time protection off"],
      checkedAt: "2026-09-12T09:00:00+08:00"
    },
    {
      id: "system.backup",
      category: "reliability",
      status: "unknown",
      title: "备份与还原点",
      summary: "需要管理员权限才能完成核验。",
      evidence: ["检查没有修改系统设置"],
      checkedAt: "2026-09-12T09:00:00+08:00"
    }
  ],
  history: [
    { runId: "demo-01", date: "2026-08-18", disks: { "C:": 18.1, "F:": 19.6 }, overall: "attention" },
    { runId: "demo-02", date: "2026-08-22", disks: { "C:": 16.8, "F:": 18.4 }, overall: "attention" },
    { runId: "demo-03", date: "2026-08-26", disks: { "C:": 14.2, "F:": 17.1 }, overall: "attention" },
    { runId: "demo-04", date: "2026-08-30", disks: { "C:": 12.8, "F:": 15.7 }, overall: "attention" },
    { runId: "demo-05", date: "2026-09-03", disks: { "C:": 11.4, "F:": 14.8 }, overall: "attention" },
    { runId: "demo-06", date: "2026-09-07", disks: { "C:": 10.2, "F:": 14.1 }, overall: "attention" },
    { runId: "demo-07", date: "2026-09-10", disks: { "C:": 9.7, "F:": 13.9 }, overall: "critical" },
    { runId: "demo-08", date: "2026-09-12", disks: { "C:": 9.3, "F:": 13.7 }, overall: "critical" }
  ]
};
