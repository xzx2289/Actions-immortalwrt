#!/bin/bash
# 410 / MSM8916 no-modem build patch for ImmortalWrt/OpenWrt
# 目标：禁用 MPSS/modem 远程处理器，释放 mpss_mem 预留内存；保留 WCNSS Wi-Fi。

set -euo pipefail

OPENWRT_DIR="$(pwd)"
GITHUB_ROOT="${GITHUB_WORKSPACE:-$(dirname "$OPENWRT_DIR")}" 
DTS_DIR="target/linux/msm89xx/dts"

msg() { echo "[410-no-modem] $*"; }

msg "Start diy-part2.sh in: $OPENWRT_DIR"

# 1) 默认 IP 和主题：保留你原来的设置
if [ -f package/base-files/files/bin/config_generate ]; then
  sed -i 's/192\.168\.1\.1/192.168.100.1/g' package/base-files/files/bin/config_generate
  msg "Default LAN IP set to 192.168.100.1"
fi

if [ -f feeds/luci/collections/luci/Makefile ]; then
  sed -i 's/luci-theme-material/luci-theme-argon/g' feeds/luci/collections/luci/Makefile || true
  msg "Default LuCI theme changed to argon when possible"
fi

# 2) 删除/禁用会重新拉起 4G modem 的用户态包。
# 注意：不禁用 WCNSS/Wi-Fi，不动 kmod-ath/kmod-mac80211 等无线组件。
disable_config_symbol() {
  local sym="$1"
  [ -f .config ] || return 0

  if [ -x ./scripts/config ]; then
    ./scripts/config --file .config -d "$sym" >/dev/null 2>&1 || true
  fi

  sed -i \
    -e "/^CONFIG_${sym}=y$/d" \
    -e "/^CONFIG_${sym}=m$/d" \
    -e "/^# CONFIG_${sym} is not set$/d" \
    .config
  echo "# CONFIG_${sym} is not set" >> .config
}

if [ -f .config ]; then
  msg "Disabling modem-related package selections in .config"
  for sym in \
    PACKAGE_modemmanager \
    PACKAGE_luci-app-modemmanager \
    PACKAGE_luci-proto-qmi \
    PACKAGE_uqmi \
    PACKAGE_qmi-utils \
    PACKAGE_libqmi \
    PACKAGE_mbim-utils \
    PACKAGE_libmbim \
    PACKAGE_comgt \
    PACKAGE_comgt-ncm \
    PACKAGE_chat \
    PACKAGE_umbim \
    PACKAGE_kmod-usb-net-qmi-wwan \
    PACKAGE_kmod-usb-net-cdc-mbim \
    PACKAGE_kmod-usb-serial-option \
    PACKAGE_kmod-usb-serial-wwan \
    PACKAGE_kmod-usb-serial-qualcomm
  do
    disable_config_symbol "$sym"
  done
else
  msg ".config not found yet; skip package selection cleanup"
fi

# 3) 防止 feeds.conf.default 里误启用第三方 modemfeed。
if [ -f feeds.conf.default ]; then
  sed -i '/koshev-msk\/modemfeed/d;/modemfeed/d' feeds.conf.default || true
fi

# 4) DTS 关键补丁：
# msm8916.dtsi 默认可能已 disabled，但 msm8916-ufi.dtsi 会把 &mpss、&mpss_mem、&mba_mem 重新 okay，
# 所以必须在所有 msm8916 dts/dtsi 里统一覆盖。保留 &wcnss / &wcnss_mem，避免内置 Wi-Fi 失效。
if [ -d "$DTS_DIR" ]; then
  msg "Patching DTS under $DTS_DIR"

  # 你仓库里如果有自定义 msm8916.dtsi，继续覆盖进去。
  if [ -f "$GITHUB_ROOT/scripts/dts/msm8916.dtsi" ]; then
    cp -f "$GITHUB_ROOT/scripts/dts/msm8916.dtsi" "$DTS_DIR/msm8916.dtsi"
    msg "Copied custom scripts/dts/msm8916.dtsi"
  fi

  python3 - <<'PY'
from pathlib import Path
import re

DTS_DIR = Path('target/linux/msm89xx/dts')
files = sorted(list(DTS_DIR.glob('msm8916*.dts')) + list(DTS_DIR.glob('msm8916*.dtsi')))

# 只动 modem/baseband 相关节点，不动 wcnss/wlan。
REPLACEMENTS = {
    'mpss': '''&mpss {
	/* 410-no-modem: disable Qualcomm MPSS/baseband remoteproc */
	status = "disabled";
};''',
    'mpss_mem': '''&mpss_mem {
	/* 410-no-modem: release MPSS reserved memory back to Linux */
	reg = <0x0 0x86800000 0x0 0x0>;
	status = "disabled";
};''',
    'mba_mem': '''&mba_mem {
	/* 410-no-modem: MBA is only needed for modem firmware loading */
	status = "disabled";
};''',
}

changed_files = []
for path in files:
    text = path.read_text(errors='ignore')
    old = text
    for node, repl in REPLACEMENTS.items():
        # 匹配 &mpss { ... }; 这类 overlay block。
        pattern = re.compile(rf'(?ms)^&{re.escape(node)}\s*\{{.*?^\}};')
        text, n = pattern.subn(repl, text)

    # 额外处理 msm8916.dtsi 里 mpss_mem 默认节点，避免上游变动后仍保留大尺寸。
    text = re.sub(
        r'(?ms)(mpss_mem:\s*mpss@86800000\s*\{.*?\n)\s*reg\s*=\s*<0x0\s+0x86800000\s+0x0\s+0x[0-9a-fA-F]+>;',
        r'\1\treg = <0x0 0x86800000 0x0 0x0>;',
        text,
    )

    if text != old:
        path.write_text(text)
        changed_files.append(str(path))

print('[410-no-modem] DTS changed files:')
for f in changed_files:
    print('[410-no-modem]  - ' + f)

if not changed_files:
    print('[410-no-modem] WARNING: no DTS file changed; please check target/linux/msm89xx/dts path')
PY

  msg "Verify modem-related DTS entries after patch:"
  grep -R -nE '&mpss|mpss_mem|mba_mem|0x5500000|status = "okay";' "$DTS_DIR"/msm8916*.dts* 2>/dev/null | \
    grep -E 'mpss|mba_mem|0x5500000' || true
else
  msg "WARNING: $DTS_DIR not found; DTS no-modem patch skipped"
fi

# 5) 保留你原来的 CPU/温度插件克隆逻辑，但加上容错，避免重复 clone 导致失败。
clone_pkg() {
  local repo="$1"
  local dest="$2"
  if [ -d "$dest/.git" ] || [ -d "$dest" ]; then
    msg "Package exists, skip: $dest"
  else
    git clone --depth=1 "$repo" "$dest" || msg "WARN: clone failed: $repo"
  fi
}

clone_pkg https://github.com/lkiuyu/luci-app-cpu-perf package/luci-app-cpu-perf
clone_pkg https://github.com/lkiuyu/luci-app-cpu-status package/luci-app-cpu-status
clone_pkg https://github.com/gSpotx2f/luci-app-cpu-status-mini package/luci-app-cpu-status-mini
clone_pkg https://github.com/lkiuyu/luci-app-temp-status package/luci-app-temp-status
clone_pkg https://github.com/lkiuyu/DbusSmsForwardCPlus package/DbusSmsForwardCPlus

msg "Done. MPSS/baseband disabled; WCNSS Wi-Fi kept."
