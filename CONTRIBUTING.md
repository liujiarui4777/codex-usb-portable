# 参与贡献

欢迎提 Issue 和 PR。这个项目很小，规则也简单，但有一条是**硬要求**。

## ⛔ 绝对不能提交的东西

提 PR 之前请自查一遍，**这类东西一旦提交进 Git 历史就很难彻底清除**：

- **任何密钥、令牌、API Key**（包括看起来"混淆过"的分片文件 `*.dat`、`auth.json`）
- **任何会话记录、对话历史、日志**（`sessions/`、`archived_sessions/`、`*.sqlite`、`*.log`）
- **任何第三方二进制**（Codex 本体、Node、Python、pandoc…）—— 体积大且不合规
- **任何个人路径 / 机器名 / 用户名**（写文档、写脚本时请用占位符）

`.gitignore` 已经把这些排除掉了，但请不要依赖它 —— 提交前扫一眼 `git status`。

## 怎么改

1. Fork → 新建分支 → 改 → PR。
2. 改 `.ps1` 时：
   - 必须存成 **UTF-8 with BOM**（否则在 Windows PowerShell 5.1 下中文会变乱码、报语法错）
   - 用 **Windows PowerShell 5.1** 做语法检查：
     `$e=$null; [void][System.Management.Automation.Language.Parser]::ParseFile($p,[ref]$null,[ref]$e); $e`
3. 改 `.cmd` 时：**内容保持纯 ASCII**（中文提示交给 .ps1 输出），
   这样英文系统上也不会乱码；文件名可以用中文。
4. 改了启动器逻辑，请顺便更新 `docs/` 里对应的说明。

## 适合上手的贡献

- 在**更多机器**上实测启动耗时，把数据补进 `docs/02-原理与设计.md`
- 浏览器界面入口（`web\launch-web.ps1`）目前**未充分实测**，欢迎验证并反馈
- Mac / Linux 版启动器（思路一样，但脚本要重写）

## 提交信息

一句话说清楚改了什么就行，中英文都可以。
