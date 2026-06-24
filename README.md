# Reality SNI Bench

一个给 VPS 本机跑的 Reality SNI 候选域名评分脚本。它只做正常 DNS、TLS 和 HTTPS 探测，用来筛出更适合作为 Reality `dest` / `serverNames` 的候选域名。

## 快速使用

```bash
git clone <your-repo-url> reality-sni-bench
cd reality-sni-bench
cp candidates.example.txt candidates.txt
chmod +x reality-sni-bench.sh
./reality-sni-bench.sh -f candidates.txt -r 5 --strict
```

输出：

- `reality-sni-report.csv`：候选域名排名、握手耗时、TLS 1.3、证书校验、ALPN、HTTP 状态码等。
- `reality-best-snippet.json`：第一名候选域名生成的 Reality 配置片段，分成服务端 `serverInboundRealitySettings` 和客户端 `clientOutboundRealitySettings` 两段，需要你替换 `privateKey`、`publicKey` 和 `shortIds`。

## 评分思路

脚本倾向选择这些候选：

- HTTPS 正常可达，证书链和主机名校验通过。
- 支持 TLS 1.3。
- ALPN 优先 `h2`，其次 `http/1.1`。
- 多轮测试成功率高。
- TLS 握手耗时低。
- HTTP 返回码不是异常的 5xx 或连接失败。
- DNS 解析不过度发散。

## 常用参数

```bash
./reality-sni-bench.sh -f candidates.txt -r 5 -o report.csv -s best.json
./reality-sni-bench.sh -f candidates.txt --strict
./reality-sni-bench.sh -h
```

## 依赖

常见 Debian/Ubuntu VPS：

```bash
sudo apt update
sudo apt install -y curl openssl dnsutils coreutils gawk sed
```

`dig` 不是强制依赖；没有 `dig` 时会尝试 `getent`。

## 注意

不要把候选列表做成大规模公共扫描。更稳的做法是维护一份与你 VPS 所在地区、线路和业务画像相近的小候选池，然后定期复测前 10 名。
