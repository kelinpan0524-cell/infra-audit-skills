# 各项改动的完整命令

## fail2ban（低风险）

```bash
apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y fail2ban
cat >/etc/fail2ban/jail.d/sshd.local <<'JAIL'
[sshd]
enabled = true
maxretry = 5
findtime = 10m
bantime = 1h
JAIL
systemctl enable --now fail2ban
fail2ban-client status sshd
```

回滚：`apt-get purge -y fail2ban`

## 自动安全更新（低风险，但有重启）

```bash
apt-get install -y unattended-upgrades
cat >/etc/apt/apt.conf.d/20auto-upgrades <<'CONF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
CONF
# 只留 security 源
sed -i 's|//\s*"${distro_id}:${distro_codename}-security";|"${distro_id}:${distro_codename}-security";|' \
  /etc/apt/apt.conf.d/50unattended-upgrades
# 自动重启（可选，业务机先确认窗口）
echo 'Unattended-Upgrade::Automatic-Reboot "true";' >> /etc/apt/apt.conf.d/50unattended-upgrades
echo 'Unattended-Upgrade::Automatic-Reboot-Time "04:00";' >> /etc/apt/apt.conf.d/50unattended-upgrades
systemctl restart unattended-upgrades
```

回滚：把 20auto-upgrades 里的 Unattended-Upgrade 改回 "0"。

## SSH 加固（高风险，必须带回滚）

写 `/etc/ssh/sshd_config.d/01-hardening.conf`：

```
PermitRootLogin prohibit-password
PasswordAuthentication no
PubkeyAuthentication yes
MaxAuthTries 3
LoginGraceTime 30
X11Forwarding no
AllowAgentForwarding no
```

注意 drop-in 的加载顺序：`00-` 开头的文件里如果写着 `PasswordAuthentication yes`（云镜像常见），会盖掉你的设置——用 `sshd -T` 看最终生效值，别只看自己的文件。

验证：`sshd -t` → `systemctl reload ssh` → **新开一个终端** ssh 一次。

回滚：见 `rollback.md`。

## UFW 收紧（中风险）

```bash
# 先看现有规则，把要保留的记下来
ufw status numbered

# 删掉整条网卡放行（示例：tailscale0 全通）
ufw delete allow in on tailscale0

# 只放需要的端口/来源
ufw allow from 100.64.0.0/10 to any port 22 proto tcp comment 'tailnet ssh'
```

回滚：`ufw allow in on tailscale0`。

改完立刻从**另一台机器**验证你要用的路径还在。
