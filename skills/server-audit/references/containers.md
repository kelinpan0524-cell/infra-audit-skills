# 容器与云防火墙的坑

## 1. Docker 的端口发布会绕过 UFW

`docker run -p 0.0.0.0:8080:80` 会在 iptables 的 DOCKER 链里插规则，UFW 的 INPUT 规则管不到。
所以「UFW 只放行了 22/443」不代表 8080 没暴露。

验证办法：

```bash
docker ps --format '{{.Names}}|{{.Ports}}' | grep '0.0.0.0'
# 从外部机器
nc -z -w3 <公网IP> 8080 && echo 真的开着
```

修法：把发布地址写成 `127.0.0.1:8080:80`，让 nginx 反代；或者用 `ufw-docker` 这类工具接管 DOCKER-USER 链。

## 2. 云厂商安全组是另一层

服务器上 `ufw status` 全绿，不代表公网打不通——安全组可能还没放行。
反过来，安全组放行了而 ufw 挡着，也会得到「不通」的实测结果。

审计时的口径：**以外部实测为准**，配置只作为解释。

## 3. 容器逃逸的常见面

- `--privileged`
- 挂载 `/var/run/docker.sock`
- 挂载宿主 `/` 或 `/etc`
- 内核漏洞（overlayfs、netfilter）——补丁没打就是敞着

审计时这几项各自单独记一条 P0。

## 4. 时间与日志

容器里时区错会影响日志关联；`docker logs --since` 比 `journalctl` 更直接。
