# Protect Computer

一个只在 Windows 本机运行的电脑空间与健康报告工具。它先读取磁盘、系统更新、防火墙、按需杀毒策略、备份可见性和物理磁盘状态，再把可能清理的文件列成清单。只有你在页面中勾选并导出审批文件后，清理脚本才会处理对应文件。

项目的公开部分只包含源码、示例数据、文档和隐私检查器。真实报告、完整路径、审批记录、机器名、账号信息和本地日志都写入被 Git 忽略的 `runtime/` 目录。

## 适用环境

- Windows 10 或 Windows 11
- Windows PowerShell 5.1 或 PowerShell 7+
- 现代 Edge、Chrome 或其他支持本地 HTML 的浏览器
- Git 只在启用公开仓库安全闸门或自动同步时需要

工具不会安装常驻杀毒软件，也不会改变 Defender、360、防火墙、Windows Update 或备份设置。报告会如实显示当前检测结果；按需防护状态会被标成“需要关注”。

## 快速开始

在 PowerShell 中执行：

```powershell
Set-Location .\Protect
.\Setup.ps1
.\Start-Maintenance.cmd
```

`Start-Maintenance.cmd` 默认进行全盘只读扫描，可能需要较长时间；它只生成清单和报告，不删除文件。临时查看空间状态可以使用快速模式：

```powershell
.\Start-Maintenance.cmd -Fast
```

扫描完成后，页面会自动打开；也可以单独执行 `.\Open-Dashboard.cmd`。没有本机报告时，页面显示的是合成演示数据，页面右上角会标注“演示数据”。

## 审批和清理

1. 在“清理审核”区域查看当前筛选结果中的每一项，路径、大小、类别、风险和原因都会显示。
2. 可以按类别、风险或路径筛选，也可以批量勾选当前结果。
3. 点击“导出审批文件”，把下载的 `approval-*.json` 路径交给脚本。
4. 默认操作是送入回收站，执行前会再次检查批次编号、文件大小和修改时间；文件发生变化时会停止处理。

```powershell
.\Apply-Approved-Cleanup.cmd -ProjectRoot (Get-Location) -ApprovalFile "C:\path\to\approval-20260912-120000.json"
```

个人资料目录和常见个人文件类型会被策略排除，清理脚本也会再次拒绝它们。高风险大文件需要额外传入 `-AllowHighRisk`；永久删除需要额外传入 `-Permanent`，这两个开关都不会绕过个人资料保护。默认送入回收站不会立即释放全部空间，确认无误后还需要由你决定是否清空回收站。

安全缓存和临时目录会以“目录候选”显示，并附带目录内文件数；普通大文件和构建产物仍按文件逐项显示。

清理完成后脚本会重新生成清单和状态报告。需要更完整的刷新时执行：

```powershell
.\Apply-Approved-Cleanup.cmd -ApprovalFile "C:\path\to\approval.json" -DeepRefresh
```

## 管理员权限

普通权限足以读取大部分磁盘状态。以管理员身份运行可以减少系统目录访问失败，并核验系统还原点；如果权限不足，报告会把该项标为“未核验”，不会假装正常。程序不会因为权限不足而自动提升，也不会静默删除文件。

## 公开仓库安全闸门

提交前先运行：

```powershell
.\scripts\Check-PublicSafe.ps1 -History
```

检查器会验证公开文件是否在允许名单内，扫描工作区和 Git 历史中的私钥、令牌、秘密赋值、当前用户路径、当前用户名、符号链接和生成数据。输出只包含类别、文件名和提交编号，不输出命中的内容。

安装本地自动同步：

```powershell
.\Setup.ps1 -InstallSync
```

它会把 Git hooks 指向 `.githooks/`。每次提交和推送前都会重新执行安全检查；提交后会尝试推送当前分支。自动推送要求 `origin` 指向你有权限写入的仓库。公开仓库发布前，维护者仍应在新环境中复核 `Check-PublicSafe.ps1 -History` 的结果。

## 目录说明

| 路径 | 作用 | 是否会放入真实数据 |
| --- | --- | --- |
| `index.html`、`styles.css`、`app.js` | 本地报告页面 | 否 |
| `scripts/` | Windows 采集、清单、审批、刷新和隐私检查 | 否 |
| `sample/` | 合成演示数据 | 否 |
| `runtime/` | 本机报告、候选清单、审批和历史 | 是，始终忽略 |
| `docs/` | 使用与开发手册 | 否 |

## 设计边界

- 不把真实报告上传到 GitHub。
- 不在浏览器页面中联网；页面的 CSP 禁止外部脚本和网络连接。
- 不移动个人资料。
- 不以文件名相似就删除；每个候选项都需要显式审批，并在执行前重新核验指纹。
- 不以“未核验”代替“正常”。

完整的使用步骤、隐私模型和开发说明分别见 [docs/USER_GUIDE.md](docs/USER_GUIDE.md)、[PRIVACY.md](PRIVACY.md) 和 [docs/DEVELOPMENT.md](docs/DEVELOPMENT.md)。
