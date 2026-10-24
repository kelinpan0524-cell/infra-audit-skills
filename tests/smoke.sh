#!/usr/bin/env bash
# 三个技能的自检：不连任何目标机
set -uo pipefail
cd "$(dirname "$0")/.."
fail=0
check() { printf '%-46s' "$1"; shift; if "$@" >/tmp/smoke.out 2>&1; then echo "✓"; else echo "✗"; tail -5 /tmp/smoke.out; fail=1; fi; }

for s in server-audit server-harden tailnet-audit; do
  printf '%-46s' "bash -n $s"
  bash -n "skills/$s/scripts/"*.sh && echo "✓" || { echo "✗"; fail=1; }
done

check "server-audit --self-test"        bash skills/server-audit/scripts/audit.sh --self-test
check "server-harden --self-test"       bash skills/server-harden/scripts/harden.sh --self-test
check "server-audit --help 可用"         bash skills/server-audit/scripts/audit.sh --help
check "tailnet-audit --help 可用"        bash skills/tailnet-audit/scripts/tailnet-recon.sh --help

python3 tests/check_skill.py skills/server-audit skills/server-harden skills/tailnet-audit || fail=1
exit $fail
