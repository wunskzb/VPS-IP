#!/usr/bin/env bash
# 一键安装: /usr/local/sbin/geoip-block + systemd 自启动
set -euo pipefail

# ⚠️ 把下面地址替换为你自己的仓库 raw 路径
REPO_RAW="${REPO_RAW:-https://raw.githubusercontent.com/wunskzb/VPS-IP/main}"

need_root() { [[ $EUID -eq 0 ]] || { echo "请用 root 运行。"; exit 1; }; }

install_bin() {
  curl -fsSL "$REPO_RAW/geoip-block.sh" -o /usr/local/sbin/geoip-block
  chmod +x /usr/local/sbin/geoip-block
}

install_service() {
  cat >/etc/systemd/system/geoip-block.service <<'UNIT'
[Unit]
Description=GeoIP Country Blocking (restore IPv4 & IPv6 sets and iptables rules)
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/geoip-block apply-all
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
UNIT
  systemctl daemon-reload
  systemctl enable geoip-block.service
}

post_hint() {
  echo
  echo "安装完成！常用命令："
  echo "  geoip-block block CN --v4"
  echo "  geoip-block block CN --v6"
  echo "  geoip-block block CN --both   # 默认"
  echo "  geoip-block list | status"
  echo "自启动已启用（重启后自动恢复 IPv4/IPv6 规则）。"
}

main() { need_root; install_bin; install_service; post_hint; }
main "$@"
