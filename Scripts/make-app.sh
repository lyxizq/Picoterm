#!/bin/bash
# 组装 Picoterm.app（自包含 bundle），用法：Scripts/make-app.sh [release]
# 口径（2026-10-25）：产物须能在任意 arm64 + macOS 14+ 的 Mac 上免 Homebrew、免安装运行——
# 非系统动态库（/usr/lib、/System 之外的绝对路径依赖）一律递归收集闭包拷入 Contents/Frameworks
# 并改写为 @rpath。禁止硬编码 Homebrew opt/Cellar 路径：Cellar 路径带版本号随 brew 升级漂移，
# 且 install_name_tool -change 旧路径不匹配时会静默跳过、退出码 0（set -e 拦不住），
# 曾因此 libssl 残留依赖本机 Cellar 路径，发到其他 Mac 启动即崩。
# 末尾自包含校验：bundle 内任一 Mach-O 残留外部绝对依赖 → 构建失败。
set -euo pipefail
cd "$(dirname "$0")/.."

CONFIG="debug"
SWIFT_FLAGS=""
if [ "${1:-}" = "release" ]; then
  CONFIG="release"
  SWIFT_FLAGS="-c release"
fi

swift build $SWIFT_FLAGS

APP="build/Picoterm.app"
FW="$APP/Contents/Frameworks"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$FW"
cp ".build/$CONFIG/Picoterm" "$APP/Contents/MacOS/Picoterm"
cp "Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"

# 绝对路径且不在系统库目录 → 需要打进 bundle；@rpath 等相对引用与系统库不动
needs_bundle() {
  case "$1" in
    /usr/lib/*|/System/*) return 1 ;;
    /*)                   return 0 ;;
    *)                    return 1 ;;
  esac
}

copy_with_closure() {  # $1 = 依赖库的原始安装名（绝对路径）
  local src="$1" base dest sub
  base="$(basename "$src")"
  dest="$FW/$base"
  if [ -f "$dest" ]; then return 0; fi
  cp -L "$src" "$dest"
  chmod u+w "$dest"
  install_name_tool -id "@rpath/$base" "$dest"
  # otool -L 首个数据行是库自身的 install ID，跳过（NR>2）
  while IFS= read -r sub; do
    if needs_bundle "$sub"; then
      copy_with_closure "$sub"
      install_name_tool -change "$sub" "@rpath/$(basename "$sub")" "$dest"
    fi
  done < <(otool -L "$dest" | awk 'NR>2 {print $1}')
}

BIN="$APP/Contents/MacOS/Picoterm"
chmod u+w "$BIN"
while IFS= read -r dep; do
  if needs_bundle "$dep"; then
    copy_with_closure "$dep"
    install_name_tool -change "$dep" "@rpath/$(basename "$dep")" "$BIN"
  fi
done < <(otool -L "$BIN" | awk 'NR>1 {print $1}')
# libssh2 已静态链接（libssh2-spm），bundle 通常无 dylib 可收；rpath 幂等追加
if ! otool -l "$BIN" | grep -q "path @executable_path/../Frameworks"; then
  install_name_tool -add_rpath "@executable_path/../Frameworks" "$BIN"
fi

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>              <string>Picoterm</string>
    <key>CFBundleDisplayName</key>       <string>Picoterm</string>
    <key>CFBundleIdentifier</key>        <string>com.lyxizq.picoterm</string>
    <key>CFBundleExecutable</key>        <string>Picoterm</string>
    <key>CFBundleIconFile</key>          <string>AppIcon</string>
    <key>CFBundlePackageType</key>       <string>APPL</string>
    <key>CFBundleShortVersionString</key><string>0.1.0</string>
    <key>CFBundleVersion</key>           <string>1</string>
    <key>LSMinimumSystemVersion</key>    <string>14.0</string>
    <key>NSHighResolutionCapable</key>   <true/>
    <key>NSPrincipalClass</key>          <string>NSApplication</string>
</dict>
</plist>
PLIST

# 自包含校验：bundle 内所有 Mach-O 只允许 @rpath 引用与系统库
fail=0
while IFS= read -r f; do
  while IFS= read -r dep; do
    if needs_bundle "$dep"; then
      echo "自包含校验失败：$f 仍依赖外部路径 $dep" >&2
      fail=1
    fi
  done < <(otool -L "$f" | awk 'NR>1 {print $1}')
done < <(find "$APP/Contents/MacOS" "$FW" -type f)
if [ "$fail" -ne 0 ]; then exit 1; fi

if compgen -G "$FW/*.dylib" > /dev/null; then
  codesign --force --sign - "$FW"/*.dylib >/dev/null 2>&1
fi
codesign --force --sign - "$APP" >/dev/null 2>&1
echo "Built $APP"
