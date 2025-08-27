#!/usr/bin/env bash
# geoip-block.sh - Country IP blocking via ipset + iptables/ip6tables (IPv4 & IPv6)
# Author: you
set -euo pipefail

DATA_DIR="/var/lib/geoip-block"
CONF_DIR="/etc/geoip-block"
CONF_FILE_V4="$CONF_DIR/blocked_countries_v4"
CONF_FILE_V6="$CONF_DIR/blocked_countries_v6"
LOG_TAG="geoip-block"

# 数据源（可通过环境变量覆盖）
: "${IP_SOURCE_V4:=ipdeny}"  # ipdeny | custom
: "${IP_SOURCE_V6:=ipdeny}"  # ipdeny | custom
# 当选择 custom 时，使用 {cc}（小写）占位
: "${CUSTOM_URL_V4:=}"       # 例如：https://example.com/v4/{cc}-aggregated.zone
: "${CUSTOM_URL_V6:=}"       # 例如：https://example.com/v6/{cc}-aggregated.zone

need_root() { [[ $EUID -eq 0 ]] || { echo "请用 root 运行。" >&2; exit 1; }; }
log() { logger -t "$LOG_TAG" -- "$*"; echo "$*"; }

lower() { echo "$1" | tr 'A-Z' 'a-z'; }
upper() { echo "$1" | tr 'a-z' 'A-Z'; }

detect_pkg() {
  if command -v apt-get >/dev/null 2>&1; then echo apt
  elif command -v dnf >/dev/null 2>&1; then echo dnf
  elif command -v yum >/dev/null 2>&1; then echo yum
  elif command -v pacman >/dev/null 2>&1; then echo pacman
  else echo ""
  fi
}

install_deps() {
  local pm; pm=$(detect_pkg)
  # 基础依赖
  if ! command -v ipset >/dev/null 2>&1; then
    case "$pm" in
      apt) apt-get update -y && apt-get install -y ipset iptables ip6tables curl ca-certificates ;;
      dnf) dnf install -y ipset iptables iptables-ipv6 curl ca-certificates || dnf install -y ipset iptables curl ca-certificates ;;
      yum) yum install -y ipset iptables iptables-ipv6 curl ca-certificates || yum install -y ipset iptables curl ca-certificates ;;
      pacman) pacman -Sy --noconfirm ipset iptables curl ca-certificates ;;
      *) echo "请手动安装: ipset iptables curl ca-certificates" ;;
    esac
  fi
}

prepare_dirs() {
  mkdir -p "$DATA_DIR" "$CONF_DIR"
  touch "$CONF_FILE_V4" "$CONF_FILE_V6"
}

ensure_ipset_mod() {
  modprobe ip_set || true
  modprobe ip_set_hash_net || true
}

# ---------------- 数据源 URL ----------------
cidr_url_v4() {
  local cc_lc; cc_lc=$(lower "$1")
  case "$IP_SOURCE_V4" in
    ipdeny)  echo "https://www.ipdeny.com/ipblocks/data/aggregated/${cc_lc}-aggregated.zone" ;;
    custom)  [[ -n "$CUSTOM_URL_V4" ]] || { echo "CUSTOM_URL_V4 未设置" >&2; exit 1; }
             echo "${CUSTOM_URL_V4//\{cc\}/$cc_lc}" ;;
    *) echo "未知 IP_SOURCE_V4: $IP_SOURCE_V4" >&2; exit 1 ;;
  esac
}
cidr_url_v6() {
  local cc_lc; cc_lc=$(lower "$1")
  case "$IP_SOURCE_V6" in
    # ipdeny 的 IPv6 聚合路径（如源有变，可改为 custom）
    ipdeny)  echo "https://www.ipdeny.com/ipv6/ipblocks/data/aggregated/${cc_lc}-aggregated.zone" ;;
    custom)  [[ -n "$CUSTOM_URL_V6" ]] || { echo "CUSTOM_URL_V6 未设置" >&2; exit 1; }
             echo "${CUSTOM_URL_V6//\{cc\}/$cc_lc}" ;;
    *) echo "未知 IP_SOURCE_V6: $IP_SOURCE_V6" >&2; exit 1 ;;
  esac
}

download_cidrs_v4() {
  local cc="$1" url file
  url=$(cidr_url_v4 "$cc")
  file="$DATA_DIR/$(upper "$cc")_v4.cidr"
  curl -fsSL "$url" -o "$file"
  echo "$file"
}
download_cidrs_v6() {
  local cc="$1" url file
  url=$(cidr_url_v6 "$cc")
  file="$DATA_DIR/$(upper "$cc")_v6.cidr"
  curl -fsSL "$url" -o "$file"
  echo "$file"
}

# ---------------- ipset 集合 ----------------
create_set_if_needed_v4() {
  local set="geo4_$(upper "$1")"
  ipset list "$set" >/dev/null 2>&1 || ipset create "$set" hash:net family inet maxelem 200000 2>/dev/null || ipset create "$set" hash:net family inet
}
create_set_if_needed_v6() {
  local set="geo6_$(upper "$1")"
  ipset list "$set" >/dev/null 2>&1 || ipset create "$set" hash:net family inet6 maxelem 200000 2>/dev/null || ipset create "$set" hash:net family inet6
}

fill_set_from_file_v4() {
  local cc="$1" file="$2" set="geo4_$(upper "$cc")"
  ipset flush "$set" || true
  {
    echo "create $set hash:net family inet -exist"
    grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+/[0-9]+' "$file" | while read -r cidr; do
      [[ -n "$cidr" ]] && echo "add $set $cidr"
    done
  } | ipset restore -!
}
fill_set_from_file_v6() {
  local cc="$1" file="$2" set="geo6_$(upper "$cc")"
  ipset flush "$set" || true
  {
    echo "create $set hash:net family inet6 -exist"
    # 简单匹配 IPv6 CIDR
    grep -Ei '^[0-9a-f:]+/[0-9]+' "$file" | while read -r cidr; do
      [[ -n "$cidr" ]] && echo "add $set $cidr"
    done
  } | ipset restore -!
}

# ---------------- iptables 规则 ----------------
ensure_iptables_rule_v4() {
  local cc="$1" set="geo4_$(upper "$cc")"
  if ! iptables -S INPUT | grep -q -- "--match-set $set src -j DROP"; then
    iptables -I INPUT -m set --match-set "$set" src -j DROP
  fi
}
ensure_iptables_rule_v6() {
  local cc="$1" set="geo6_$(upper "$cc")"
  if ! ip6tables -S INPUT | grep -q -- "--match-set $set src -j DROP"; then
    ip6tables -I INPUT -m set --match-set "$set" src -j DROP
  fi
}
remove_iptables_rule_v4() {
  local cc="$1" set="geo4_$(upper "$cc")"
  while iptables -S INPUT | grep -q -- "--match-set $set src -j DROP"; do
    iptables -D INPUT -m set --match-set "$set" src -j DROP || true
  done
}
remove_iptables_rule_v6() {
  local cc="$1" set="geo6_$(upper "$cc")"
  while ip6tables -S INPUT | grep -q -- "--match-set $set src -j DROP"; do
    ip6tables -D INPUT -m set --match-set "$set" src -j DROP || true
  done
}

# ---------------- 配置记录 ----------------
add_conf_v4() { local CC=$(upper "$1"); grep -q "^$CC$" "$CONF_FILE_V4" || echo "$CC" >> "$CONF_FILE_V4"; }
add_conf_v6() { local CC=$(upper "$1"); grep -q "^$CC$" "$CONF_FILE_V6" || echo "$CC" >> "$CONF_FILE_V6"; }
del_conf_v4() { local CC=$(upper "$1"); sed -i.bak "/^${CC}\$/d" "$CONF_FILE_V4"; }
del_conf_v6() { local CC=$(upper "$1"); sed -i.bak "/^${CC}\$/d" "$CONF_FILE_V6"; }

# ---------------- 子命令实现 ----------------
cmd_block() {
  local cc="$1" mode="$2"   # v4|v6|both
  ensure_ipset_mod
  [[ "$mode" == "v6"  || "$mode" == "both" ]] && {
    log "开始屏蔽 $cc (IPv6)"
    local f6; f6=$(download_cidrs_v6 "$cc")
    create_set_if_needed_v6 "$cc"
    fill_set_from_file_v6 "$cc" "$f6"
    ensure_iptables_rule_v6 "$cc"
    add_conf_v6 "$cc"
    log "IPv6 已屏蔽 $cc（$(wc -l < "$f6") 段，可能含非 CIDR 行已忽略）"
  }
  [[ "$mode" == "v4"  || "$mode" == "both" ]] && {
    log "开始屏蔽 $cc (IPv4)"
