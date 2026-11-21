#!/bin/bash
# =============================================================================
# 脚本名称: import_certificate.sh
# 功能描述: 在 GitHub Actions 的 macOS Runner 上安装 iOS 发布证书(.p12)与
#           描述文件(.mobileprovision)，并输出供 xcodebuild 使用的签名参数。
# 使用方式: 仅在 CI 环境中由工作流调用，本地一般无需手动执行。
# 环境变量:
#   BUILD_CERTIFICATE_BASE64      Base64 编码后的 .p12 证书内容（GitHub Secret）
#   P12_PASSWORD                  .p12 证书的导出密码（GitHub Secret）
#   PROVISION_PROFILE_BASE64      Base64 编码后的 .mobileprovision 描述文件（GitHub Secret）
#   KEYCHAIN_PASSWORD             临时钥匙串密码（工作流内部生成即可）
# 输出变量:
#   通过写入 $GITHUB_ENV 导出 PROVISIONING_PROFILE_SPECIFIER（描述文件名称/UUID）
# =============================================================================
set -euo pipefail

# -----------------------------------------------------------------------------
# 1. 环境变量校验：缺少任一必需变量立即失败，避免后续步骤出现难以定位的错误
# -----------------------------------------------------------------------------
: "${BUILD_CERTIFICATE_BASE64:?未设置 BUILD_CERTIFICATE_BASE64}"
: "${P12_PASSWORD:?未设置 P12_PASSWORD}"
: "${PROVISION_PROFILE_BASE64:?未设置 PROVISION_PROFILE_BASE64}"

# 临时工作目录，存放解码后的证书与描述文件，任务结束后由 Runner 自动回收
CERT_DIR="${RUNNER_TEMP:-/tmp}/certificates"
mkdir -p "$CERT_DIR"

# 临时钥匙串名称与密码（CI 一次性使用，不影响 Runner 登录钥匙串）
KEYCHAIN_NAME="build.keychain-db"
KEYCHAIN_PASSWORD="${KEYCHAIN_PASSWORD:-ci_temp_password}"
P12_PATH="$CERT_DIR/distribution.p12"
PP_PATH="$CERT_DIR/profile.mobileprovision"

echo "==> [1/5] 解码 Base64 证书与描述文件"
echo "$BUILD_CERTIFICATE_BASE64" | base64 --decode > "$P12_PATH"
echo "$PROVISION_PROFILE_BASE64" | base64 --decode > "$PP_PATH"

# 校验解码结果是否为有效文件，防止 Secret 粘贴错误
file "$P12_PATH" | grep -qi "PKCS\|data" || { echo "证书解码失败"; exit 1; }
file "$PP_PATH" | grep -qi "data" || { echo "描述文件解码失败"; exit 1; }

echo "==> [2/5] 创建临时钥匙串 $KEYCHAIN_NAME"
# 若同名钥匙串已存在则先删除，保证流程幂等
security delete-keychain "$KEYCHAIN_NAME" 2>/dev/null || true
security create-keychain -p "$KEYCHAIN_PASSWORD" "$KEYCHAIN_NAME"
# 设置较长的自动锁定时间，构建过程中避免钥匙串锁定导致签名失败
security set-keychain-settings -lut 21600 "$KEYCHAIN_NAME"
# 将临时钥匙串加入搜索列表
security list-keychains -d user -s "$KEYCHAIN_NAME"

echo "==> [3/5] 导入 .p12 证书到临时钥匙串"
# -T /usr/bin/codesign: 允许 codesign 访问私钥而不弹出授权框
security import "$P12_PATH" \
  -k "$KEYCHAIN_NAME" \
  -P "$P12_PASSWORD" \
  -T /usr/bin/codesign \
  -T /usr/bin/security

# 解锁钥匙串并设置分区列表，避免 xcodebuild 签名时再次要求授权
security unlock-keychain -p "$KEYCHAIN_PASSWORD" "$KEYCHAIN_NAME"
security set-key-partition-list -S apple-tool:,apple: -k "$KEYCHAIN_PASSWORD" "$KEYCHAIN_NAME" >/dev/null

echo "==> [4/5] 安装描述文件到系统目录"
# 描述文件必须放入 ~/Library/MobileDevice/Provisioning Profiles/，
# 文件名需为其 UUID（从描述文件内部读取），Xcode 才能自动识别
mkdir -p "$HOME/Library/MobileDevice/Provisioning Profiles"

# mobileprovision 是 CMS 签名的 plist，用 security cms 解密后提取 UUID 和 Name
PROFILE_PLIST="$CERT_DIR/profile.plist"
security cms -D -i "$PP_PATH" > "$PROFILE_PLIST"
PROFILE_UUID=$(/usr/libexec/PlistBuddy -c "Print UUID" "$PROFILE_PLIST")
PROFILE_NAME=$(/usr/libexec/PlistBuddy -c "Print Name" "$PROFILE_PLIST")
APP_ID=$(/usr/libexec/PlistBuddy -c "Print Entitlements:application-identifier" "$PROFILE_PLIST")

cp "$PP_PATH" "$HOME/Library/MobileDevice/Provisioning Profiles/$PROFILE_UUID.mobileprovision"
echo "    描述文件名称: $PROFILE_NAME"
echo "    描述文件 UUID: $PROFILE_UUID"
echo "    关联 App ID: $APP_ID"

echo "==> [5/5] 导出签名参数到 GitHub 环境变量"
# 后续 xcodebuild 步骤通过这两个变量定位描述文件
echo "PROVISIONING_PROFILE_SPECIFIER=$PROFILE_NAME" >> "$GITHUB_ENV"
echo "PROVISIONING_PROFILE_UUID=$PROFILE_UUID" >> "$GITHUB_ENV"

echo "==> 证书与描述文件安装完成"
