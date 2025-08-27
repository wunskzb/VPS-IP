#!/usr/bin/env bash
# 一键安装: 把脚本装到 /usr/local/sbin，并配置 systemd 自启动
set -euo pipefail

REPO_RAW="${REPO_RAW:-https://raw.githubusercontent.com/<your-github-username>/geoip-block/main}"

need_root() { if [[ $EUID -ne 0 ]]; then echo "请用 root 运行。"; exit 1; fi; }

install_bin() {
  curl -fsSL "$REPO_RAW/geoip-block.sh" -o /usr/local/sbin/geoip-block
  chmod +x /usr/local/sbin/geoip-block
}

install_service() {
  cat >/etc/systemd/system/geoip-block.service <<'UNIT'
[Unit]
Description=GeoIP Country Blocking (restore sets and iptables rules)
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
  echo "  geoip-block block CN      # 屏蔽中国（示例）"
  echo "  geoip-block unblock CN    # 取消屏蔽"
  echo "  geoip-block list          # 查看已记录国家"
  echo "  geoip-block status        # 查看规则与集合"
  echo "自启动已启用（重启后自动恢复规则）。"
}

main() {
  need_root
  install_bin
  install_service
  post_hint
}

main "$@"
