#!/bin/bash
# =============================================================================
# 脚本名称: diagnose_p12.sh
# 功能描述: 当 verify_p12.sh 报"密码错误"但确信密码正确时，用本脚本深入排查：
#             1) 检查输入的密码是否含全角字符、首尾空格等输入问题
#             2) 显示 openssl 的真实报错（区分密码错 vs 加密算法不支持）
#             3) 分别用默认模式与 -legacy 兼容模式尝试打开
#             4) 用文件方式传密码，排除特殊字符被 shell 解释的可能
# 安全说明: 密码静默读取，仅输出长度/是否含非ASCII等元信息，绝不回显明文。
# =============================================================================
set -uo pipefail

GREEN='\033[0;32m'; RED='\033[0;31m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
P12="$ROOT_DIR/证书/分发证书.p12"

[ -f "$P12" ] || { echo -e "${RED}未找到 $P12${NC}"; exit 1; }

echo -e "${CYAN}============ .p12 打开失败诊断 ============${NC}"
read -rsp "请输入 .p12 导出密码（输入时不显示，建议手动敲入勿粘贴）: " P12_PASS
echo
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# -----------------------------------------------------------------------------
# 1. 输入质量检查（不回显明文，只看元信息）
# -----------------------------------------------------------------------------
echo -e "${YELLOW}==> [1] 输入质量检查${NC}"
CHAR_COUNT=${#P12_PASS}
BYTE_COUNT=$(printf '%s' "$P12_PASS" | wc -c | tr -d ' ')
echo "    字符长度: $CHAR_COUNT    字节长度: $BYTE_COUNT"
# 含中文/全角时字节数会明显大于字符数
if [ "$BYTE_COUNT" -ne "$CHAR_COUNT" ]; then
  echo -e "${RED}    [!] 字节数 ≠ 字符数，密码中可能含中文或全角字符（常见于中文输入法）${NC}"
fi
# 首尾空白检查
case "$P12_PASS" in
  [[:space:]]*|[[:space:]]*) echo -e "${RED}    [!] 密码首尾含有空格/制表符，多半是粘贴带入的${NC}" ;;
  *) echo "    首尾无空白字符" ;;
esac
# 非 ASCII 字符检查
if printf '%s' "$P12_PASS" | LC_ALL=C grep -q '[^[:print:]]'; then
  echo -e "${RED}    [!] 含不可打印或非 ASCII 字符，请切换英文输入法重新敲入${NC}"
else
  echo "    全部为 ASCII 可打印字符"
fi

# 把密码写入临时文件（仅当前用户可读，用完即删），用于文件方式传参
umask 077
printf '%s' "$P12_PASS" > "$WORK/pass.txt"

# -----------------------------------------------------------------------------
# 2. 多种方式尝试，显示 openssl 真实报错
# -----------------------------------------------------------------------------
echo
echo -e "${YELLOW}==> [2] 尝试用不同方式打开（显示真实报错）${NC}"

run_try() {
  local label="$1"; shift
  echo -e "${CYAN}--- $label ---${NC}"
  if "$@" 2>"$WORK/err.txt"; then
    echo -e "${GREEN}    成功！该方式可打开 .p12${NC}"
    return 0
  else
    echo -e "${RED}    失败，openssl 原始报错:${NC}"
    sed 's/^/      /' "$WORK/err.txt"
    return 1
  fi
}

OK=0
# 方式A：默认算法 + 环境变量传密码（避免特殊字符问题）
if P12PASS="$P12_PASS" run_try "A. 默认模式 + 环境变量传密码" \
   openssl pkcs12 -in "$P12" -nokeys -passin env:P12PASS -out "$WORK/a.pem"; then OK=1; fi

# 方式B：legacy 兼容模式（openssl 3.x 遇到 RC2/旧算法时需要）
if P12PASS="$P12_PASS" run_try "B. -legacy 兼容模式 + 环境变量传密码" \
   openssl pkcs12 -legacy -in "$P12" -nokeys -passin env:P12PASS -out "$WORK/b.pem"; then OK=1; fi

# 方式C：文件方式传密码（彻底排除 shell 特殊字符解释）
if run_try "C. 默认模式 + 文件传密码" \
   openssl pkcs12 -in "$P12" -nokeys -passin "file:$WORK/pass.txt" -out "$WORK/c.pem"; then OK=1; fi

# 方式D：legacy + 文件传密码
if run_try "D. -legacy 兼容模式 + 文件传密码" \
   openssl pkcs12 -legacy -in "$P12" -nokeys -passin "file:$WORK/pass.txt" -out "$WORK/d.pem"; then OK=1; fi

# -----------------------------------------------------------------------------
# 3. 结论与建议
# -----------------------------------------------------------------------------
echo
echo -e "${YELLOW}==> [3] 诊断结论${NC}"
if [ "$OK" -eq 1 ]; then
  echo -e "${GREEN}密码本身正确，问题出在算法兼容或传参方式，CI 用的 import_certificate.sh${NC}"
  echo -e "${GREEN}在 macOS 自带版本上通常不受影响；本脚本已确认 .p12 可用。${NC}"
else
  echo -e "${RED}四种方式全部失败，基本可判定为密码不匹配，而非算法问题。${NC}"
  cat <<'TIP'
    常见原因与处理：
    1) macOS 导出 .p12 时会先后问两个密码：
       - 第一个「.p12 密码」= 你给文件设的密码（CI 要用的就是它）
       - 第二个「登录钥匙串密码」= 你 Mac 的开机/登录密码（仅用于授权导出）
       两者容易搞混，请确认你输入的是第一个。
    2) 若仍不确定，最省事的办法：重新导出一次 .p12，
       导出时把密码设为纯字母数字（如 Baihualin2026），避免特殊字符和中文输入法。
    3) 重新导出后放回 证书/分发证书.p12，再跑 ./scripts/verify_p12.sh
TIP
fi
