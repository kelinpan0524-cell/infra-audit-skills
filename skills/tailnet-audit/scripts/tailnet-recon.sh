#!/usr/bin/env bash
# tailnet-recon.sh：Tailscale 拓扑、可达性矩阵、ACL 快照（只读）
set -uo pipefail

PORTS="22"
SSH_TARGET="" SSH_KEY=""
OUT=""

usage() {
  cat <<'USAGE'
用法：
  tailnet-recon.sh status
  tailnet-recon.sh matrix [--ports 22,445,5433]
  tailnet-recon.sh from --ssh root@1.2.3.4 --key ~/.ssh/id [--ports 22,445]
  tailnet-recon.sh acl --out acl.json          # 需要 TS_API_KEY
USAGE
}

cmd="${1:-status}"
case "$cmd" in -h|--help) usage; exit 0 ;; esac
shift || true
while [ $# -gt 0 ]; do
  case "$1" in
    --ports) PORTS="$2"; shift 2 ;;
    --ssh) SSH_TARGET="$2"; shift 2 ;;
    --key) SSH_KEY="$2"; shift 2 ;;
    --out) OUT="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "未知参数：$1" >&2; exit 2 ;;
  esac
done

need_tailscale() {
  command -v tailscale >/dev/null || { echo "本机没有 tailscale 命令" >&2; exit 1; }
}

case "$cmd" in
  status)
    need_tailscale
    tsjson=$(mktemp)
    tailscale status --json > "$tsjson"
    python3 - "$tsjson" <<'PY'
import json, sys
d = json.load(open(sys.argv[1], encoding="utf-8"))
me = d["Self"]
print("本机 :", me["HostName"], me["TailscaleIPs"][0] if me.get("TailscaleIPs") else "", "tags=", me.get("Tags") or "无",
      "exit_node=", me.get("ExitNode"))
tn = d.get("CurrentTailnet", {})
print("tailnet:", tn.get("Name"), "| MagicDNS:", tn.get("MagicDNSEnabled"))
peers = list(d.get("Peer", {}).values())
print("设备数 :", len(peers) + 1)
print()
print("%-22s %-16s %-14s %-5s %-12s %s" % ("名称", "IP", "tags", "在线", "密钥到期", "子网路由"))
for p in sorted(peers, key=lambda x: x["HostName"].lower()):
    exp = (p.get("KeyExpiry") or "")[:10] or "永不过期"
    routes = p.get("PrimaryRoutes") or []
    print("%-22s %-16s %-14s %-5s %-12s %s" % (
        p["HostName"][:22], (p.get("TailscaleIPs") or [""])[0],
        ",".join(p.get("Tags") or []) or "无", "是" if p.get("Online") else "否",
        exp, ",".join(routes) or "无"))
print()
print("要判断「谁能摸到谁」，别只看这张表：ACL 会过滤可见性，必须配合 matrix / from 实测。")
PY
    rm -f "$tsjson"
    ;;

  matrix|from)
    tfile=$(mktemp)
    if [ "$cmd" = "matrix" ]; then
      need_tailscale
      tsjson2=$(mktemp)
      tailscale status --json > "$tsjson2"
      python3 - "$tsjson2" > "$tfile" <<'PYLIST'
import json, sys
d = json.load(open(sys.argv[1], encoding="utf-8"))
for p in d.get("Peer", {}).values():
    ips = p.get("TailscaleIPs") or []
    if ips:
        print("%s %s" % (p["HostName"].replace(" ", "_"), ips[0]))
PYLIST
      rm -f "$tsjson2"
    else
      [ -z "$SSH_TARGET" ] && { echo "from 需要 --ssh root@ip" >&2; exit 2; }
      ssh -i "$SSH_KEY" -o ConnectTimeout=10 -o BatchMode=yes -o StrictHostKeyChecking=accept-new "$SSH_TARGET" \
        'tailscale status --json' > "$tsjson2" 2>/dev/null || { echo "取不到 $SSH_TARGET 的 tailscale 状态" >&2; exit 1; }
      python3 - "$tsjson2" > "$tfile" <<'PYLIST'
import json, sys
d = json.load(open(sys.argv[1], encoding="utf-8"))
for p in d.get("Peer", {}).values():
    ips = p.get("TailscaleIPs") or []
    if ips:
        print("%s %s" % (p["HostName"].replace(" ", "_"), ips[0]))
PYLIST
      rm -f "$tsjson2"
    fi

    [ -s "$tfile" ] || { echo "没有可测的目标（ACL 可能过滤了可见性）"; rm -f "$tfile"; exit 0; }
    echo "来源: ${SSH_TARGET:-本机} | 端口: $PORTS"
    echo
    printf "%-22s %-16s %s\n" "目标" "IP" "结果"
    while read -r name ip; do
      [ -z "$ip" ] && continue
      res=""
      for port in ${PORTS//,/ }; do
        if [ "$cmd" = "matrix" ]; then
          if nc -z -G 2 "$ip" "$port" >/dev/null 2>&1; then res="$res $port:通"; else res="$res $port:-"; fi
        else
          if ssh -i "$SSH_KEY" -o ConnectTimeout=10 -o BatchMode=yes -o StrictHostKeyChecking=accept-new "$SSH_TARGET" \
             "timeout 3 bash -c 'echo > /dev/tcp/$ip/$port' 2>/dev/null" >/dev/null 2>&1; then
            res="$res $port:通"; else res="$res $port:-"; fi
        fi
      done
      printf "%-22s %-16s %s\n" "$(echo "$name" | cut -c1-22)" "$ip" "$res"
    done < "$tfile"
    rm -f "$tfile"
    echo
    echo "读法：隧道通（tailscale ping）+ 端口全不通 = ACL 在限；只有「通」的端口要逐个确认是什么服务。"
    ;;

  acl)
    [ -z "${TS_API_KEY:-}" ] && { echo "需要 TS_API_KEY（Tailscale 后台 → Settings → Keys，带 policy_file 读权限）" >&2; exit 2; }
    out="${OUT:-acl-$(date +%F).json}"
    curl -sS -u "$TS_API_KEY:" "https://api.tailscale.com/api/v2/tailnet/-/acl" -o "$out" || exit 1
    python3 - "$out" <<'PY'
import json, sys
p = sys.argv[1]
try:
    d = json.load(open(p, encoding="utf-8"))
except Exception:
    print("拿回来的不是 JSON：", open(p, encoding="utf-8").read()[:200]); raise SystemExit(1)
print("已保存:", p)
acls = d.get("acls") or d.get("ACLs") or []
wild = [r for r in acls if "*" in (r.get("src") or []) and any("*" in x for x in (r.get("dst") or []))]
print("规则条数:", len(acls), "| 含通配 src/dst 的规则:", len(wild), "| 有 ssh 段:", bool(d.get("ssh")))
if wild:
    print("⚠ 有全放开规则，重点审：", json.dumps(wild[:2], ensure_ascii=False)[:200])
PY
    ;;

  *) usage; exit 2 ;;
esac
