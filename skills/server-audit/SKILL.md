---
name: server-audit
description: 只读审查一台 Linux 服务器的安全面：暴露端口、补丁、SSH、防火墙、密钥，出分级报告。
version: 1.0.0
author: Kelin Pan, Hermes Agent
license: MIT
platforms: [macos, linux]
metadata:
  hermes:
    tags: [安全, 审计, 只读, Linux, 运维]
    related_skills: [server-harden, tailnet-audit]
---

# 服务器安全审查（只读）

对一台 Debian/Ubuntu 机器做只读体检，输出「证据 → 影响 → 怎么改 → 怎么验」的分级清单。
**这个技能永远不修改目标机**；要动手走 `server-harden`。

## When to Use

- 「这台机器安全吗」「扫一下有没有裸奔的服务」「审计一下服务器」
- 新机器上线前、给客户演示前、出了安全事件后自查
- 定期体检（建议每月一次，和 `tailnet-audit` 一起跑）

不适用：代码漏洞审计（那是 SAST 的事）、渗透测试（要授权和专门工具）。

## Prerequisites

- 目标机 SSH 可达，且你有只读权限的账号（root 或带 sudo 的账号）。
- 本机有 bash、ssh；报告用 python3 汇总。

## How to Run

```bash
# 单机
scripts/audit.sh --host root@10.0.0.10 --key ~/.ssh/deploy_ed25519 --out report.json

# 多机（清单写在 config.json，格式见 examples/hosts.example.json）
scripts/audit.sh --config hosts.json --out reports/

# 只看摘要，不落盘
scripts/audit.sh --host root@10.0.0.10 --key ~/.ssh/deploy_ed25519 --summary
```

输出：每台机一份 JSON（结构固定，便于比对历次结果）+ 终端里一份人看的摘要。

## Quick Reference

| 想查 | 看 JSON 字段 |
| --- | --- |
| 谁在监听 0.0.0.0 | `listeners_public` |
| 补丁欠多少 | `updates.pending`、`updates.security` |
| SSH 能不能密码登录 | `sshd.password_auth`、`sshd.root_login` |
| 防火墙开没开 | `firewall.active`、`firewall.default_in` |
| 有没有雷 | `findings[]`（每条带 severity/evidence/fix） |

## Procedure

1. **确认授权**：只审自己拥有或书面授权的机器；不确定就停，先问。
2. **跑采集**：命令见上。完成标准：JSON 里 `host`、`collected_at` 有值，没有 `error` 字段。
3. **看 findings**：脚本给的是候选，不是判决；每条都要能指回具体命令输出。
4. **人工补两条机器判断不了的**：这台机器上跑的业务重要程度、它存着什么凭证（有没有私钥、token、数据库口令）。
5. **出报告**：按 `references/report.md` 的结构写，P0/P1/P2 分级，未验证的写进「未验证」一节。
6. **交接**：要改的项转给 `server-harden`，每项一条，别合并成一句「加固一下」。

## Pitfalls

- **只读**：脚本里不许出现 `apt install`、`systemctl restart`、`sed -i`、`ufw allow`。
- **`ss -tlnp` 看到的 0.0.0.0 不等于公网可达**：云厂商安全组、UFW 都可能挡着，必须从外部实测（`nc -z` 公网 IP）才算数。
- **容器发布的端口会绕过 UFW**（Docker 直接写 iptables）：`docker ps` 里 `0.0.0.0:` 那种要单独算风险，别被「UFW 只开了 22/443」骗了。
- **别把密钥内容写进报告**：只记文件名、指纹、数量。
- **别用 root 的口令登录做采集**：优先密钥，其次临时账号。

## Verification

```bash
bash tests/smoke.sh                        # 脚本自身自检（不连目标机）
python3 tests/check_skill.py skills/server-audit
```

对着已知机器跑一次，报告的 `listeners_public` 应和 `ss -tlnp` 手查一致；对不上就修脚本，不是改报告。

## References

- [检查项与判据](references/checks.md)
- [报告结构与分级](references/report.md)
- [容器与云防火墙的坑](references/containers.md)
