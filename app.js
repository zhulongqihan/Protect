(function () {
  "use strict";

  const runtimeStatus = window.PROTECT_RUNTIME_STATUS;
  const runtimeCleanup = window.PROTECT_RUNTIME_CLEANUP;
  const status = isReport(runtimeStatus) ? runtimeStatus : window.PROTECT_SAMPLE_STATUS;
  const cleanup = isCleanup(runtimeCleanup) ? runtimeCleanup : window.PROTECT_SAMPLE_CLEANUP;
  const isDemo = !isReport(runtimeStatus) || status.demo === true;
  const state = {
    candidates: Array.isArray(cleanup && cleanup.candidates) ? cleanup.candidates : [],
    selected: new Set(),
    filtered: [],
    page: 1,
    pageSize: 50
  };

  const $ = (selector) => document.querySelector(selector);
  const safeText = (value, fallback) => value === undefined || value === null || value === "" ? (fallback || "") : String(value);
  const formatBytes = (bytes) => {
    const value = Number(bytes) || 0;
    if (value < 1024) return value + " B";
    const units = ["KB", "MB", "GB", "TB"];
    let size = value;
    let unit = -1;
    while (size >= 1024 && unit < units.length - 1) {
      size /= 1024;
      unit += 1;
    }
    return size.toFixed(size >= 10 ? 0 : 1) + " " + units[unit];
  };
  const formatDate = (value) => {
    if (!value) return "未记录";
    const date = new Date(value);
    if (Number.isNaN(date.getTime())) return safeText(value, "未记录");
    return new Intl.DateTimeFormat("zh-CN", { dateStyle: "medium", timeStyle: "short" }).format(date);
  };
  const escapeHtml = (value) => safeText(value)
    .replaceAll("&", "&amp;")
    .replaceAll("<", "&lt;")
    .replaceAll(">", "&gt;")
    .replaceAll('"', "&quot;")
    .replaceAll("'", "&#039;");
  const statusLabel = (value) => ({
    pass: "正常",
    attention: "需要关注",
    critical: "立即处理",
    unknown: "未核验"
  }[value] || "未核验");
  const statusClass = (value) => ["pass", "attention", "critical", "unknown"].includes(value) ? value : "unknown";
  const statusSymbol = (value) => ({ pass: "✓", attention: "!", critical: "×", unknown: "?" }[value] || "?");
  const categoryLabel = (value) => ({
    cache: "可重建缓存",
    temp: "临时文件",
    log: "日志",
    build: "构建产物",
    "large-file": "大文件待审",
    duplicate: "重复文件",
    "app-data": "应用数据"
  }[value] || safeText(value, "其他"));
  const riskLabel = (value) => ({ low: "低风险", medium: "中风险", high: "高风险" }[value] || "需审阅");
  const percentageBucket = (value) => Math.max(0, Math.min(100, Math.round((Number(value) || 0) / 5) * 5));

  function isReport(value) {
    return Boolean(value && typeof value === "object" && Array.isArray(value.disks) && value.overall);
  }

  function isCleanup(value) {
    return Boolean(value && typeof value === "object" && Array.isArray(value.candidates));
  }

  function setHtml(selector, html) {
    const element = $(selector);
    if (element) element.innerHTML = html;
  }

  function setText(selector, value, fallback) {
    const element = $(selector);
    if (element) element.textContent = safeText(value, fallback);
  }

  function showToast(message) {
    setText("#toast", message);
    window.clearTimeout(showToast.timer);
    showToast.timer = window.setTimeout(() => setText("#toast", ""), 4500);
  }

  function renderMode() {
    const mode = $("#data-mode");
    if (!mode) return;
    mode.textContent = isDemo ? "演示数据" : "本机报告";
    mode.className = "mode-badge " + (isDemo ? "demo" : "live");
  }

  function renderHeader() {
    const overall = status.overall || {};
    const overallStatus = statusClass(overall.status);
    $("#verdict-panel").className = "verdict-panel status-" + overallStatus;
    $("#verdict-status").className = "status-chip status-chip-" + overallStatus;
    setText("#verdict-status", safeText(overall.label, statusLabel(overallStatus)));
    setText("#verdict-title", safeText(overall.label, statusLabel(overallStatus)));
    setText("#verdict-panel .verdict-symbol", statusSymbol(overallStatus));
    setText("#verdict-summary", safeText(overall.summary, "报告没有提供总体说明。"));
    setText("#host-name", status.host && status.host.computerName, "未知设备");
    setText("#host-os", status.host && status.host.os, "系统信息未记录");
    setText("#report-meta", (isDemo ? "这是合成演示数据。 " : "") + "报告生成于 " + formatDate(status.generatedAt));
    setText("#checked-at", formatDate(status.generatedAt));
    setText("#run-id", status.runId, "无编号");
    setHtml("#verdict-reasons", (overall.reasons || []).map((reason) => "<li>" + escapeHtml(reason) + "</li>").join(""));
  }

  function renderDisks() {
    const disks = Array.isArray(status.disks) ? status.disks : [];
    if (!disks.length) {
      setHtml("#disk-list", '<div class="empty-state">报告没有磁盘数据。请重新运行只读采集器。</div>');
      return;
    }
    setHtml("#disk-list", disks.map((disk) => {
      const diskStatus = statusClass(disk.status);
      const freePercent = Math.max(0, Math.min(100, Number(disk.freePercent) || 0));
      return '<div class="disk-row">' +
        '<div class="disk-name"><strong>' + escapeHtml(disk.mountPoint) + " · " + escapeHtml(disk.label) + "</strong>" +
        '<span>' + escapeHtml(disk.physicalDisk || "物理磁盘未记录") + "</span></div>" +
        '<div class="meter" aria-label="' + escapeHtml(disk.mountPoint + " 可用 " + freePercent.toFixed(1) + "%") + '">' +
        '<div class="meter-fill status-' + diskStatus + ' width-' + percentageBucket(freePercent) + '"></div></div>' +
        '<div class="disk-stat"><strong>' + freePercent.toFixed(1) + '%</strong><span>可用</span></div>' +
        '<div class="disk-meta">' + escapeHtml(formatBytes(disk.freeBytes)) + " / " + escapeHtml(formatBytes(disk.totalBytes)) + "</div>" +
        "</div>";
    }).join(""));
  }

  function renderPriority() {
    const items = [];
    (status.disks || []).filter((disk) => disk.status === "critical" || disk.status === "attention").forEach((disk) => {
      const targetBytes = Number(disk.totalBytes) * 0.2;
      const shortfall = Math.max(0, targetBytes - Number(disk.freeBytes));
      items.push({
        status: disk.status,
        title: disk.mountPoint + " 空间不足",
        summary: "达到 20% 健康线前还需要释放约 " + formatBytes(shortfall) + "。",
        action: "查看清理清单"
      });
    });
    const protection = status.protection || {};
    Object.keys(protection).forEach((key) => {
      const item = protection[key];
      if (item && (item.status === "attention" || item.status === "unknown")) {
        items.push({
          status: item.status,
          title: ({ antivirus: "常驻杀毒策略", backup: "备份与还原点", updates: "系统更新", firewall: "防火墙", storageHealth: "物理硬盘" }[key] || key),
          summary: item.summary || "这项检查需要进一步确认。",
          action: item.status === "unknown" ? "需要更高权限核验" : "按需检查"
        });
      }
    });
    if (!items.length) {
      items.push({ status: "pass", title: "暂时没有高优先级问题", summary: "关键检查均已通过，可以继续保持定期检查。", action: "继续维护" });
    }
    setHtml("#priority-list", items.slice(0, 6).map((item) => {
      const cls = statusClass(item.status);
      return '<div class="priority-row"><span class="status-chip status-chip-' + cls + '">' +
        escapeHtml(statusLabel(cls)) + "</span><div class=\"priority-copy\"><h3>" +
        escapeHtml(item.title) + "</h3><p>" + escapeHtml(item.summary) +
        '</p></div><span class="priority-action">' + escapeHtml(item.action) + "</span></div>";
    }).join(""));
  }

  function getFilteredCandidates() {
    const category = $("#category-filter") && $("#category-filter").value || "all";
    const risk = $("#risk-filter") && $("#risk-filter").value || "all";
    const query = ($("#path-filter") && $("#path-filter").value || "").trim().toLowerCase();
    return state.candidates.filter((candidate) => {
      const path = safeText(candidate.path).toLowerCase();
      return (category === "all" || candidate.category === category) &&
        (risk === "all" || candidate.risk === risk) &&
        (!query || path.includes(query) || safeText(candidate.reason).toLowerCase().includes(query));
    });
  }

  function renderCategoryOptions() {
    const select = $("#category-filter");
    if (!select) return;
    const categories = [...new Set(state.candidates.map((candidate) => candidate.category))].sort();
    select.innerHTML = '<option value="all">全部</option>' + categories.map((category) =>
      '<option value="' + escapeHtml(category) + '">' + escapeHtml(categoryLabel(category)) + "</option>").join("");
  }

  function renderSelectionSummary() {
    const selected = state.candidates.filter((candidate) => state.selected.has(candidate.id));
    const bytes = selected.reduce((sum, candidate) => sum + (Number(candidate.bytes) || 0), 0);
    setText("#selection-summary", "已选择 " + selected.length + " 项 · 预计 " + formatBytes(bytes));
  }

  function renderCleanup() {
    state.filtered = getFilteredCandidates();
    const pageCount = Math.max(1, Math.ceil(state.filtered.length / state.pageSize));
    state.page = Math.min(state.page, pageCount);
    const start = (state.page - 1) * state.pageSize;
    const visible = state.filtered.slice(start, start + state.pageSize);
    const summary = "共 " + state.filtered.length + " 项，预计 " + formatBytes(state.filtered.reduce((sum, item) => sum + (Number(item.bytes) || 0), 0));
    setText("#cleanup-summary", summary);
    const excluded = cleanup && cleanup.excludedByPolicy;
    setText("#cleanup-policy-note", excluded && Number(excluded.count) > 0
      ? "个人资料策略已保护 " + Number(excluded.count) + " 项（约 " + formatBytes(excluded.bytes) + "），这些项目不会进入审批清单。"
      : "个人资料和常见个人文件类型会被策略保护，不会进入审批清单。");
    setText("#page-summary", "第 " + state.page + " / " + pageCount + " 页");
    $("#previous-page").disabled = state.page <= 1;
    $("#next-page").disabled = state.page >= pageCount;
    if (!visible.length) {
      setHtml("#cleanup-list", '<div class="empty-state">当前筛选没有候选项。可以清空筛选，或重新运行只读采集器。</div>');
    } else {
      setHtml("#cleanup-list", visible.map((candidate) => {
        const checked = state.selected.has(candidate.id) ? " checked" : "";
        const risk = safeText(candidate.risk, "high");
        return '<div class="cleanup-item"><input type="checkbox" data-candidate-id="' + escapeHtml(candidate.id) +
          '"' + checked + ' aria-label="选择 ' + escapeHtml(candidate.path) + '">' +
          '<div><div class="cleanup-path">' + escapeHtml(candidate.path) + '</div><div class="cleanup-reason">' +
          escapeHtml(candidate.reason) + "</div></div>" +
          '<div class="cleanup-meta"><strong>' + escapeHtml(formatBytes(candidate.bytes)) +
          '</strong><span>' + escapeHtml(categoryLabel(candidate.category)) + "</span></div>" +
          '<div class="cleanup-meta"><strong class="risk-' + escapeHtml(risk) + '">' + escapeHtml(riskLabel(risk)) +
          '</strong><span>' + escapeHtml(candidate.reversible ? "可恢复标记" : "默认送回收站") + "</span></div></div>";
      }).join(""));
    }
    renderSelectionSummary();
  }

  function renderProtection() {
    const labels = {
      firewall: "防火墙",
      antivirus: "杀毒策略",
      updates: "系统更新",
      backup: "备份与还原点",
      storageHealth: "物理硬盘"
    };
    const protection = status.protection || {};
    const rows = Object.keys(labels).map((key) => {
      const item = protection[key] || { status: "unknown", summary: "报告没有提供这一项。" };
      const cls = statusClass(item.status);
      return '<div class="check-row"><span class="check-symbol status-' + cls + '" aria-hidden="true">' +
        statusSymbol(cls) + '</span><div class="check-copy"><h3>' + escapeHtml(labels[key]) +
        "</h3><p>" + escapeHtml(item.summary) + "</p></div><span class=\"status-chip status-chip-" +
        cls + '">' + escapeHtml(statusLabel(cls)) + "</span></div>";
    });
    setHtml("#protection-list", rows.join(""));
  }

  function renderEvidence() {
    const checks = Array.isArray(status.checks) ? status.checks : [];
    if (!checks.length) {
      setHtml("#evidence-list", '<div class="empty-state">没有可展开的检查证据。</div>');
      return;
    }
    setHtml("#evidence-list", checks.map((check) => {
      const cls = statusClass(check.status);
      return '<div class="evidence-row"><div><span class="status-chip status-chip-' + cls + '">' +
        escapeHtml(statusLabel(cls)) + "</span><h3>" + escapeHtml(check.title) +
        '</h3><p class="mono">' + escapeHtml(formatDate(check.checkedAt)) + "</p></div>" +
        '<div class="evidence-copy"><p>' + escapeHtml(check.summary) + "</p><ul>" +
        (check.evidence || []).map((item) => "<li>" + escapeHtml(item) + "</li>").join("") + "</ul></div></div>";
    }).join(""));
  }

  function renderHistory() {
    const history = Array.isArray(status.history) ? status.history.slice(-90) : [];
    if (!history.length) {
      setHtml("#history-chart", '<div class="empty-state">还没有足够的历史报告。完成一次清理后，这里会开始记录趋势。</div>');
      return;
    }
    const values = history.flatMap((entry) => Object.values(entry.disks || {}).map(Number)).filter(Number.isFinite);
    const max = Math.max(20, ...values);
    setHtml("#history-chart", history.map((entry) => {
      const current = Math.min(max, Math.max(0, Number((entry.disks || {})["C:"]) || 0));
      const height = Math.max(5, percentageBucket((current / max) * 100));
      const cls = statusClass(entry.overall);
      const label = safeText(entry.date) + " · C 盘 " + current.toFixed(1) + "% · " + statusLabel(cls);
      return '<div class="history-bar status-' + cls + ' height-' + height + '" tabindex="0" aria-label="' + escapeHtml(label) + '"></div>';
    }).join(""));
    setHtml("#history-table-wrap", "<table><caption>历史报告数据</caption><thead><tr><th>日期</th><th>C 盘可用率</th><th>F 盘可用率</th><th>状态</th></tr></thead><tbody>" +
      history.map((entry) => "<tr><td>" + escapeHtml(entry.date) + "</td><td>" + escapeHtml((entry.disks || {})["C:"]) +
      "%</td><td>" + escapeHtml((entry.disks || {})["F:"]) + "%</td><td>" + escapeHtml(statusLabel(statusClass(entry.overall))) + "</td></tr>").join("") +
      "</tbody></table>");
  }

  function exportApproval() {
    const selected = state.candidates.filter((candidate) => state.selected.has(candidate.id));
    if (!selected.length) {
      showToast("请先选择至少一个候选项。");
      return;
    }
    const approval = {
      schemaVersion: 1,
      runId: cleanup.runId || status.runId,
      approvedCandidateIds: selected.map((candidate) => candidate.id),
      mode: "recycle",
      approvedAt: new Date().toISOString()
    };
    const blob = new Blob([JSON.stringify(approval, null, 2)], { type: "application/json" });
    const url = URL.createObjectURL(blob);
    const link = document.createElement("a");
    link.href = url;
    link.download = "approval-" + safeText(approval.runId, "report") + ".json";
    document.body.appendChild(link);
    link.click();
    link.remove();
    URL.revokeObjectURL(url);
    showToast("审批文件已导出。请把它交给 Apply-Approved-Cleanup.ps1 执行。");
  }

  function bindEvents() {
    ["category-filter", "risk-filter", "path-filter"].forEach((id) => {
      const element = document.getElementById(id);
      if (!element) return;
      element.addEventListener(element.tagName === "INPUT" ? "input" : "change", () => {
        state.page = 1;
        renderCleanup();
      });
    });
    $("#cleanup-list").addEventListener("change", (event) => {
      const input = event.target.closest("[data-candidate-id]");
      if (!input) return;
      if (input.checked) state.selected.add(input.dataset.candidateId);
      else state.selected.delete(input.dataset.candidateId);
      renderSelectionSummary();
    });
    $("#select-visible").addEventListener("click", () => {
      state.filtered.slice((state.page - 1) * state.pageSize, state.page * state.pageSize).forEach((candidate) => state.selected.add(candidate.id));
      renderCleanup();
      showToast("已勾选当前结果。");
    });
    $("#clear-selection").addEventListener("click", () => {
      state.selected.clear();
      renderCleanup();
      showToast("已清空选择。");
    });
    $("#export-approval").addEventListener("click", exportApproval);
    $("#previous-page").addEventListener("click", () => { state.page -= 1; renderCleanup(); });
    $("#next-page").addEventListener("click", () => { state.page += 1; renderCleanup(); });
    $("#refresh-button").addEventListener("click", () => window.location.reload());
  }

  function init() {
    if (!isReport(status)) {
      setText("#verdict-summary", "没有找到有效的本地报告。请运行只读采集器。");
      setHtml("#verdict-reasons", "<li>页面当前只能展示合成示例。</li>");
    }
    renderMode();
    renderHeader();
    renderDisks();
    renderPriority();
    renderCategoryOptions();
    renderCleanup();
    renderProtection();
    renderEvidence();
    renderHistory();
    bindEvents();
  }

  init();
}());
