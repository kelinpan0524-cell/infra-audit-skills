# 检查项与判据

每条都写清「查什么、怎么判、为什么重要」。

## 1. 身份与补丁

- `uname -r`、`/etc/os-release`：确认发行版和内核。内核落后大版本 = 容器逃逸类漏洞没修。
- `apt list --upgradable`：总数 + `grep -i security` 的数量。安全包 > 0 即 P1，> 30 个即 P0。
- `/var/run/reboot-required`：存在说明补丁没生效。

## 2. 防火墙

- `ufw status verbose`：`Status: active` + `Default: deny (incoming)`。inactive 就是 P0（除非有安全组兜底，要外部实测确认）。
- 注意自定义放行行：`Anywhere on tailscale0`、`40000/udp` 这类整条放行，都要单独评估。

## 3. SSH

- `sshd -T` 取生效值（不是看配置文件，drop-in 会覆盖）。
- `permitrootlogin` 最好是 `no` 或 `without-password`；`passwordauthentication no`；`maxauthtries` ≤ 4。
- `authorized_keys` 行数 + 每把钥匙的指纹和注释：不认识的就是后门候选。

## 4. 监听面

- `ss -tlnp`：分清 `127.0.0.1:`、`0.0.0.0:`、`[::]:`、具体网卡地址。
- 绑 0.0.0.0 的数据库（3306/5432/6379/27017/9200）、管理面板（5000/8080/9090/15672）一律当 P0 候选。

## 5. 容器

- `docker ps --format '{{.Names}}|{{.Ports}}'`：`0.0.0.0:xxxx->` 的发布端口绕过 UFW。
- 容器以 root 跑、挂载 docker.sock、挂载宿主 `/` 都是 P0。

## 6. 账号

- `getent group sudo wheel docker`：docker 组等价 root。
- `awk -F: '$3==0' /etc/passwd`：多出来的 UID 0 都是后门。
- `last -n 20`：看异常来源 IP 和时段。

## 7. 防护与更新机制

- `systemctl is-active fail2ban`、`unattended-upgrades`。
- `systemctl is-active auditd`、`apparmor`（Ubuntu 默认有）。
- HIDS/云监控 agent（Elkeid、beszel、Wazuh）在跑是加分项，但别当唯一防线。

## 8. 证书

- `openssl s_client -connect 127.0.0.1:443 -servername <域名>` 取 `notAfter`，30 天内到期写 P1。

## 严重度口径

| 级别 | 含义 |
| --- | --- |
| P0 | 现在就能被利用，或一利用就是整机/整网 |
| P1 | 需要条件（弱口令、0day、内网位置），但影响大 |
| P2 | 最佳实践缺口，不影响立刻被攻破 |
