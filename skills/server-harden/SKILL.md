---
name: server-harden
description: 按审计结果改服务器配置，每步可回滚；改 SSH 前自动挂 5 分钟还原定时器。
version: 1.0.0
author: Kelin Pan, Hermes Agent
license: MIT
platforms: [macos, linux]
metadata:
  hermes:
    tags: [安全, 加固, 回滚, SSH, Linux]
    related_skills: [server-audit, tailnet-audit]
---

# 服务器加固（每步可回滚）

只做审计报告里已经点名的项，一次一项，每项都有回滚路径。改 SSH 之前先挂一个 5 分钟后自动还原的定时器——这样即使改错、即使你失联，机器也会自己回到能登录的状态。

## When to Use

- `server-audit` 出了报告，要按 P0/P1 逐条处理
- 新机器上线前的基线加固
- 「远程改配置怕把自己锁在外面」——这正是本技能存在的理由

不适用：没有审计报告就上来改（先审后改）；生产窗口没确认就重启（先要窗口）。

## Prerequisites

- 目标机 SSH 可达，且**当前这条连接是通的**（改之前先确认）。
- 建议同时开两个终端：一个跑命令，一个留着验证能否重新登录。
- 有 sudo/root。改 SSH 需要 root。

## How to Run

```bash
# 只看要做什么，不动手
scripts/harden.sh --host root@10.0.0.10 --key ~/.ssh/deploy --check

# 逐项执行（一次一项，跑完验证再下一项）
scripts/harden.sh --host root@10.0.0.10 --key ~/.ssh/deploy --apply fail2ban
scripts/harden.sh --host root@10.0.0.10 --key ~/.ssh/deploy --apply autoupdate
scripts/harden.sh --host root@10.0.0.10 --key ~/.ssh/deploy --apply sshd-guard   # 带自动回滚
```

## Quick Reference

| 动作 | 改什么 | 回滚 |
| --- | --- | --- |
| `fail2ban` | 安装并启用 sshd jail | `apt purge fail2ban` |
| `autoupdate` | 只开 security 源，04:00 自动重启 | 改回 `/etc/apt/apt.conf.d/20auto-upgrades` |
| `sshd-guard` | 写 `01-hardening.conf`：禁密码、禁 root 直登、重试 3 次 | **5 分钟后自动还原**，或 `systemctl stop sshd-rollback.timer` 后手动还原 |

## Procedure

1. **确认现状**：`--check` 打印将要做的动作和会碰的文件。完成标准：没有一项是你不想动的。
2. **留后路**：另开一个终端保持登录；记下当前 `sshd -T` 的关键值。
3. **执行单项**：一条命令只做一件事。完成标准：命令返回成功且打印了「验证命令」。
4. **立刻验证**：新开一个终端真的 ssh 一次（不是看日志），成功才继续。
5. **确认回滚定时器已取消**（`sshd-guard` 才有）：`systemctl list-timers | grep rollback` 为空。
6. **记录**：把改了什么、怎么回滚写进当次报告。

## Pitfalls

- **不许批量刷**：一次一项。批量失败时你不知道是哪一步把门锁了。
- **`sshd -t` 是硬门槛**：新配置语法不过就别 reload，回滚定时器只是兜底。
- **云厂商控制台是最后保险**：改 SSH 前确认你有 VNC/串口/救援登录的权限。
- **UFW 里整条 `tailscale0 ALLOW`** 这种规则删之前，先想清楚有没有依赖它的备份/同步任务。
- **改名/换端口**：不要为了「安全」把 SSH 端口改到 22222 就以为解决问题，先确认安全组和监控都跟着改了。

## Verification

```bash
bash tests/smoke.sh                              # 脚本自检（不连目标机）
python3 tests/check_skill.py skills/server-harden
```

每项改完的验证命令由脚本打印；对不上就是没生效，别往下走。

## References

- [回滚机制细节](references/rollback.md)
- [各项改动的完整命令](references/playbook.md)
