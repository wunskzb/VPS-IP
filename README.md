# geoip-block

一键屏蔽指定国家 IP (IPv4/IPv6)，基于 `ipset + iptables/ip6tables`。支持记录配置、自动更新、开机自恢复。

## 安装

```bash
curl -fsSL https://raw.githubusercontent.com/wunskzb/VPS-IP/main/install.sh | bash


## 使用示例
## 屏蔽伊朗
sudo geoip-block block IR --v4     # 仅屏蔽 IPv4
sudo geoip-block block IR --v6     # 仅屏蔽 IPv6
sudo geoip-block block IR --both   # 同时屏蔽 IPv4 + IPv6

屏蔽中国
sudo geoip-block block CN --both

查看已生效规则
sudo geoip-block status

取消屏蔽
sudo geoip-block unblock IR --both   # 取消伊朗 IPv4+IPv6 屏蔽
sudo geoip-block unblock CN --both   # 取消中国 IPv4+IPv6 屏蔽

卸载（移除脚本和 systemd 服务）
sudo systemctl disable --now geoip-block.service
sudo rm -f /usr/local/sbin/geoip-block
sudo rm -f /etc/systemd/system/geoip-block.service
sudo rm -rf /etc/geoip-block /var/lib/geoip-block
sudo systemctl daemon-reload
