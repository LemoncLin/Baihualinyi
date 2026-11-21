#!/bin/bash
# =============================================================================
# 脚本名称: make_secrets.sh
# 功能描述: 在本地(macOS/Linux)把 iOS 签名材料转换成可粘贴到 GitHub Secrets 的
#           Base64 字符串，并进行校验。GitHub Secrets 只接受文本，因此二进制
#           的 .p12 / .mobileprovision 需要先 Base64 编码。
# 使用方式:
#   ./scripts/make_secrets.sh /路径/证书.p12 /路径/描述文件.mobileprovision
# 注意事项:
#   - 输出内容包含敏感信息，请勿截图外发或提交到仓库。
#   - 生成后按 README 指引粘贴到仓库 Settings → Secrets。
# =============================================================================
set -euo pipefail

# 颜色定义，用于终端高亮提示
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'

if [ "$#" -lt 2 ]; then
  echo -e "${RED}用法错误${NC}: $0 <distribution.p12> <profile.mobileprovision>"
  exit 1
fi

P12_FILE="$1"
PP_FILE="$2"

# -----------------------------------------------------------------------------
# 文件存在性校验
# -----------------------------------------------------------------------------
for f in "$P12_FILE" "$PP_FILE"; do
  if [ ! -f "$f" ]; then
    echo -e "${RED}文件不存在: $f${NC}"
    exit 1
  fi
done

echo -e "${YELLOW}============================================================${NC}"
echo "  iOS 签名材料 Base64 生成工具"
echo -e "${YELLOW}============================================================${NC}"

# -----------------------------------------------------------------------------
# 1. 处理 .p12 证书
# -----------------------------------------------------------------------------
echo
echo -e "${GREEN}[1/2] 发布证书 (.p12)${NC}"
echo "源文件: $P12_FILE"
echo "对应 Secret 名称: BUILD_CERTIFICATE_BASE64"
echo "-------------------------------- 复制以下内容 ------------------------------"
# -i 禁用换行，保证是单行字符串，适合粘贴到 Secret
base64 -i "$P12_FILE" 2>/dev/null || base64 -w 0 "$P12_FILE"
echo
echo "----------------------------------------------------------------------------"

# -----------------------------------------------------------------------------
# 2. 处理 .mobileprovision 描述文件
#    同时解析出名称/UUID/TeamID，方便核对并填写 ExportOptions.plist
# -----------------------------------------------------------------------------
echo
echo -e "${GREEN}[2/2] 描述文件 (.mobileprovision)${NC}"
echo "源文件: $PP_FILE"
echo "对应 Secret 名称: PROVISION_PROFILE_BASE64"
echo "-------------------------------- 复制以下内容 ------------------------------"
base64 -i "$PP_FILE" 2>/dev/null || base64 -w 0 "$PP_FILE"
echo
echo "----------------------------------------------------------------------------"

# macOS 下进一步解析描述文件详情；Linux 无 security 命令则跳过
if command -v security >/dev/null 2>&1; then
  TMP_PLIST="$(mktemp)"
  security cms -D -i "$PP_FILE" > "$TMP_PLIST"
  echo
  echo -e "${GREEN}描述文件详情（用于核对配置）:${NC}"
  echo "  Name（名称，填到 ExportOptions.plist）: $(/usr/libexec/PlistBuddy -c 'Print Name' "$TMP_PLIST")"
  echo "  UUID: $(/usr/libexec/PlistBuddy -c 'Print UUID' "$TMP_PLIST")"
  echo "  TeamIdentifier: $(/usr/libexec/PlistBuddy -c 'Print TeamIdentifier:0' "$TMP_PLIST")"
  echo "  App ID: $(/usr/libexec/PlistBuddy -c 'Print Entitlements:application-identifier' "$TMP_PLIST")"
  rm -f "$TMP_PLIST"
else
  echo
  echo -e "${YELLOW}当前为 Linux 环境，无法解析描述文件详情，请在 macOS 上核对名称。${NC}"
fi

echo
echo -e "${YELLOW}还需在 GitHub Secrets 中另外配置:${NC}"
echo "  P12_PASSWORD                 .p12 的导出密码"
echo "  APP_STORE_CONNECT_API_KEY    App Store Connect API 私钥(.p8)文本内容"
echo "  APP_STORE_CONNECT_KEY_ID     密钥 Key ID"
echo "  APP_STORE_CONNECT_ISSUER_ID  Issuer ID"
echo
echo -e "${GREEN}完成。请按 README 指引逐项粘贴，切勿将明文材料提交到仓库。${NC}"
