# Reality SNI Bench

给 VPS 本机运行的 Reality SNI 候选域名评分脚本。它只做正常 DNS、TLS 和 HTTPS 探测，用来筛出更适合作为 Reality `dest` / `serverNames` 的候选域名。

## 一键运行

交互菜单一键运行：

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/xn9kqy58k/reality-sni-bench/main/oneclick.sh)
```

菜单里可以选择：

- `1`：只测 IPv4
- `2`：只测 IPv6
- `3`：IPv4 + IPv6 都测

无交互直接跑：

```bash
curl -fsSL https://raw.githubusercontent.com/xn9kqy58k/reality-sni-bench/main/oneclick.sh | bash -s -- --mode ipv4 --rounds 5 --yes
curl -fsSL https://raw.githubusercontent.com/xn9kqy58k/reality-sni-bench/main/oneclick.sh | bash -s -- --mode ipv6 --rounds 5 --yes
curl -fsSL https://raw.githubusercontent.com/xn9kqy58k/reality-sni-bench/main/oneclick.sh | bash -s -- --mode both --rounds 5 --yes
```

也可以先克隆再运行：

```bash
git clone https://github.com/xn9kqy58k/reality-sni-bench.git
cd reality-sni-bench
bash oneclick.sh
```

## 高级用法

```bash
cp candidates.example.txt candidates.txt
chmod +x reality-sni-bench.sh
./reality-sni-bench.sh -f candidates.txt -m both -r 5 --strict
./reality-sni-bench.sh -f candidates.txt -m ipv4 -r 5 --strict
./reality-sni-bench.sh -f candidates.txt -m ipv6 -r 5 --strict
```

## 输出

- `reality-sni-report.csv`：候选域名排名、地址族、握手耗时、TLS 1.3、证书校验、ALPN、HTTP 状态码、实际连接 IP、DNS 解析 IP。
- `reality-best-snippet.json`：分别生成 IPv4 和 IPv6 的 Reality 配置片段，需要替换 `privateKey`、`publicKey` 和 `shortIds`。

## 评分思路

脚本倾向选择这些候选：

- HTTPS 正常可达，证书链和主机名校验通过。
- 支持 TLS 1.3。
- ALPN 优先 `h2`，其次 `http/1.1`。
- 多轮测试成功率高。
- TLS 握手耗时低。
- HTTP 返回码不是异常的 5xx 或连接失败。
- DNS 解析不过度发散。
- IPv4 和 IPv6 分开排名，因为同一个 SNI 在两条线路上的表现可能完全不同。

## 依赖

`oneclick.sh` 会尽量自动安装依赖。手动安装示例：

```bash
sudo apt update
sudo apt install -y curl openssl dnsutils coreutils gawk sed git
```

## 注意

不要把候选列表做成大规模公共扫描。更稳的做法是维护一份与你 VPS 所在地区、线路和业务画像相近的小候选池，然后定期复测前 10 名。
