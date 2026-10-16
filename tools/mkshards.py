#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
Codex 便携版 · API 密钥分片生成器（跨平台，Python 3.7+）

把 API Key 拆成 3 个混淆分片，写进 U 盘的 CodexHome 目录，
供便携启动器（launch-desktop.ps1 / launch-cli.ps1 / launch-web.ps1）在启动时还原。

算法（必须与启动器一致）：
  1. 把 Key 按 UTF-8 编码后切成 3 段，每段长度 = ceil(n/3)；
  2. 每段各自与掩码循环 XOR，起点都是索引 0；
  3. 每段各自 Base64，分别写入 user-settings.dat / window-layout.dat / cache-index.dat。

用法：
  python mkshards.py -H E:\\CodexHome                 # 交互输入（不回显）
  python mkshards.py -H E:\\CodexHome --key sk-xxxx   # 直接给（会留在命令历史里，慎用）
  python mkshards.py -H ./CodexHome --mask my-secret  # 换自己的掩码（启动器也要跟着改）

注意：这只是混淆，不是加密。能拿到 U 盘的人仍可能还原出密钥。
"""
import argparse
import base64
import getpass
import os
import sys

# Windows 控制台显示中文：让输出编码跟随当前控制台代码页（cp936 / cp437 / 65001）
if sys.platform == "win32":
    try:
        import ctypes
        _cp = ctypes.windll.kernel32.GetConsoleOutputCP() or 936
        sys.stdout.reconfigure(encoding="cp%d" % _cp, errors="replace")
        sys.stderr.reconfigure(encoding="cp%d" % _cp, errors="replace")
    except Exception:
        pass

DEFAULT_MASK = b"codex-portable-2026"
NAMES = ("user-settings.dat", "window-layout.dat", "cache-index.dat")


def make_shards(key: str, mask: bytes):
    data = key.encode("utf-8")
    n = len(data)
    third = (n + 2) // 3
    segs = [data[0:third], data[third:2 * third], data[2 * third:]]
    out = []
    for seg in segs:
        x = bytes(b ^ mask[i % len(mask)] for i, b in enumerate(seg))
        out.append(base64.b64encode(x).decode("ascii"))
    return out


def restore(home: str, mask: bytes) -> str:
    built = ""
    for name in NAMES:
        path = os.path.join(home, name)
        with open(path, "r", encoding="ascii") as f:
            raw = base64.b64decode(f.read().strip())
        built += bytes(b ^ mask[i % len(mask)] for i, b in enumerate(raw)).decode("utf-8")
    return built


def main():
    ap = argparse.ArgumentParser(description="生成 Codex 便携版 API 密钥分片")
    ap.add_argument("-H", "--home", required=True, help="CodexHome 目录（U 盘上的那个）")
    ap.add_argument("--key", help="API Key；不填则交互输入（不回显）")
    ap.add_argument("--mask", default=DEFAULT_MASK.decode(), help="混淆掩码，默认与启动器一致")
    args = ap.parse_args()

    key = args.key or getpass.getpass("请粘贴你的 API Key（输入时不显示）：")
    key = (key or "").strip()
    if len(key) < 8:
        print("[错误] Key 太短或为空，未做任何修改。", file=sys.stderr)
        return 2

    home = os.path.abspath(args.home)
    os.makedirs(home, exist_ok=True)
    mask = args.mask.encode("ascii")

    shards = make_shards(key, mask)
    for name, blob in zip(NAMES, shards):
        with open(os.path.join(home, name), "w", encoding="ascii") as f:
            f.write(blob)
        print("  [写入] %s  (%d 字符)" % (name, len(blob)))

    if restore(home, mask) == key:
        print("\n[成功] 自校验通过：分片能正确还原出密钥。")
    else:
        print("\n[警告] 自校验不一致：请检查掩码是否与启动器一致。", file=sys.stderr)
        return 3
    print("目标目录：%s" % home)
    return 0


if __name__ == "__main__":
    sys.exit(main())
