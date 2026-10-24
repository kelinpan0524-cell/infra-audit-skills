# 三件套：服务器审查 / 加固 / Tailscale 内网审查

给 AI 助手用的安全技能包，专门照顾一种常见处境：**自己维护一两台公网服务器 + 一个 Tailscale 内网 + 一台 NAS，没有安全团队。**

三个技能分工明确，可以单独用，也能串起来：

| 技能 | 回答什么问题 | 会不会改东西 |
| --- | --- | --- |
| `server-audit` | 这台机器安全吗？哪里露着？ | 不改，只读 |
| `server-harden` | 按报告逐项改，改坏了能回滚吗？ | 改，但每步可回滚 |
| `tailnet-audit` | 公网那台被攻破后，能摸到内网哪些东西？ | 不改，只读 |

## 为什么不是「再找一个扫描器」

扫描器给你一堆漏洞编号，这三件套给你的是**能交差的结论**：

- 每条风险都带证据（哪条命令、哪行配置），没有证据的降级成「未验证」；
- 每条都写清「改完怎么验」，不是「建议加固」；
- 改配置带回滚，尤其 SSH——先挂 5 分钟自动还原，确认能登录再取消；
- 明确区分「隧道层通」和「端口层通」，这是判断内网隔离的关键，绝大多数清单都漏了这层。

## 安装

```bash
# 任意支持 skills 的助手
cp -R skills/* ~/.claude/skills/       # Claude Code
cp -R skills/* ~/.hermes/skills/       # Hermes
```

## 快速上手

```bash
# 1. 先审，不改
skills/server-audit/scripts/audit.sh --host root@203.0.113.10 --key ~/.ssh/deploy --out web.json --summary

# 2. 按报告逐项加固（一次一项）
skills/server-harden/scripts/harden.sh --host root@203.0.113.10 --key ~/.ssh/deploy --check
skills/server-harden/scripts/harden.sh --host root@203.0.113.10 --key ~/.ssh/deploy --apply fail2ban

# 3. 看内网能不能被横向
skills/tailnet-audit/scripts/tailnet-recon.sh status
skills/tailnet-audit/scripts/tailnet-recon.sh from --ssh root@203.0.113.10 --key ~/.ssh/deploy --ports 22,445,5433
```

`audit.sh` 输出固定结构的 JSON，两次跑完可以直接 diff，看有没有新开的端口、新加的账号。

## 示例报告长什么样

```json
{
  "host": "root@203.0.113.10",
  "updates": {"pending": 249, "security": 174, "reboot_required": false},
  "firewall": {"active": true, "default_in": "deny"},
  "sshd": {"password_auth": "no", "root_login": "without-password", "maxauthtries": 6},
  "listeners_public": ["0.0.0.0:80", "0.0.0.0:443", "0.0.0.0:22"],
  "findings": [
    {"severity": "P0", "issue": "待升级包 249 个", "evidence": "apt list --upgradable", "fix": "挑窗口 upgrade + 重启"}
  ]
}
```

## 安全边界

- `server-audit`、`tailnet-audit` 只读；脚本里没有 `apt install`、`sed -i`、`systemctl restart`。
- `server-harden` 只做三件事，每件都写了回滚命令；SSH 那项强制走 5 分钟自动还原。
- 只对**你自己拥有或书面授权**的机器使用。
- 报告里不写密钥内容，只记文件名和指纹。

## 自检

```bash
bash tests/smoke.sh
```

包含：三个脚本的语法检查、两个 `--self-test`（用内置样例验证解析和分级，不连机器）、三个技能文档的 frontmatter 与链接检查。

## 许可

MIT。
