#!/bin/bash
# =============================================================================
# 脚本名称: restore_large_assets.sh
# 功能描述: 本地调试用。把 .large-assets-stash/ 中暂存的大文件按原始相对路径
#           还原回 ios/ 工程目录，使本地 Xcode 能完整构建。
#           CI 环境请使用工作流内置的 Release 下载还原逻辑，而非本脚本。
# 使用方式: ./scripts/restore_large_assets.sh
# =============================================================================
set -euo pipefail

GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; NC='\033[0m'
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
STASH_DIR="$ROOT_DIR/.large-assets-stash"
IOS_DIR="$ROOT_DIR/ios"

if [ ! -d "$STASH_DIR" ]; then
  echo -e "${RED}未找到暂存目录 .large-assets-stash，无需还原。${NC}"
  exit 0
fi

echo -e "${YELLOW}开始从暂存目录还原大文件到工程...${NC}"
count=0
# 遍历暂存目录中的所有文件，按相对路径还原
while IFS= read -r src; do
  rel="${src#$STASH_DIR/}"
  dest="$IOS_DIR/$rel"
  mkdir -p "$(dirname "$dest")"
  # 已存在则跳过，避免覆盖工程内可能更新的文件
  if [ -f "$dest" ]; then
    echo "[跳过] 已存在: $rel"
    continue
  fi
  cp "$src" "$dest"
  count=$((count + 1))
  echo "[还原] $rel"
done < <(find "$STASH_DIR" -type f)

echo -e "${GREEN}还原完成，共恢复 $count 个文件。本地 Xcode 工程已完整。${NC}"
echo -e "${YELLOW}提示: 重新打包提交前，记得再次运行 pack_large_assets.sh 剥离大文件。${NC}"
