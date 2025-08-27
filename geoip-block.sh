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
    local f4; f4=$(download_cidrs_v4 "$cc")
    create_set_if_needed_v4 "$cc"
    fill_set_from_file_v4 "$cc" "$f4"
    ensure_iptables_rule_v4 "$cc"
    add_conf_v4 "$cc"
    log "IPv4 已屏蔽 $cc（$(wc -l < "$f4") 段）"
  }
}

cmd_unblock() {
  local cc="$1" mode="$2"
  [[ "$mode" == "v6"  || "$mode" == "both" ]] && {
    log "取消屏蔽 $cc (IPv6)"
    remove_iptables_rule_v6 "$cc"
    ipset destroy "geo6_$(upper "$cc")" 2>/dev/null || true
    del_conf_v6 "$cc"
  }
  [[ "$mode" == "v4"  || "$mode" == "both" ]] && {
    log "取消屏蔽 $cc (IPv4)"
    remove_iptables_rule_v4 "$cc"
    ipset destroy "geo4_$(upper "$cc")" 2>/dev/null || true
    del_conf_v4 "$cc"
  }
  log "已取消屏蔽 $cc [$mode]"
}

cmd_update() {
  local cc="$1" mode="$2"
  [[ "$mode" == "v6"  || "$mode" == "both" ]] && {
    log "更新 $cc (IPv6)"
    local f6; f6=$(download_cidrs_v6 "$cc")
    create_set_if_needed_v6 "$cc"
    fill_set_from_file_v6 "$cc" "$f6"
    ensure_iptables_rule_v6 "$cc"
    add_conf_v6 "$cc"
  }
  [[ "$mode" == "v4"  || "$mode" == "both" ]] && {
    log "更新 $cc (IPv4)"
    local f4; f4=$(download_cidrs_v4 "$cc")
    create_set_if_needed_v4 "$cc"
    fill_set_from_file_v4 "$cc" "$f4"
    ensure_iptables_rule_v4 "$cc"
    add_conf_v4 "$cc"
  }
  log "已更新 $cc [$mode]"
}

cmd_apply_all() {
  ensure_ipset_mod
  # IPv6
  while read -r CC; do
    [[ -z "${CC:-}" ]] && continue
    local cc_lc; cc_lc=$(lower "$CC")
    local f6="$DATA_DIR/${CC}_v6.cidr"
    [[ -s "$f6" ]] || f6=$(download_cidrs_v6 "$cc_lc")
    create_set_if_needed_v6 "$cc_lc"
    fill_set_from_file_v6 "$cc_lc" "$f6"
    ensure_iptables_rule_v6 "$cc_lc"
  done < "$CONF_FILE_V6"
  # IPv4
  while read -r CC; do
    [[ -z "${CC:-}" ]] && continue
    local cc_lc; cc_lc=$(lower "$CC")
    local f4="$DATA_DIR/${CC}_v4.cidr"
    [[ -s "$f4" ]] || f4=$(download_cidrs_v4 "$cc_lc")
    create_set_if_needed_v4 "$cc_lc"
    fill_set_from_file_v4 "$cc_lc" "$f4"
    ensure_iptables_rule_v4 "$cc_lc"
  done < "$CONF_FILE_V4"
  log "已恢复所有记录的国家屏蔽（IPv4/IPv6）。"
}

cmd_list() {
  echo "IPv4 已记录屏蔽国家："; cat "$CONF_FILE_V4" || true; echo
  echo "IPv6 已记录屏蔽国家："; cat "$CONF_FILE_V6" || true
}

cmd_status() {
  echo "iptables (IPv4) 中的 geo4_* 规则："
  iptables -S | grep -E 'match-set geo4_' || true
  echo
  echo "ip6tables (IPv6) 中的 geo6_* 规则："
  ip6tables -S | grep -E 'match-set geo6_' || true
  echo
  echo "ipset 集合摘要："
  ipset list | awk 'BEGIN{set=""; fam=""} /^Name: geo[46]_/ {set=$2} /^Family:/ {fam=$2} /^Number of entries/ {print set " (" fam "): " $4 " entries"}'
}

usage() {
  cat <<'EOF'
用法:
  geoip-block block   <CC> [--v4|--v6|--both]   # 屏蔽国家(ISO2)，默认 --both
  geoip-block unblock <CC> [--v4|--v6|--both]   # 取消屏蔽
  geoip-block update  <CC> [--v4|--v6|--both]   # 更新该国家的 IP 段
  geoip-block list
  geoip-block status
  geoip-block apply-all                          # 供 systemd 开机恢复

环境变量(可选):
  IP_SOURCE_V4=ipdeny|custom
  CUSTOM_URL_V4='https://example.com/v4/{cc}-aggregated.zone'
  IP_SOURCE_V6=ipdeny|custom
  CUSTOM_URL_V6='https://example.com/v6/{cc}-aggregated.zone'
EOF
  exit 1
}

parse_mode() {
  local mode="both"
  case "${1:-}" in
    --v4) mode="v4" ;;
    --v6) mode="v6" ;;
    --both|"") mode="both" ;;
    *) echo "未知选项：$1" >&2; usage ;;
  esac
  echo "$mode"
}

main() {
  need_root
  prepare_dirs
  install_deps

  local cmd=${1:-}; shift || true
  case "$cmd" in
    block|unblock|update)
      [[ $# -ge 1 ]] || usage
      local cc="$1"; shift || true
      local mode; mode=$(parse_mode "${1:-}")
      case "$cmd" in
        block)   cmd_block "$cc" "$mode"   ;;
        unblock) cmd_unblock "$cc" "$mode" ;;
        update)  cmd_update "$cc" "$mode"  ;;
      esac
      ;;
    list)    cmd_list ;;
    status)  cmd_status ;;
    apply-all) cmd_apply_all ;;
    *) usage ;;
  esac
}

main "$@"
