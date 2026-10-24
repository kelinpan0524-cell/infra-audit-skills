# 回滚机制细节

## 为什么需要它

远程改 SSH 最常见的翻车：配置写错 → reload → 连接断开 → 再也进不去 → 只能开工单找机房。

本技能的做法：**先挂定时器，再改配置**。定时器在 5 分钟后无条件把备份还原并 reload sshd。改的人（或 agent）确认自己能登录之后，再手动取消定时器。

## 实现

```bash
# 1. 备份现有配置（可能不存在就建空文件）
ssh root@host 'test -f /etc/ssh/sshd_config.d/01-hardening.conf && \
  cp /etc/ssh/sshd_config.d/01-hardening.conf /tmp/sshd.bak || touch /tmp/sshd.bak'

# 2. 挂 5 分钟自动还原（transient unit，不是 cron）
ssh root@host "systemd-run --on-active=5min --unit=sshd-rollback \
  /bin/bash -c 'cp /tmp/sshd.bak /etc/ssh/sshd_config.d/01-hardening.conf 2>/dev/null || rm -f /etc/ssh/sshd_config.d/01-hardening.conf; sshd -t && systemctl reload ssh'"

# 3. 写新配置 → 语法检查 → reload
# 4. 新终端登录验证
# 5. 成功才取消
ssh root@host 'systemctl stop sshd-rollback.timer 2>/dev/null; systemctl reset-failed sshd-rollback.service 2>/dev/null'
```

## 失败时会怎样

- 配置语法错：`sshd -t` 就返回非零，脚本直接退出，不 reload，连接还活着。
- reload 后新规则把你自己挡了：5 分钟后定时器触发，配置回到原样，连接恢复。
- 机器重启：transient unit 丢失，但配置文件在重启前就是坏的——所以改配置和 reload 要一气呵成，中间别重启。

## 不该用回滚兜底的场景

- 改防火墙（回滚定时器本身也要靠网络下来，防火墙一错就全断）：改防火墙要更保守，先加放行再加拒绝。
- 改云安全组：那是控制台操作，脚本管不到。

## 验证回滚定时器是否存在

```bash
systemctl list-timers --all | grep sshd-rollback
systemctl status sshd-rollback.timer --no-pager
```
