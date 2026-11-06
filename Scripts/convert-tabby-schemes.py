#!/usr/bin/env python3
"""把 Tabby 社区配色（Xresources 文本，191 套）转换成 Picoterm 的 TerminalTheme JSON，
嵌进 Sources/Picoterm/Store/CommunityColorSchemes.swift 的字符串字面量（不用 SPM resources：
Bundle.module 在 make-app 组出的 .app 里找不到资源包会直接 fatalError，字面量最稳）。

用法：python3 Scripts/convert-tabby-schemes.py
输入：.reference/tabby/tabby-community-color-schemes/schemes/*（MIT；配色源自 iTerm2-Color-Schemes，MIT）
派生：selection = 前景色 30% 叠在背景色上；isDark = 背景感知亮度 < 0.5；同色板去重（保留字母序靠前者）
"""
import json
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SCHEMES_DIR = os.path.join(ROOT, ".reference", "tabby", "tabby-community-color-schemes", "schemes")
OUTPUT = os.path.join(ROOT, "Sources", "Picoterm", "Store", "CommunityColorSchemes.swift")

HEX = re.compile(r"^#[0-9a-fA-F]{6}$")


def parse(path):
    variables = {}
    values = {}
    with open(path, encoding="utf-8", errors="replace") as f:
        for raw in f:
            line = raw.strip()
            if line.startswith("#define"):
                parts = line.split()
                if len(parts) >= 3:
                    variables[parts[1]] = parts[2]
            elif line.startswith("*."):
                key, sep, value = line[2:].partition(":")
                if not sep:  # 上游个别文件漏了冒号（Melange Dark），按空白切
                    key, _, value = line[2:].partition(" ")
                value = value.strip()
                values[key.strip()] = variables.get(value, value)
    return values


def to_rgb(h):
    return tuple(int(h[i:i + 2], 16) for i in (1, 3, 5))


def to_hex(rgb):
    return "#%02x%02x%02x" % rgb


def blend(fg, bg, alpha):
    return tuple(round(f * alpha + b * (1 - alpha)) for f, b in zip(fg, bg))


def luminance(rgb):
    r, g, b = (c / 255 for c in rgb)
    return 0.2126 * r + 0.7152 * g + 0.0722 * b


def slug(name):
    return re.sub(r"[^a-z0-9]+", "-", name.lower()).strip("-")


def main():
    if not os.path.isdir(SCHEMES_DIR):
        sys.exit(f"schemes dir missing: {SCHEMES_DIR}")
    themes = []
    seen = {}
    skipped = []
    for name in sorted(os.listdir(SCHEMES_DIR)):
        if name.startswith("."):
            continue
        values = parse(os.path.join(SCHEMES_DIR, name))
        fg, bg = values.get("foreground"), values.get("background")
        colors = [values.get(f"color{i}") for i in range(16)]
        if not (fg and bg and all(colors)) or not all(HEX.match(c) for c in [fg, bg] + colors):
            skipped.append(name)
            continue
        cursor = values.get("cursorColor") if HEX.match(values.get("cursorColor") or "") else fg
        key = (fg.lower(), bg.lower(), tuple(c.lower() for c in colors))
        if key in seen:
            skipped.append(f"{name} (duplicate of {seen[key]})")
            continue
        seen[key] = name
        themes.append({
            "id": "tabby:" + slug(name),
            "name": name,
            "isDark": luminance(to_rgb(bg)) < 0.5,
            "background": bg.lower(),
            "foreground": fg.lower(),
            "cursor": cursor.lower(),
            "selection": to_hex(blend(to_rgb(fg), to_rgb(bg), 0.3)),
            "ansi": [c.lower() for c in colors],
        })

    payload = json.dumps(themes, ensure_ascii=False, separators=(",", ":"), indent=None)
    # 每个主题一行，便于 diff
    payload = payload.replace("},{", "},\n{")
    swift = f'''// 由 Scripts/convert-tabby-schemes.py 生成——勿手改，重跑脚本即可。
// 来源：Tabby tabby-community-color-schemes/schemes（MIT，Portions copyright Tabby Developers）；
// 配色本体源自 iTerm2-Color-Schemes（Mark Badolato，MIT）。共 {len(themes)} 套（原始 {len(themes) + len(skipped)} 个文件，
// 去掉 {len(skipped)} 个重复/不完整）。selection/isDark 为派生值（见脚本）。
enum CommunityColorSchemes {{
    static let json = #"""
{payload}
"""#
}}
'''
    with open(OUTPUT, "w", encoding="utf-8") as f:
        f.write(swift)
    print(f"wrote {len(themes)} themes to {os.path.relpath(OUTPUT, ROOT)}")
    for s in skipped:
        print(f"  skipped: {s}")


if __name__ == "__main__":
    main()
