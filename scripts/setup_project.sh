#!/bin/bash
# =============================================================================
# 脚本名称: setup_project.sh
# 功能描述: 本地一键整理工具。从包含 Xcode 工程的 rar/zip 压缩包中提取 ios/ 目录，
#           剔除无关素材，补齐 CI 工作流所需的脚手架文件，并初始化 Git 仓库。
# 兼容平台: macOS / Linux（Linux 需安装 unrar，macOS 可用 unar 或 unrar）
# 使用方式:
#   ./scripts/setup_project.sh [压缩包路径]
#   不传参数时默认使用当前目录下的 ios.rar
# =============================================================================
set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
info()  { echo -e "${GREEN}[INFO]${NC} $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*" >&2; }

# 脚本所在仓库根目录（兼容从任意路径调用）
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ARCHIVE="${1:-$ROOT_DIR/ios.rar}"
WORK_DIR="$ROOT_DIR/.setup-tmp"

# -----------------------------------------------------------------------------
# 1. 入参校验与解压工具探测
# -----------------------------------------------------------------------------
[ -f "$ARCHIVE" ] || { error "压缩包不存在: $ARCHIVE"; exit 1; }

# 依次尝试可用的解压工具
extract() {
  # $1 = 压缩包, $2 = 目标目录
  if command -v unrar >/dev/null 2>&1; then
    unrar x -o+ "$1" "$2"
  elif command -v unar >/dev/null 2>&1; then
    unar -force-overwrite -output-directory "$2" "$1"
  elif command -v 7z >/dev/null 2>&1; then
    7z x -y -o"$2" "$1"
  else
    error "未找到解压工具，请先安装 unrar / unar / 7z"
    exit 1
  fi
}

info "压缩包: $ARCHIVE"
info "仓库根目录: $ROOT_DIR"

# -----------------------------------------------------------------------------
# 2. 解压到临时目录，只提取 ios/ 工程目录
# -----------------------------------------------------------------------------
rm -rf "$WORK_DIR"
mkdir -p "$WORK_DIR"
info "开始解压（大文件可能耗时数分钟）..."
case "$ARCHIVE" in
  *.rar)
    if command -v unrar >/dev/null 2>&1; then
      unrar x -o+ "$ARCHIVE" "ios/*" "$WORK_DIR/"
    else
      # unar/7z 不支持路径过滤时全量解压，后续只取 ios 目录
      extract "$ARCHIVE" "$WORK_DIR"
    fi
    ;;
  *.zip)
    unzip -o "$ARCHIVE" -d "$WORK_DIR" 'ios/*'
    ;;
  *)
    error "暂不支持的压缩格式: $ARCHIVE（支持 .rar/.zip）"
    exit 1
    ;;
esac

# 兼容压缩包内可能存在的多层目录，定位真正的 ios 目录
EXTRACTED_IOS="$(find "$WORK_DIR" -maxdepth 3 -type d -name ios | head -1)"
[ -n "$EXTRACTED_IOS" ] || { error "压缩包内未找到 ios/ 目录"; exit 1; }
info "定位到工程目录: $EXTRACTED_IOS"

# -----------------------------------------------------------------------------
# 3. 校验关键工程文件是否齐全
# -----------------------------------------------------------------------------
if [ ! -d "$EXTRACTED_IOS/App/App.xcodeproj" ]; then
  error "未找到 App.xcodeproj，工程结构可能已变化，请人工检查"
  exit 1
fi
info "工程结构校验通过"

# -----------------------------------------------------------------------------
# 4. 移动到仓库根目录（若已存在旧 ios 目录则备份）
# -----------------------------------------------------------------------------
if [ -d "$ROOT_DIR/ios" ]; then
  BACKUP="$ROOT_DIR/ios.backup.$(date +%Y%m%d%H%M%S)"
  warn "已存在 ios/ 目录，备份到 $BACKUP"
  mv "$ROOT_DIR/ios" "$BACKUP"
fi
mv "$EXTRACTED_IOS" "$ROOT_DIR/ios"
rm -rf "$WORK_DIR"
info "工程已就位: $ROOT_DIR/ios"

# -----------------------------------------------------------------------------
# 5. 确保脚本可执行权限
# -----------------------------------------------------------------------------
chmod +x "$ROOT_DIR/scripts/"*.sh 2>/dev/null || true

# -----------------------------------------------------------------------------
# 6. 初始化 Git 仓库（如尚未初始化）
# -----------------------------------------------------------------------------
cd "$ROOT_DIR"
if [ ! -d .git ]; then
  git init
  info "已初始化 Git 仓库"
else
  info "已存在 Git 仓库，跳过初始化"
fi

# 统计工程体积，提示是否需要清理大文件
IOS_SIZE="$(du -sh ios | awk '{print $1}')"
cat <<EOF

$(echo -e "${GREEN}================ 整理完成 ================${NC}")
工程目录 : $ROOT_DIR/ios
工程体积 : $IOS_SIZE

下一步:
  1) 打开 scripts/ExportOptions.plist 替换 Team ID 与描述文件名称
  2) 在仓库 Settings → Secrets 配置签名材料（可用 scripts/make_secrets.sh 生成）
  3) 在仓库 Settings → Variables 配置 DEVELOPMENT_TEAM
  4) git add . && git commit && git push 后，到 Actions 手动触发工作流
EOF
