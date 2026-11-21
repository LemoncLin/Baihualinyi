#!/bin/bash
# =============================================================================
# 脚本名称: pack_large_assets.sh
# 功能描述: 把超过阈值的大文件从工程中剥离，打包成一个 tar.gz 资产包，并生成
#           带相对路径与 SHA256 校验值的 manifest。
#           - 资产包上传到 GitHub Release（大文件不进 Git，规避 100MB 推送限制）
#           - 工程内大文件被移动到 .large-assets-stash（不进 Git），保留本地副本
#           - CI 通过 release_restore.sh 下载资产包并按 manifest 原位还原
# 使用方式:
#   ./scripts/pack_large_assets.sh              # 默认阈值 45MB，预览+打包
#   SIZE_LIMIT_MB=40 ./scripts/pack_large_assets.sh
# 产物:
#   release-assets/large-assets.tar.gz          上传到 GitHub Release 的资产包
#   release-assets/large-assets.manifest.txt    路径 + SHA256 清单（提交进 Git）
# =============================================================================
set -euo pipefail

GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; NC='\033[0m'
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
IOS_DIR="$ROOT_DIR/ios"
# 阈值（MB），低于 GitHub 100MB 硬限制并预留余量
SIZE_LIMIT_MB="${SIZE_LIMIT_MB:-45}"
SIZE_LIMIT_KB=$((SIZE_LIMIT_MB * 1024))

ASSET_DIR="$ROOT_DIR/release-assets"
STASH_DIR="$ROOT_DIR/.large-assets-stash"
TARBALL="$ASSET_DIR/large-assets.tar.gz"
MANIFEST="$ASSET_DIR/large-assets.manifest.txt"

mkdir -p "$ASSET_DIR"

echo -e "${YELLOW}============ 扫描大于 ${SIZE_LIMIT_MB}MB 的文件 ============${NC}"
# 以 ios/ 为基准生成相对路径清单
cd "$IOS_DIR"
find . -type f -size "+${SIZE_LIMIT_KB}k" | sed 's|^\./||' | sort > "$ASSET_DIR/.large-list.tmp"
COUNT=$(wc -l < "$ASSET_DIR/.large-list.tmp")

if [ "$COUNT" -eq 0 ]; then
  echo -e "${GREEN}没有超过阈值的大文件，无需打包。${NC}"
  rm -f "$ASSET_DIR/.large-list.tmp"
  exit 0
fi

echo "共发现 $COUNT 个大文件:"
while IFS= read -r rel; do
  echo "  - $rel ($(du -h "$rel" | awk '{print $1}'))"
done < "$ASSET_DIR/.large-list.tmp"

# -----------------------------------------------------------------------------
# 1. 生成 manifest：相对路径 + SHA256，供 CI 还原后做完整性校验
# -----------------------------------------------------------------------------
echo -e "${YELLOW}[1/4] 生成 SHA256 校验清单${NC}"
: > "$MANIFEST"
while IFS= read -r rel; do
  hash=$(shasum -a 256 "$rel" 2>/dev/null | awk '{print $1}' || sha256sum "$rel" | awk '{print $1}')
  echo "$hash  $rel" >> "$MANIFEST"
done < "$ASSET_DIR/.large-list.tmp"
echo "清单已写入: ${MANIFEST#$ROOT_DIR/}"

# -----------------------------------------------------------------------------
# 2. 打包（保持相对路径，解压即可原位还原）
# -----------------------------------------------------------------------------
echo -e "${YELLOW}[2/4] 打包 tar.gz（体积较大，请耐心等待）${NC}"
tar -czf "$TARBALL" -T "$ASSET_DIR/.large-list.tmp"
ls -lh "$TARBALL" | awk '{print "资产包体积:", $5}'

# -----------------------------------------------------------------------------
# 3. 把大文件从工程移到 stash 目录（保留本地副本，但不进 Git）
#    用 mv 而非删除，原始数据仍在本机；ios.rar 也是额外兜底
# -----------------------------------------------------------------------------
echo -e "${YELLOW}[3/4] 将大文件移出工程目录到 .large-assets-stash/${NC}"
while IFS= read -r rel; do
  mkdir -p "$STASH_DIR/$(dirname "$rel")"
  mv "$IOS_DIR/$rel" "$STASH_DIR/$rel"
done < "$ASSET_DIR/.large-list.tmp"

# -----------------------------------------------------------------------------
# 4. 输出后续操作提示
# -----------------------------------------------------------------------------
rm -f "$ASSET_DIR/.large-list.tmp"
echo -e "${YELLOW}[4/4] 完成${NC}"
cat <<EOF

${GREEN}================ 下一步操作 ================${NC}
1) 资产包已生成: release-assets/large-assets.tar.gz
2) 把该资产包上传到 GitHub Release（资产名必须为 large-assets.tar.gz）:
   - 方式A（网页）: 仓库 Releases → Draft a new release → 拖入 tar.gz
   - 方式B（命令）: gh release create v1.0-assets \\
       release-assets/large-assets.tar.gz \\
       --title "大文件资产包" --notes "CI 构建依赖的视频/大图资源"
3) 提交清单文件 large-assets.manifest.txt 到 Git（tar.gz 本身不要提交）
4) 推送到 GitHub 后手动触发 Actions 工作流，CI 会自动下载并还原这些文件

本地被移走的文件保存在 .large-assets-stash/，需要本地 Xcode 调试时可运行:
  ./scripts/restore_large_assets.sh
EOF
