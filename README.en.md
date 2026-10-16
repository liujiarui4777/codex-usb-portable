# Codex Portable · Windows USB drive

**Put a full Codex on a USB stick.** Plug it into any 64-bit Windows 10/11 machine and double-click.
Your config, API key and session history travel with the drive; the host PC installs
**no runtime** and keeps only a removable local cache.

![Platform](https://img.shields.io/badge/platform-Windows%2010%2F11%20x64-0078D6?logo=windows&logoColor=white)
![PowerShell](https://img.shields.io/badge/PowerShell-5.1%2B-5391FE?logo=powershell&logoColor=white)
![License](https://img.shields.io/badge/license-MIT-green)
![Binaries](https://img.shields.io/badge/binaries-not%20included-orange)

[中文](README.md) · [English](README.en.md)

---

## How it works

    +----------------------------+          +-------------------------------+
    |   USB drive (portable)     |          |   Host PC (leaves nothing)    |
    |                            |          |                               |
    |  CodexHome/                |  once    |  ~2 GB cache under the user   |
    |    config, key shards,     | -------> |  profile (one-click cleanup)  |
    |    session history         |          |                               |
    |  _internal/ codex/ node/   |  run     |  desktop GUI / terminal /     |
    |    the programs            | -------> |  browser UI                   |
    +----------------------------+          +-------------------------------+

Three entries, pick per situation: **desktop GUI** (5-15 s after the first cache),
**terminal** (2-3 s), **browser UI** (3-5 s).

## Quick start

    git clone https://github.com/liujiarui4777/codex-usb-portable.git E:\codex-usb-portable

1. Double-click `setup\一键装配.cmd` — it downloads all components from their official
   upstream releases (~1.5 GB) and puts them in place, then self-checks.
   For a tiny install (terminal only, ~160 MB): `setup.ps1 -Minimal`
2. Double-click `CodexHome\设置API密钥.cmd` to store your API key
   (or run `codex login` once and use an official account instead).
3. Double-click `【Windows】启动 Codex(桌面版).cmd`.

## What this repo deliberately does NOT contain

| Not included | Why |
|---|---|
| **Any third-party binary** | The desktop build is ~1.9 GB / 7000+ files and a single exe exceeds GitHub's 100 MB file limit; redistributing Codex or upstream repacks would not be compliant. The setup script pulls them from upstream on demand instead. |
| **Any key, credential or chat history** | No key appears in the source; shards (`*.dat`), `auth.json`, `sessions/` and logs are excluded by `.gitignore`. The history is a clean snapshot. |

## Security

The API key is never stored in clear text: it is split into 3 shards, each obfuscated and
Base64-encoded, restored in memory at launch and written to `auth.json` only for that session.
**This is obfuscation, not encryption** — anyone with physical access can still recover it,
so use a revocable, low-limit key, or enable BitLocker To Go on the drive.
The launchers redirect `APPDATA` / `LOCALAPPDATA` into their own cache directory so they never
touch the Codex config already installed on the host, and nothing is ever uploaded anywhere.

Chinese documentation: [docs/](docs/) · Licensed MIT (scripts and docs only) ·
Not affiliated with OpenAI or any upstream project.
