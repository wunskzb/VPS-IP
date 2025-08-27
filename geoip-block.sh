#!/usr/bin/env bash
# geoip-block.sh - Country IP blocking via ipset + iptables
# Author: you
set -euo pipefail

DATA_DIR="/var/lib/geoip-block"
CONF_DIR="/etc/geoip-block"
CONF_FILE="$CONF_DIR/blocked_countries"
LOG_TAG="geoip-block"
: "${IP_SOURCE:=ipdeny}"   # 可选: ipdeny | custom
: "${CUSTOM_URL:=}"        # IP_SOURCE=custom 时，形如 https://example.com/cc-aggregated.zone 的模板URL

need_root() {
  if [[ $EUID -ne 0 ]]; then
    echo "请用 root 运行。" >&2; exit 1
  fi
}

log() { logger -t "$LOG_TAG" -- "$*"; echo "$*"; }

detect_pkg() {
  if command -v apt-get >/dev/null 2>&1; then echo apt; return
  elif command -v dnf >/dev/null 2>&1; then echo dnf; return
  elif command -v yum >/dev/null 2>&1; then echo yum; return
  elif command -v pacman >/dev/null 2>&1; then echo pacman; return
  fi
  echo ""
}

install_deps() {
  local pm=$(detect_pkg)
  if ! command -v ipset >/dev/null 2>&1; then
    case "$pm" in
      apt) apt-get update -y && apt-get install -y ipset iptables curl ca-certificates ;;
      dnf) dnf install -y ipset iptables curl ca-certificates ;;
      yum) yum install -y ipset iptables curl ca-certificates ;;
      pacman) pacman -Sy --noconfirm ipset iptables curl ca-certificates ;;
      *) echo "请手动安装: ipset iptables curl ca-certificates" ;;
    esac
  fi
}

lower() { echo "$1" | tr 'A-Z' 'a-z'; }
upper() { echo "$1" | tr 'a-z' 'A-Z'; }

cidr_url() {
  local cc_lc
  cc_lc=$(lower "$1")
  case "$IP_SOURCE" in
    ipdeny)   echo "https://www.ipdeny.com/ipblocks/data/aggregated/${cc_lc}-aggregated.zone" ;;
    custom)
      if [[ -z "$CUSTOM_URL" ]]; then
        echo "自定义源未设定(CUSTOM_URL)" >&2; exit 1
      fi
      # 自定义 URL 模板：用 {cc} 表示小写国家代码占位
      echo "${CUSTOM_URL//\{cc\}/$cc_lc}"
      ;;
    *)
      echo "未知 IP_SOURCE: $IP_SOURCE" >&2; exit 1
      ;;
  esac
}

prepare_dirs() {
  mkdir -p "$DATA_DIR" "$CONF_DIR"
  touch "$CONF_FILE"
}

ensure_ipset() {
  modprobe ip_set || true
  modprobe ip_set_hash_net || true
}

create_set_if_needed() {
  local set="geo_$(upper "$1")"
  if ! ipset list "$set" >/dev/null 2>&1; then
    ipset create "$set" hash:net maxelem 200000 || ipset create "$set" hash:net
  fi
}

fill_set_from_file() {
  local cc="$1"; local file="$2"; local set="geo_$(upper "$cc")"
  # 清空后批量导入
  ipset flush "$set" || true
  # 使用 ipset restore 提速
  {
    echo "create $set hash:net -exist"
    while read -r cidr; do
      [[ -z "$cidr" ]] && continue
      echo "add $set $cidr"
    done < <(grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+/[0-9]+' "$file" || true)
  } | ipset restore -!
}

ensure_iptables_rule() {
  local cc="$1"; local set="geo_$(upper "$cc")"
  # 避免重复添加，匹配规则存在性
  if ! iptables -S INPUT | grep -q -- "--match-set $set src -j DROP"; then
    iptables -I INPUT -m set --match-set "$set" src -j DROP
  fi
  # 可选：如需对 FORWARD 也拦截，取消下面注释
  # if ! iptables -S FORWARD | grep -q -- "--match-set $set src -j DROP"; then
  #   iptables -I FORWARD -m set --match-set "$set" src -j DROP
  # fi
}

remove_iptables_rule() {
  local cc="$1"; local set="geo_$(upper "$cc")"
  # 多次删除直到不存在
  while iptables -S INPUT | grep -q -- "--match-set $set src -j DROP"; do
    iptables -D INPUT -m set --match-set "$set" src -j DROP || true
  done
  # 同步 FORWARD 如有开启
  # while iptables -S FORWARD | grep -q -- "--match-set $set src -j DROP"; do
  #   iptables -D FORWARD -m set --match-set "$set" src -j DROP || true
  # done
}

download_cidrs() {
  local cc="$1"; local url file
  url=$(cidr_url "$cc")
  file="$DATA_DIR/$(upper "$cc").cidr"
  curl -fsSL "$url" -o "$file"
  echo "$file"
}

add_to_conf_once() {
  local cc_u
  cc_u=$(upper "$1")
  grep -q "^$cc_u$" "$CONF_FILE" || echo "$cc_u" >> "$CONF_FILE"
}

remove_from_conf() {
  local cc_u
  cc_u=$(upper "$1")
  sed -i.bak "/^${cc_u}\$/d" "$CONF_FILE"
}

cmd_block() {
  local cc="$1"
  log "开始屏蔽国家：$cc"
  local file
  file=$(download_cidrs "$cc")
  ensure_ipset
  create_set_if_needed "$cc"
  fill_set_from_file "$cc" "$file"
  ensure_iptables_rule "$cc"
  add_to_conf_once "$cc"
  log "已屏蔽 $cc（共 $(wc -l < "$file") 段）"
}

cmd_unblock() {
  local cc="$1"; local set="geo_$(upper "$cc")"
  log "取消屏蔽国家：$cc"
  remove_iptables_rule "$cc"
  ipset destroy "$set" 2>/dev/null || true
  remove_from_conf "$cc"
  log "已取消屏蔽 $cc"
}

cmd_update() {
  local cc="$1"; local file
  log "更新国家段：$cc"
  file=$(download_cidrs "$cc")
  create_set_if_needed "$cc"
  fill_set_from_file "$cc" "$file"
  log "已更新 $cc（共 $(wc -l < "$file") 段）"
}

cmd_apply_all() {
  # 用于开机自恢复
  while read -r cc_u; do
    [[ -z "$cc_u" ]] && continue
    local cc_l
    cc_l=$(lower "$cc_u")
    local file="$DATA_DIR/${cc_u}.cidr"
    if [[ ! -s "$file" ]]; then
      file=$(download_cidrs "$cc_l")
    fi
    ensure_ipset
    create_set_if_needed "$cc_l"
    fill_set_from_file "$cc_l" "$file"
    ensure_iptables_rule "$cc_l"
  done < "$CONF_FILE"
  log "已应用配置文件中的全部国家屏蔽。"
}

cmd_list() {
  echo "已记录的屏蔽国家："
  cat "$CONF_FILE" || true
}

cmd_status() {
  echo "当前 iptables 规则 (含 geo_* 匹配)："
  iptables -S | grep -E 'match-set geo_' || true
  echo
  echo "当前 ipset 集合："
  ipset list | awk 'BEGIN{set=""} /^Name: geo_/ {set=$2} /^Number of entries/ {print set ": " $4 " entries"}'
}

usage() {
  cat <<EOF
用法:
  $0 block   <CC>   # 屏蔽国家(ISO2), 例如 CN、RU、IR
  $0 unblock <CC>   # 取消屏蔽
  $0 update  <CC>   # 更新该国家的 IP 段
  $0 list            # 查看已记录在案的屏蔽国家
  $0 status          # 查看当前规则与集合
  $0 apply-all       # 从配置文件恢复全部规则(供 systemd 调用)
环境变量:
  IP_SOURCE=ipdeny|custom
  CUSTOM_URL='https://example.com/{cc}-aggregated.zone'  # 当 IP_SOURCE=custom 时生效
EOF
  exit 1
}

main() {
  need_root
  prepare_dirs
  install_deps

  local cmd=${1:-}; shift || true
  case "${cmd}" in
    block)   [[ $# -ge 1 ]] || usage; cmd_block "$1" ;;
    unblock) [[ $# -ge 1 ]] || usage; cmd_unblock "$1" ;;
    update)  [[ $# -ge 1 ]] || usage; cmd_update "$1" ;;
    list)    cmd_list ;;
    status)  cmd_status ;;
    apply-all) cmd_apply_all ;;
    *) usage ;;
  esac
}

main "$@"
