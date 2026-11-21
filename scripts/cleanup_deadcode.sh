#!/bin/bash
# =============================================================================
# 脚本名称: cleanup_deadcode.sh
# 功能描述: 清理经全量引用验证确认无外部依赖的旧版全景目录、krpano 工具残留
#           与系统垃圾文件。删除前先把清单写入日志，便于追溯与恢复。
# 安全兜底: 原始 ios.rar 压缩包仍保留在仓库外，误删可从中重新解压。
# 使用方式: ./scripts/cleanup_deadcode.sh          # 仅预览清单
#           ./scripts/cleanup_deadcode.sh --apply   # 真正执行删除
# =============================================================================
set -euo pipefail

GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; NC='\033[0m'
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BHLY="$ROOT_DIR/ios/App/App/public/bhly"
LOG_FILE="$ROOT_DIR/scripts/cleanup-manifest.log"
APPLY=0

[ "${1:-}" = "--apply" ] && APPLY=1

# 待删除的目录（均已通过 grep 全量引用验证：无外部资源引用）
DEAD_DIRS=(
  # 旧版全景点位，已被「全景点位新」整体替代
  "全景图/全景点位"
  # 全景点位新内部的历史备份，全局零引用
  "全景图/全景点位新/旧版vtour"
  # 第二版 vtour，仅在其他 tour.xml 的注释文字中出现，无真实资源依赖
  "全景图/全景点位新/第二版vtour"
  # 沙盘的历史备份目录，全局零引用
  "全景图/沙盘/vtour旧版"
)

# 待删除的文件匹配模式（工具残留 / 系统垃圾 / 备份文件）
DEAD_FILE_PATTERNS=(
  "*.exe"          # krpano 本地测试服务器，App 运行不需要
  "*.bak_stock"    # 备份残留
  ".DS_Store"      # macOS 目录垃圾
  "Thumbs.db"      # Windows 目录垃圾
)

echo -e "${YELLOW}============ 死代码清理清单（生成时间 $(date '+%Y-%m-%d %H:%M:%S')）============${NC}" | tee "$LOG_FILE"

total_before=$(du -sk "$BHLY" | awk '{print $1}')
removed_count=0

# -----------------------------------------------------------------------------
# 1. 处理待删目录
# -----------------------------------------------------------------------------
for d in "${DEAD_DIRS[@]}"; do
  target="$BHLY/$d"
  if [ -d "$target" ]; then
    size=$(du -sh "$target" | awk '{print $1}')
    echo "[目录] $target  ($size)" | tee -a "$LOG_FILE"
    if [ "$APPLY" -eq 1 ]; then
      rm -rf "$target"
      removed_count=$((removed_count+1))
    fi
  else
    echo "[跳过] 目录不存在: $target" | tee -a "$LOG_FILE"
  fi
done

# -----------------------------------------------------------------------------
# 2. 处理待删文件（按模式全局查找）
# -----------------------------------------------------------------------------
for pat in "${DEAD_FILE_PATTERNS[@]}"; do
  while IFS= read -r f; do
    [ -z "$f" ] && continue
    size=$(du -h "$f" | awk '{print $1}')
    echo "[文件] $f  ($size)" | tee -a "$LOG_FILE"
    if [ "$APPLY" -eq 1 ]; then
      rm -f "$f"
      removed_count=$((removed_count+1))
    fi
  done < <(find "$BHLY" -type f -iname "$pat" 2>/dev/null)
done

total_after=$(du -sk "$BHLY" | awk '{print $1}')
freed_mb=$(( (total_before - total_after) / 1024 ))

echo | tee -a "$LOG_FILE"
echo "清理前总体积: $((total_before/1024)) MB" | tee -a "$LOG_FILE"
echo "清理后总体积: $((total_after/1024)) MB" | tee -a "$LOG_FILE"
echo "释放空间约: ${freed_mb} MB" | tee -a "$LOG_FILE"

if [ "$APPLY" -eq 0 ]; then
  echo -e "${YELLOW}当前为预览模式，未实际删除。确认无误后执行: $0 --apply${NC}"
else
  echo -e "${GREEN}已执行删除，共处理 $removed_count 项。清单见 $LOG_FILE${NC}"
fi
