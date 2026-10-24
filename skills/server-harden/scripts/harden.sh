#!/usr/bin/env bash
# harden.sh：按项执行加固；SSH 改动带回滚定时器。
set -uo pipefail
HOST="" KEY="" ACTION="" YES=0 SELF_TEST=0

usage() {
  cat <<'USAGE'
用法：
  harden.sh --host root@10.0.0.10 --key ~/.ssh/id --check
  harden.sh --host root@10.0.0.10 --key ~/.ssh/id --apply fail2ban|autoupdate|sshd-guard [--yes]
  harden.sh --self-test
说明：sshd-guard 会先挂 5 分钟自动还原，成功登录后用 --cancel-rollback 取消。
USAGE
}

while [ $# -gt 0 ]; do
  case "$1" in
    --host) HOST="$2"; shift 2 ;;
    --key) KEY="$2"; shift 2 ;;
    --apply) ACTION="$2"; shift 2 ;;
    --check) ACTION="check"; shift ;;
    --cancel-rollback) ACTION="cancel"; shift ;;
    --yes) YES=1; shift ;;
    --self-test) SELF_TEST=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "未知参数：$1" >&2; exit 2 ;;
  esac
done

sshx() { ssh -i "$KEY" -o ConnectTimeout=10 -o BatchMode=yes -o StrictHostKeyChecking=accept-new "$HOST" "$@"; }

preflight() {
  echo "== 预检 $HOST"
  sshx 'echo "主机: $(hostname)"; echo "内核: $(uname -r)"; echo "sshd: $(sshd -T 2>/dev/null | awk "/^passwordauthentication/{print \$2}")/$(sshd -T 2>/dev/null | awk "/^permitrootlogin/{print \$2}")"; echo "fail2ban: $(systemctl is-active fail2ban 2>/dev/null || echo inactive)"; echo "自动更新: $(systemctl is-active unattended-upgrades 2>/dev/null || echo inactive)"' || {
    echo "✗ 连不上或没权限，先修连接再加固" >&2; return 1; }
}

do_check() {
  preflight || return 1
  echo
  echo "将要做的（一次只做一项）："
  echo "  fail2ban   装 fail2ban + sshd jail        回滚: apt purge fail2ban"
  echo "  autoupdate 只开 security 源自动更新        回滚: 改回 20auto-upgrades"
  echo "  sshd-guard 禁密码/禁 root 直登/重试3次     回滚: 5 分钟自动还原"
  echo
  echo "SSH 加固前请确认：另开一个终端登录着，且你有云控制台的救援入口。"
}

do_fail2ban() {
  sshx 'DEBIAN_FRONTEND=noninteractive apt-get update -qq && DEBIAN_FRONTEND=noninteractive apt-get install -y -qq fail2ban && \
    printf "[sshd]\nenabled = true\nmaxretry = 5\nfindtime = 10m\nbantime = 1h\n" > /etc/fail2ban/jail.d/sshd.local && \
    systemctl enable --now fail2ban && sleep 1 && fail2ban-client status sshd' || return 1
  echo "验证：fail2ban-client status sshd 里有 Currently banned 计数"
}

do_autoupdate() {
  sshx 'DEBIAN_FRONTEND=noninteractive apt-get install -y -qq unattended-upgrades && \
    printf "APT::Periodic::Update-Package-Lists \"1\";\nAPT::Periodic::Unattended-Upgrade \"1\";\n" > /etc/apt/apt.conf.d/20auto-upgrades && \
    systemctl restart unattended-upgrades && systemctl is-active unattended-upgrades' || return 1
  echo "验证：systemctl is-active unattended-upgrades → active；不改自动重启（要开另说）"
}

do_sshd_guard() {
  if [ "$YES" != "1" ]; then
    echo "这会改 SSH 配置。确认后有 5 分钟自动还原兜底；再加 --yes 才执行。" >&2
    return 3
  fi
  echo "== 备份并挂回滚定时器"
  sshx 'set -e
    mkdir -p /etc/ssh/sshd_config.d
    cp -f /etc/ssh/sshd_config.d/01-hardening.conf /tmp/sshd.bak 2>/dev/null || touch /tmp/sshd.bak
    systemctl stop sshd-rollback.timer 2>/dev/null || true
    systemd-run --on-active=5min --unit=sshd-rollback /bin/sh -c "
      if [ -s /tmp/sshd.bak ]; then cp -f /tmp/sshd.bak /etc/ssh/sshd_config.d/01-hardening.conf;
      else rm -f /etc/ssh/sshd_config.d/01-hardening.conf; fi
      sshd -t && systemctl reload ssh"' || return 1

  echo "== 写新配置并校验"
  sshx 'printf "PermitRootLogin prohibit-password\nPasswordAuthentication no\nPubkeyAuthentication yes\nMaxAuthTries 3\nLoginGraceTime 30\nX11Forwarding no\nAllowAgentForwarding no\n" > /etc/ssh/sshd_config.d/01-hardening.conf
    sshd -t' || { echo "✗ 配置语法不过，未 reload；删掉文件即可（本来也没生效）" >&2; return 1; }

  sshx 'systemctl reload ssh' || return 1
  echo "== 已 reload。现在必须新开一个终端 ssh 一次。"
  echo "   成功 → 执行：harden.sh --host $HOST --key $KEY --cancel-rollback"
  echo "   失败 → 什么都别做，5 分钟后自动还原"
}

do_cancel() {
  sshx 'systemctl stop sshd-rollback.timer 2>/dev/null; systemctl reset-failed sshd-rollback.service 2>/dev/null; systemctl list-timers --all | grep -c sshd-rollback || true'
  echo "回滚定时器已取消（上面的 0 表示已无残留）"
}

if [ "$SELF_TEST" = "1" ]; then
  bash -n "$0" && echo "self-test OK：语法检查通过，动作清单：check/fail2ban/autoupdate/sshd-guard/cancel"
  exit 0
fi

[ -z "$HOST" ] && { usage; exit 2; }
case "$ACTION" in
  check) do_check ;;
  fail2ban) do_fail2ban ;;
  autoupdate) do_autoupdate ;;
  sshd-guard) do_sshd_guard ;;
  cancel) do_cancel ;;
  *) usage; exit 2 ;;
esac
