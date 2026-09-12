# 开发说明

## 运行链路

`Start-Maintenance.ps1` 生成一个批次编号，依次调用：

1. `Build-CleanupManifest.ps1`：读取候选文件元信息，输出本机清单；
2. `Collect-SystemStatus.ps1`：读取磁盘、系统可靠性和保护状态，写入本机报告；
3. `Open-Dashboard.ps1`：打开静态页面。

页面只读取 `runtime/data/latest-status.js` 和 `runtime/data/pending-cleanup.js`。若本机数据不存在，页面退回到 `sample/` 中的合成数据。

`Apply-Approved-Cleanup.ps1` 不接受路径作为删除指令，只接受页面导出的候选 ID。它会重新读取当前清单、核对文件指纹、检查系统路径和个人资料策略，再执行送入回收站或显式永久删除。清理后默认按实际成功项增量更新清单并重新采集状态；传入 `-DeepRefresh` 时才重新遍历全部固定磁盘。

## 本地数据边界

所有运行输出都在 `runtime/`。这个目录被 `.gitignore` 忽略，不能加入公开提交。开发时可以查看本机报告，但不要把其中的内容复制到 Markdown、示例或 issue。

## 可验证命令

PowerShell 语法检查：

```powershell
$files = Get-ChildItem .\scripts -Filter *.ps1
foreach ($file in $files) {
  $tokens = $null
  $errors = $null
  [System.Management.Automation.Language.Parser]::ParseFile($file.FullName, [ref]$tokens, [ref]$errors) | Out-Null
  if ($errors.Count) { throw $file.FullName }
}
```

JavaScript 语法检查：

```powershell
node --check app.js
node --check sample/status.example.js
node --check sample/cleanup.example.js
```

公开安全检查：

```powershell
.\scripts\Check-PublicSafe.ps1 -History
```

## 扩展规则

新增清理规则时，先说明它为什么安全、怎样恢复、如何验证文件没有变化，再加入 `Protect.Common.ps1`。规则应优先识别可重建缓存和明确的诊断残留；不能用“路径看起来像”替代审批和指纹校验。

新增状态检查时，给出 `pass`、`attention`、`critical` 或 `unknown`，同时提供人能读懂的 `summary` 和可核对的 `evidence`。没有证据时返回 `unknown`。

公开源码必须继续遵守允许路径清单。新增公开文件后，要同步更新 `Check-PublicSafe.ps1` 的规则，并在提交前运行带 `-History` 的扫描。
