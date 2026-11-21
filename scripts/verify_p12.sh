#!/bin/bash
# =============================================================================
# 脚本名称: verify_p12.sh
# 功能描述: 在不泄露 .p12 密码的前提下，本地验证导出的发布证书包是否可用。
#           校验三件事：
#             1) 密码能否正确打开 .p12
#             2) .p12 内是否同时包含证书与私钥（CI 签名的必要条件）
#             3) .p12 内证书与描述文件内嵌证书是否为同一把（公钥指纹比对）
# 使用方式: ./scripts/verify_p12.sh
# 说明    : 密码通过 read -s 静默读取，不回显、不写入命令历史、不上传任何地方。
# =============================================================================
set -euo pipefail

GREEN='\033[0;32m'; RED='\033[0;31m'; YELLOW='\033[1;33m'; NC='\033[0m'
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CERT_DIR="$ROOT_DIR/证书"
P12="$CERT_DIR/分发证书.p12"
PP="$CERT_DIR/baihualinyi.mobileprovision"

[ -f "$P12" ] || { echo -e "${RED}未找到 $P12${NC}"; exit 1; }
[ -f "$PP" ]  || { echo -e "${RED}未找到 $PP${NC}"; exit 1; }

# 静默读取密码（不回显）
read -rsp "请输入 .p12 导出密码（输入时不显示）: " P12_PASS
echo
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

echo -e "${YELLOW}==> [1/3] 验证密码并解析 .p12 ...${NC}"
# -nokeys 仅取证书；若密码错误，此步直接失败
if ! openssl pkcs12 -in "$P12" -nokeys -passin "pass:$P12_PASS" \
      -out "$WORK/cert.pem" 2>/dev/null; then
  echo -e "${RED}密码错误或 .p12 已损坏，无法打开。${NC}"
  exit 1
fi
echo -e "${GREEN}密码正确，.p12 可正常打开。${NC}"

echo -e "${YELLOW}==> [2/3] 检查是否包含私钥 ...${NC}"
# -nocerts -nodes 提取私钥；成功即说明私钥存在
if openssl pkcs12 -in "$P12" -nocerts -nodes -passin "pass:$P12_PASS" \
      -out "$WORK/key.pem" 2>/dev/null && [ -s "$WORK/key.pem" ]; then
  echo -e "${GREEN}私钥存在，满足 CI 代码签名条件。${NC}"
else
  echo -e "${RED}未找到私钥！该 .p12 无法用于签名，请在钥匙串中连同私钥重新导出。${NC}"
  exit 1
fi

# 显示证书主题，确认是 Apple Distribution 证书
echo "证书主题:"
openssl x509 -in "$WORK/cert.pem" -noout -subject | sed 's/^/    /'

echo -e "${YELLOW}==> [3/3] 与描述文件内嵌证书比对公钥指纹 ...${NC}"
# 从描述文件解出 plist，再导出其内嵌证书，计算公钥 SHA256
openssl smime -inform DER -verify -in "$PP" -noverify 2>/dev/null > "$WORK/pp.plist"
python3 - "$WORK/pp.plist" "$WORK/pp_cert.der" <<'PY'
import plistlib, sys
d = plistlib.load(open(sys.argv[1], 'rb'))
certs = d.get('DeveloperCertificates', [])
if not certs:
    sys.exit("描述文件中无内嵌证书")
open(sys.argv[2], 'wb').write(certs[0])
PY

# 分别计算两边证书的公钥 SHA256 指纹
P12_FP=$(openssl x509 -in "$WORK/cert.pem" -noout -pubkey \
          | openssl pkey -pubin -outform der 2>/dev/null | sha256sum | awk '{print $1}')
PP_FP=$(openssl x509 -inform DER -in "$WORK/pp_cert.der" -noout -pubkey \
          | openssl pkey -pubin -outform der 2>/dev/null | sha256sum | awk '{print $1}')

echo "  .p12 证书指纹 : $P12_FP"
echo "  描述文件指纹  : $PP_FP"
if [ "$P12_FP" = "$PP_FP" ]; then
  echo -e "${GREEN}指纹一致：.p12 与描述文件配套，可用于 TestFlight 签名。${NC}"
else
  echo -e "${RED}指纹不一致：证书与描述文件不配套，请检查是否用同一把 Distribution 证书生成。${NC}"
  exit 1
fi

echo
echo -e "${GREEN}============ 全部校验通过 ============${NC}"
