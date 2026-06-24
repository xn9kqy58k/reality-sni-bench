# Reality SNI Bench

给 VPS 本机跑的 Reality SNI 候选域名优选脚本。它只做正常 DNS、TLS 和 HTTPS 探测，用来筛出更适合做 Reality `dest` / `serverNames` 的候选域名。

## 一键运行

默认不再弹交互菜单，复制就跑，直接测 IPv4 + IPv6：

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/xn9kqy58k/reality-sni-bench/main/oneclick.sh)
```

只测 IPv4：

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/xn9kqy58k/reality-sni-bench/main/oneclick.sh) --ipv4
```

只测 IPv6：

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/xn9kqy58k/reality-sni-bench/main/oneclick.sh) --ipv6
```

追加自己的 SNI 候选后再测：

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/xn9kqy58k/reality-sni-bench/main/oneclick.sh) --add www.cloudflare.com --add www.microsoft.com
```

需要老式菜单交互时再显式加：

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/xn9kqy58k/reality-sni-bench/main/oneclick.sh) --interactive
```

## 常用参数

- `--ipv4`：只测 IPv4
- `--ipv6`：只测 IPv6
- `--dual` / `--both`：IPv4 + IPv6 都测，默认值
- `--rounds 5`：每个域名测试 5 轮，默认 3 轮
- `--add example.com`：追加一个候选域名，可重复写多次
- `--no-strict`：不强制 TLS 1.3 + 证书校验通过
- `--install-dir /opt/reality-sni-bench`：指定安装目录

也可以用管道形式：

```bash
curl -fsSL https://raw.githubusercontent.com/xn9kqy58k/reality-sni-bench/main/oneclick.sh | bash -s -- --ipv4 --rounds 5
curl -fsSL https://raw.githubusercontent.com/xn9kqy58k/reality-sni-bench/main/oneclick.sh | bash -s -- --ipv6 --rounds 5
curl -fsSL https://raw.githubusercontent.com/xn9kqy58k/reality-sni-bench/main/oneclick.sh | bash -s -- --dual --rounds 5
```

## 手动运行

```bash
git clone https://github.com/xn9kqy58k/reality-sni-bench.git
cd reality-sni-bench
cp candidates.example.txt candidates.txt
chmod +x reality-sni-bench.sh
./reality-sni-bench.sh -f candidates.txt -m both -r 5 --strict
```

## 输出

- `reality-sni-report.csv`：候选域名排名、地址族、握手耗时、TLS 1.3、证书校验、ALPN、HTTP 状态码、实际连接 IP、DNS 解析 IP。
- `reality-best-snippet.json`：分别生成 IPv4 和 IPv6 的 Reality 配置片段，需要替换 `privateKey`、`publicKey` 和 `shortIds`。

## 优选逻辑

脚本倾向选择：

- HTTPS 正常可达，证书链和主机名校验通过。
- 支持 TLS 1.3。
- ALPN 优先 `h2`，其次 `http/1.1`。
- 多轮测试成功率高。
- TLS 握手耗时低。
- HTTP 返回码不是异常 5xx 或连接失败。
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
