#!/usr/bin/env bash
# server-audit：只读采集一台 Linux 的安全面，输出 JSON + 人看的摘要。
# 绝不修改目标机：本脚本里没有 apt install / systemctl restart / sed -i / ufw allow。
set -uo pipefail

HOST="" KEY="" OUT="" CONFIG="" SUMMARY=0 SELF_TEST=0

usage() {
  cat <<'USAGE'
用法：
  audit.sh --host root@10.0.0.10 --key ~/.ssh/id_ed25519 [--out report.json] [--summary]
  audit.sh --config hosts.json --out reports/
  audit.sh --self-test          # 用内置样例验证解析与分级，不连任何机器
USAGE
}

while [ $# -gt 0 ]; do
  case "$1" in
    --host) HOST="$2"; shift 2 ;;
    --key) KEY="$2"; shift 2 ;;
    --out) OUT="$2"; shift 2 ;;
    --config) CONFIG="$2"; shift 2 ;;
    --summary) SUMMARY=1; shift ;;
    --self-test) SELF_TEST=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "未知参数：$1" >&2; usage; exit 2 ;;
  esac
done

# 远端采集：只读命令，输出 KEY=VALUE
remote_probe() {
  ssh -i "$KEY" -o ConnectTimeout=10 -o BatchMode=yes -o StrictHostKeyChecking=accept-new "$HOST" 'bash -s' <<'PROBE'
echo "HOSTNAME=$(hostname 2>/dev/null)"
. /etc/os-release 2>/dev/null && echo "OS=$PRETTY_NAME"
echo "KERNEL=$(uname -r)"
echo "PENDING=$(apt list --upgradable 2>/dev/null | grep -c upgradable || echo 0)"
echo "SECURITY=$(apt list --upgradable 2>/dev/null | grep -ci security || echo 0)"
echo "REBOOT_REQUIRED=$(test -f /var/run/reboot-required && echo yes || echo no)"
echo "FW_ACTIVE=$( (ufw status 2>/dev/null | head -1 | grep -q active) && echo yes || echo no)"
echo "FW_DEFAULT_IN=$(ufw status verbose 2>/dev/null | sed -n 's/^Default: \([a-z]*\).*/\1/p' | head -1)"
echo "SSHD_PASSWORD=$(sshd -T 2>/dev/null | awk '/^passwordauthentication/{print $2}')"
echo "SSHD_ROOT=$(sshd -T 2>/dev/null | awk '/^permitrootlogin/{print $2}')"
echo "SSHD_MAXAUTH=$(sshd -T 2>/dev/null | awk '/^maxauthtries/{print $2}')"
echo "SSHD_PORT=$(sshd -T 2>/dev/null | awk '/^port /{print $2; exit}')"
echo "AUTHKEYS=$(grep -c '^ssh-' /root/.ssh/authorized_keys 2>/dev/null || echo 0)"
echo "FAIL2BAN=$(systemctl is-active fail2ban 2>/dev/null || echo inactive)"
echo "UNATTENDED=$(systemctl is-active unattended-upgrades 2>/dev/null || echo inactive)"
echo "AUDITD=$(systemctl is-active auditd 2>/dev/null || echo inactive)"
echo "APPARMOR=$(systemctl is-active apparmor 2>/dev/null || echo inactive)"
echo "UID0=$(awk -F: '$3==0{c++} END{print c+0}' /etc/passwd)"
echo "SUDO_GROUP=$(getent group sudo 2>/dev/null | cut -d: -f4)"
echo "DOCKER_GROUP=$(getent group docker 2>/dev/null | cut -d: -f4)"
echo "LISTEN_PUBLIC_START"
(ss -tlnH 2>/dev/null || netstat -tln 2>/dev/null) | awk '$4 ~ /^(0\.0\.0\.0|\[::\]|\*):/{print $4}' | sort -u | head -40
echo "LISTEN_PUBLIC_END"
echo "DOCKER_PUB_START"
docker ps --format '{{.Names}}|{{.Ports}}' 2>/dev/null | grep '0.0.0.0' || true
echo "DOCKER_PUB_END"
echo "CERT_END"
echo | openssl s_client -connect 127.0.0.1:443 -servername "$(hostname)" 2>/dev/null | openssl x509 -noout -enddate 2>/dev/null | sed 's/notAfter=//'
echo "CERT_END2"
PROBE
}

# 把 KEY=VALUE + 多行块解析成 JSON，并按规则生成 findings
assemble() {
  python3 - "$1" "$HOST" <<'PY'
import json, sys, datetime, re

raw = open(sys.argv[1], encoding="utf-8", errors="replace").read()
host = sys.argv[2] or "unknown"

def block(name):
    m = re.search(r"^%s_START$(.*?)^%s_END$" % (name, name), raw, re.S | re.M)
    return [l.strip() for l in (m.group(1) if m else "").splitlines() if l.strip()]

kv = {}
for line in raw.splitlines():
    if "=" in line and not line.startswith(" "):
        k, v = line.split("=", 1)
        if re.fullmatch(r"[A-Z0-9_]+", k):
            kv[k] = v.strip()

listeners = block("LISTEN_PUBLIC")
docker_pub = block("DOCKER_PUB")
cert = ""
m = re.search(r"^CERT_END$", raw, re.M)
if m:
    tail = raw[m.end():].split("CERT_END2")[0].strip()
    cert = tail.splitlines()[0] if tail else ""

def num(v, d=0):
    try: return int(str(v).strip())
    except Exception: return d

data = {
    "host": host,
    "hostname": kv.get("HOSTNAME", ""),
    "os": kv.get("OS", ""),
    "kernel": kv.get("KERNEL", ""),
    "collected_at": datetime.datetime.now().astimezone().isoformat(timespec="seconds"),
    "updates": {"pending": num(kv.get("PENDING")), "security": num(kv.get("SECURITY")),
                "reboot_required": kv.get("REBOOT_REQUIRED") == "yes"},
    "firewall": {"active": kv.get("FW_ACTIVE") == "yes", "default_in": kv.get("FW_DEFAULT_IN", "")},
    "sshd": {"password_auth": kv.get("SSHD_PASSWORD", ""), "root_login": kv.get("SSHD_ROOT", ""),
             "maxauthtries": num(kv.get("SSHD_MAXAUTH")), "port": num(kv.get("SSHD_PORT"), 22)},
    "auth_keys": num(kv.get("AUTHKEYS")),
    "agents": {"fail2ban": kv.get("FAIL2BAN", ""), "unattended_upgrades": kv.get("UNATTENDED", ""),
               "auditd": kv.get("AUDITD", ""), "apparmor": kv.get("APPARMOR", "")},
    "accounts": {"uid0": num(kv.get("UID0")), "sudo_group": kv.get("SUDO_GROUP", ""),
                 "docker_group": kv.get("DOCKER_GROUP", "")},
    "listeners_public": listeners,
    "docker_published_public": docker_pub,
    "tls_cert_expiry": cert,
}

# ---- 分级规则：每条都带证据 ----
f = []
def add(sev, key, msg, evidence, fix):
    f.append({"severity": sev, "key": key, "issue": msg, "evidence": evidence, "fix": fix})

if data["updates"]["security"] > 0:
    add("P1", "updates.security", "有安全更新没打（%d 个）" % data["updates"]["security"],
        "apt list --upgradable | grep -ci security = %d" % data["updates"]["security"],
        "挑维护窗口 apt upgrade 后重启")
if data["updates"]["pending"] > 30:
    add("P0", "updates.pending", "待升级包 %d 个，内核/库补丁可能缺失" % data["updates"]["pending"],
        "apt list --upgradable 行数", "同上一并处理")
if data["updates"]["reboot_required"]:
    add("P1", "reboot", "补丁已装但没重启，未生效", "/var/run/reboot-required 存在", "计划重启")
if not data["firewall"]["active"]:
    add("P0", "firewall", "本机防火墙没开", "ufw status 第一行不是 active", "开 ufw 并默认拒绝入站")
if data["sshd"]["password_auth"] not in ("no", ""):
    add("P0", "sshd.password", "SSH 允许密码登录", "sshd -T passwordauthentication=%s" % data["sshd"]["password_auth"],
        "改 no 并保留密钥通道")
if data["sshd"]["root_login"] in ("yes",):
    add("P0", "sshd.root", "root 可以用密码直接登录", "permitrootlogin=yes", "改 without-password 或 no")
if data["sshd"]["maxauthtries"] and data["sshd"]["maxauthtries"] > 4:
    add("P2", "sshd.maxauth", "SSH 重试次数偏大（%d）" % data["sshd"]["maxauthtries"], "sshd -T maxauthtries", "调到 3-4")
if data["accounts"]["uid0"] > 1:
    add("P0", "accounts.uid0", "有 %d 个 UID 0 账号" % data["accounts"]["uid0"], "/etc/passwd", "逐个核对来源")
if data["accounts"]["docker_group"]:
    add("P1", "accounts.docker", "这些账号在 docker 组（等价 root）", data["accounts"]["docker_group"], "确认都是必要账号")
if data["agents"]["fail2ban"] != "active" and data["sshd"]["password_auth"] != "no":
    add("P1", "fail2ban", "密码登录开着又没 fail2ban", "systemctl is-active fail2ban", "装 fail2ban 开 sshd jail")
if data["agents"]["unattended_upgrades"] != "active":
    add("P2", "autoupdate", "没开自动安全更新", "systemctl is-active unattended-upgrades", "开启 security 源自动更新")

db_ports = {"3306": "MySQL", "5432": "PostgreSQL", "5433": "PostgreSQL", "6379": "Redis",
            "27017": "MongoDB", "9200": "Elasticsearch", "11211": "Memcached"}
for item in listeners:
    port = item.rsplit(":", 1)[-1]
    if port in db_ports:
        add("P0", "db.public", "%s（%s）监听在所有网卡" % (db_ports[port], port),
            "ss -tln 显示 %s" % item, "改绑 127.0.0.1，或防火墙只放应用机")
for item in docker_pub:
    add("P1", "docker.public", "容器端口发布到 0.0.0.0（绕过 UFW）", item, "改绑 127.0.0.1 或走反代")

data["findings"] = sorted(f, key=lambda x: {"P0": 0, "P1": 1, "P2": 2}[x["severity"]])
print(json.dumps(data, ensure_ascii=False, indent=2))
PY
}

summarize() {
  python3 - "$1" <<'PY'
import json, sys, collections
d = json.load(open(sys.argv[1], encoding="utf-8"))
c = collections.Counter(x["severity"] for x in d["findings"])
print("== %s (%s)" % (d["hostname"] or d["host"], d["os"]))
print("   待升级 %d（安全 %d）| 防火墙 %s | SSH 密码登录 %s | 公开监听 %d 个" % (
    d["updates"]["pending"], d["updates"]["security"],
    "开" if d["firewall"]["active"] else "关",
    d["sshd"]["password_auth"] or "未知", len(d["listeners_public"])))
print("   P0 %d / P1 %d / P2 %d" % (c["P0"], c["P1"], c["P2"]))
for x in d["findings"][:5]:
    print("   [%s] %s — %s" % (x["severity"], x["issue"], x["fix"]))
PY
}

if [ "$SELF_TEST" = "1" ]; then
  tmp=$(mktemp)
  cat > "$tmp" <<'SAMPLE'
HOSTNAME=demo-host
OS=Ubuntu 22.04.4 LTS
KERNEL=5.15.0-100-generic
PENDING=42
SECURITY=3
REBOOT_REQUIRED=no
FW_ACTIVE=yes
FW_DEFAULT_IN=deny
SSHD_PASSWORD=yes
SSHD_ROOT=yes
SSHD_MAXAUTH=6
SSHD_PORT=22
AUTHKEYS=2
FAIL2BAN=inactive
UNATTENDED=inactive
AUDITD=inactive
APPARMOR=active
UID0=1
SUDO_GROUP=deploy
DOCKER_GROUP=deploy
LISTEN_PUBLIC_START
0.0.0.0:22
0.0.0.0:5432
LISTEN_PUBLIC_END
DOCKER_PUB_START
demo-api|0.0.0.0:8080->80/tcp
DOCKER_PUB_END
CERT_END
CERT_END2
SAMPLE
  json=$(assemble "$tmp" demo-host)
  echo "$json" | python3 -c "import json,sys; d=json.load(sys.stdin); assert d['updates']['security']==3; assert any(f['key']=='sshd.password' for f in d['findings']); assert any(f['key']=='db.public' for f in d['findings']); print('self-test OK：%d 条发现' % len(d['findings']))"
  rm -f "$tmp"
  exit 0
fi

run_one() {
  local host="$1" key="$2" target="$3"
  local tmp; tmp=$(mktemp)
  if ! remote_probe > "$tmp" 2>/dev/null; then
    echo "{\"host\": \"$host\", \"error\": \"ssh 采集失败（网络或权限）\"}" > "$target"
    echo "✗ $host 采集失败" >&2
    rm -f "$tmp"; return 1
  fi
  assemble "$tmp" "$host" > "$target"
  rm -f "$tmp"
  [ "$SUMMARY" = "1" ] && summarize "$target"
  echo "✓ $host → $target" >&2
}

if [ "$SELF_TEST" = "0" ]; then
  if [ -n "$CONFIG" ]; then
    mkdir -p "${OUT:-reports}"
    python3 -c "import json,sys;print('\n'.join('%s %s' % (h['host'], h.get('key','~/.ssh/id_ed25519')) for h in json.load(open(sys.argv[1]))['hosts']))" "$CONFIG" |
    while read -r h k; do
      name=$(echo "$h" | tr '@.' '__')
      run_one "$h" "$(eval echo "$k")" "${OUT:-reports}/$name.json"
    done
  elif [ -n "$HOST" ]; then
    target="${OUT:-/dev/stdout}"
    [ "$target" != "/dev/stdout" ] && run_one "$HOST" "${KEY:-~/.ssh/id_ed25519}" "$target" || assemble <(remote_probe) "$HOST"
  else
    usage; exit 2
  fi
fi
