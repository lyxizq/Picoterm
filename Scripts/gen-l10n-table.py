#!/usr/bin/env python3
"""生成 Sources/PicotermCore/L10nEn.swift。

流程：扫描源码里所有 L("…") 的中文键 → 与 Scripts/l10n-en.json 的译文合并 →
校验覆盖（缺译/失效条目各打一份清单）→ 重新生成 Swift 表。
键以「Swift 字面量转义后的明文」对齐：源码里的 \n、\" 等转义先还原成真实字符，
与 JSON 里的键比较，生成时再转义回 Swift 字面量。
"""
import json
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SRC_DIRS = [ROOT / "Sources" / "Picoterm", ROOT / "Sources" / "PicotermCore",
            ROOT / "Tests" / "PicotermCoreTests"]
OUT = ROOT / "Sources" / "PicotermCore" / "L10nEn.swift"
PAIRS = ROOT / "Scripts" / "l10n-en.json"

# Swift 字面量：反斜杠转义还原
UNESCAPE = {
    "n": "\n", "t": "\t", "r": "\r", '"': '"', "\\": "\\", "0": "\0",
}

def unescape(literal: str) -> str:
    out, i = [], 0
    while i < len(literal):
        c = literal[i]
        if c == "\\" and i + 1 < len(literal):
            nxt = literal[i + 1]
            if nxt == "u":
                end = literal.index("}", i)
                out.append(chr(int(literal[i + 2:end], 16)))
                i = end + 1
                continue
            out.append(UNESCAPE.get(nxt, nxt))
            i += 2
        else:
            out.append(c)
            i += 1
    return "".join(out)

def escape(text: str) -> str:
    return (text.replace("\\", "\\\\").replace('"', '\\"')
                .replace("\n", "\\n").replace("\t", "\\t").replace("\r", "\\r"))

# L( 后紧跟（仅空格/tab）的字符串字面量第一参数
CALL_RE = re.compile(r'\bL\([ \t]*"((?:[^"\\\n]|\\.)*)"')

# 经变量传入 L() 的运行时键（源码里不是字面量，提取不到；按出处人工登记）
RUNTIME_KEYS = {
    # FilePanelView.FilePropertiesView：typeText 参与 == 比较，显示处 L(typeText)
    "文件夹", "符号链接", "文件", "特别的",
}

def extract_keys() -> dict[str, int]:
    keys: dict[str, int] = {k: 1 for k in RUNTIME_KEYS}
    for d in SRC_DIRS:
        for f in sorted(d.rglob("*.swift")):
            if f == OUT:  # 生成文件自身的注释里有 L("…") 示例
                continue
            for m in CALL_RE.finditer(f.read_text(encoding="utf-8")):
                keys[unescape(m.group(1))] = keys.get(unescape(m.group(1)), 0) + 1
    # 单测里故意用的缺译键（验证回退与 format 展开），不计入缺译
    for test_only in ("此键不存在于表中的文案", "字号 %.1f pt"):
        keys.pop(test_only, None)
    return keys

# L10nEn.swift 现有条目（保留既有译文，避免反复重灌）
EXISTING_RE = re.compile(r'^\s*"((?:[^"\\]|\\.)*)"\s*:\s*"((?:[^"\\]|\\.)*)",?\s*$')

def existing_pairs() -> dict[str, str]:
    out = {}
    if not OUT.exists():
        return out
    for line in OUT.read_text(encoding="utf-8").splitlines():
        m = EXISTING_RE.match(line)
        if m:
            out[unescape(m.group(1))] = unescape(m.group(2))
    return out

def main() -> int:
    keys = extract_keys()
    # 纯 ASCII 键（如 "[picoterm] %@\r\n" 这类无中文的格式壳）无需翻译：不计缺译、不入表
    keys = {k: n for k, n in keys.items() if not k.isascii()}
    pairs = existing_pairs()
    if PAIRS.exists():
        pairs.update(json.loads(PAIRS.read_text(encoding="utf-8")))

    missing = sorted(k for k in keys if k not in pairs)
    stale = sorted(k for k in pairs if k not in keys)
    if missing:
        print(f"缺译文 {len(missing)} 条：")
        for k in missing:
            print(f"  {k!r}")
    if stale:
        print(f"失效条目 {len(stale)} 条（源码已无此键，不写入）：")
        for k in stale:
            print(f"  {k!r}")

    lines = [
        "// 英文译文表（键 = 中文原文，与各调用点 L(\"…\") 的键严格一致）。",
        "// 由 Scripts/gen-l10n-table.py 生成：译文维护在 Scripts/l10n-en.json，",
        "// 改完文案跑 `python3 Scripts/gen-l10n-table.py` 重新生成；缺译条目键回退中文原文。",
        "public enum L10nEn {",
        "    public static let table: [String: String] = [",
    ]
    for k in sorted(pairs):
        if k in keys and pairs[k]:
            lines.append(f'        "{escape(k)}": "{escape(pairs[k])}",')
    lines += [
        "    ]",
        "}",
        "",
    ]
    OUT.write_text("\n".join(lines), encoding="utf-8")
    print(f"写入 {OUT.relative_to(ROOT)}：{sum(1 for k in pairs if k in keys and pairs[k])} 条"
          f"（源码键 {len(keys)}，缺译 {len(missing)}）")
    return 1 if missing else 0

if __name__ == "__main__":
    sys.exit(main())
