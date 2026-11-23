#!/bin/bash
# =============================================================================
# 脚本名称: update_from_rar.sh
# 功能描述: 【二次及以后版本更新专用】拿到新的 ios.rar 后，一条命令把仓库更新到
#           "可推送、可触发 CI" 的状态。串联以下动作：
#             1) 备份当前 ios/ 与旧资产包（可回滚）
#             2) 从新 rar 仅提取 ios/ 工程到临时目录并校验
#             3) 清理死代码（旧版全景目录 / krpano 工具残留）
#             4) 重新剥离 >45MB 大文件，生成新 tar.gz 与 SHA256 清单
#             5) 输出人工待办（提交、传 Release、触发工作流）
# 使用方式:
#   ./scripts/update_from_rar.sh [新压缩包路径]      # 默认 ./ios.rar
# 注意    : 本脚本不自动 git commit/push，也不自动覆盖 Release，
#           这些动作留给你确认后执行，避免误发布。
# =============================================================================
set -euo pipefail

GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; NC='\033[0m'
info()  { echo -e "${GREEN}[INFO]${NC} $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*" >&2; }

# WSL 挂载 NTFS(/mnt 下 drvfs) 时，目录刚创建就 mv 偶发 "Permission denied"，
# 这是文件系统元数据尚未稳定的瞬时错误。封装带重试的 mv 提升健壮性。
# 用法: robust_mv <源> <目标>
robust_mv() {
  local src="$1" dst="$2" attempt
  for attempt in 1 2 3 4 5; do
    if mv "$src" "$dst" 2>/dev/null; then
      return 0
    fi
    warn "mv 失败(第 ${attempt} 次)，2 秒后重试: $src -> $dst"
    sleep 2
  done
  error "mv 连续 5 次失败: $src -> $dst"
  return 1
}

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ARCHIVE="${1:-$ROOT_DIR/ios.rar}"
SCRIPTS="$ROOT_DIR/scripts"
STAMP="$(date +%Y%m%d%H%M%S)"
BACKUP_DIR="$ROOT_DIR/.update-backup/$STAMP"

[ -f "$ARCHIVE" ] || { error "压缩包不存在: $ARCHIVE"; exit 1; }
command -v unrar >/dev/null 2>&1 || command -v unar >/dev/null 2>&1 \
  || { error "未找到 unrar/unar 解压工具"; exit 1; }

# -----------------------------------------------------------------------------
# 0. 工作区干净度检查：避免把未提交改动覆盖丢失
# -----------------------------------------------------------------------------
cd "$ROOT_DIR"
if [ -n "$(git status --porcelain 2>/dev/null)" ]; then
  warn "当前 Git 工作区有未提交改动，建议先 commit/stash 再更新。"
  read -rp "仍要继续吗？(y/N): " ans
  [ "$ans" = "y" ] || [ "$ans" = "Y" ] || { info "已取消"; exit 0; }
fi

mkdir -p "$BACKUP_DIR"
info "备份目录: $BACKUP_DIR"

# -----------------------------------------------------------------------------
# 1. 备份当前 ios/ 与旧资产包（仅当存在时）
# -----------------------------------------------------------------------------
[ -d "$ROOT_DIR/ios" ] && { info "备份当前 ios/ ..."; robust_mv "$ROOT_DIR/ios" "$BACKUP_DIR/ios"; }
[ -f "$ROOT_DIR/release-assets/large-assets.tar.gz" ] && \
  cp "$ROOT_DIR/release-assets/large-assets.tar.gz" "$BACKUP_DIR/large-assets.tar.gz"

# -----------------------------------------------------------------------------
# 2. 从新 rar 提取 ios/ 工程（复用 setup_project.sh 的定位逻辑，这里独立实现以便控错）
# -----------------------------------------------------------------------------
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
info "解压新压缩包（仅 ios/ 目录）..."
if command -v unrar >/dev/null 2>&1; then
  unrar x -o+ "$ARCHIVE" "ios/*" "$WORK/" >/dev/null
else
  unar -force-overwrite -output-directory "$WORK" "$ARCHIVE" >/dev/null
fi

NEW_IOS="$(find "$WORK" -maxdepth 3 -type d -name ios | head -1)"
[ -n "$NEW_IOS" ] || { error "压缩包内未找到 ios/ 目录，已保留备份，可回滚"; exit 1; }
[ -d "$NEW_IOS/App/App.xcodeproj" ] || { error "未找到 App.xcodeproj，工程结构异常"; exit 1; }
robust_mv "$NEW_IOS" "$ROOT_DIR/ios"
info "新工程已就位"

# -----------------------------------------------------------------------------
# 3. 关键：确保 Bundle ID 与签名相关配置不被新包覆盖回旧值
#    新 rar 若仍带 com.baihualin.yi，这里强制纠正为本项目的发布 ID
# -----------------------------------------------------------------------------
PBX="$ROOT_DIR/ios/App/App.xcodeproj/project.pbxproj"
CAP="$ROOT_DIR/ios/App/App/capacitor.config.json"
OLD_ID="com.baihualin.yi"; NEW_ID="com.megmt.baihualinyi"
if grep -q "$OLD_ID" "$PBX" "$CAP" 2>/dev/null; then
  warn "新工程含旧 Bundle ID，自动纠正为 $NEW_ID"
  sed -i "s/$OLD_ID/$NEW_ID/g" "$PBX" "$CAP"
fi
info "当前 Bundle ID: $(grep -m1 PRODUCT_BUNDLE_IDENTIFIER "$PBX" | sed 's/.*= //;s/;//')"

# Capacitor 默认 .gitignore 会排除 public，确保放开（资源固定需入库）
GI="$ROOT_DIR/ios/.gitignore"
if grep -q "^App/App/public$" "$GI" 2>/dev/null; then
  warn "检测到 Capacitor 默认忽略 public，已自动放开"
  sed -i 's|^App/App/public$|# App/App/public  # 本项目资源固定，需入库|' "$GI"
fi

# -----------------------------------------------------------------------------
# 4. 清理死代码（自动应用，规则与首次一致，可在 cleanup-manifest.log 追溯）
# -----------------------------------------------------------------------------
info "清理死代码 ..."
bash "$SCRIPTS/cleanup_deadcode.sh" --apply >/dev/null 2>&1 || true

# -----------------------------------------------------------------------------
# 5. 重新剥离大文件并生成资产包 + 清单
# -----------------------------------------------------------------------------
info "重新打包大文件资产 ..."
bash "$SCRIPTS/pack_large_assets.sh"

# -----------------------------------------------------------------------------
# 6. 汇总与人工待办
# -----------------------------------------------------------------------------
echo
echo -e "${GREEN}================ 本地更新完成 ================${NC}"
echo "备份位置(可回滚): $BACKUP_DIR"
echo "工程体积: $(du -sh "$ROOT_DIR/ios" | awk '{print $1}')"
echo "新资产包: $(ls -lh "$ROOT_DIR/release-assets/large-assets.tar.gz" | awk '{print $5}')"
cat <<'TIP'

接下来需要你手动确认并执行：
  1) 检查改动：git status
  2) 提交代码（含新的 large-assets.manifest.txt）：
       git add -A && git commit -m "release: 版本更新（资源/工程同步）" && git push
  3) 用新的 release-assets/large-assets.tar.gz 覆盖 Release(v1.0-assets) 资产：
       仓库 Releases → v1.0-assets → Edit → 删除旧 tar.gz → 拖入新文件 → Update release
  4) 到 Actions 手动触发「构建并上传 TestFlight」（不勾 skip_upload 即正式上传）

如需回滚：把备份目录里的 ios/ 移回根目录即可。
TIP
