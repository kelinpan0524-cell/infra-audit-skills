# ACL 要看的六件事

ACL 是一段 JSON（也可以在后台用可视化编辑器生成），审的时候按这六条过。

## 1. 默认策略：`"acls"` 是不是全放开

```json
{"acls": [{"action": "accept", "src": ["*"], "dst": ["*:*"]}]}
```

这是最坏情况：任何设备能到任何设备的任何端口。看到 `src: ["*"]` 就要重点分析「谁能拿到一台设备」。

## 2. grants 是否按 tag 划分

好的写法（按身份分）：

```json
{"grants": [
  {"src": ["tag:cloud"], "dst": ["tag:internal:443"], "ip": ["tcp"]},
  {"src": ["autogroup:member"], "dst": ["tag:nas:445,22"], "ip": ["tcp"]}
]}
```

要问的问题：`tag:cloud` 能到哪里？如果它一条 grant 都没有，那它就是个哑设备（最理想）；如果它拿到 `dst: ["*"]`，等于内网全开。

## 3. 有没有 `autogroup:internet` / exit node

`{"src": ["autogroup:member"], "dst": ["autogroup:internet:*"]}` 意味着成员可以把流量从某个 exit node 出去。出口机被打穿 = 全员的流量可被看。

## 4. `ssh` 段

```json
{"ssh": [{"action": "accept", "src": ["autogroup:member"], "dst": ["tag:nas"], "users": ["root"]}]}
```

Tailscale SSH 用身份鉴权，绕开机器自己的 authorized_keys。放开 `users: ["root"]` 且 `src` 是全员，就是「谁登录了 tailnet 谁 root」。

## 5. `tagOwners`

```json
{"tagOwners": {"tag:cloud": ["autogroup:admin"], "tag:relay": ["autogroup:admin"]}}
```

tag 谁能打，决定谁能把自己「升级」成受限更少的身份。理想是所有 tag 都只有 admin 能打。

## 6. 设备审批与密钥有效期

- 后台 → Machines：有没有开 `Manually approve new devices`（防止有人偷偷加设备）。
- 每台设备的 key expiry：永不过期 = 丢了就永久有效，建议 90-180 天。
- Tailnet Lock：开了之后，新节点必须由已有节点签名才能接入。

## 怎么拿 ACL 快照

```bash
TS_API_KEY=tskey-api-xxx scripts/tailnet-recon.sh acl --out acl.json
```

或人工：后台 → Access controls → 复制 JSON，存进私有仓库做版本记录（改之前和改之后各存一份）。
