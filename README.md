# Reality SNI Bench

VLESS/Reality SNI 候选域名测速脚本。

默认会先根据当前 VPS 出口 IP 的地区/ASN 粗筛候选，再测试 HTTPS/TLS 表现，输出 IPv4/IPv6 排名和 Reality 配置片段。

## 一键运行

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

追加候选：

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/xn9kqy58k/reality-sni-bench/main/oneclick.sh) --add example.com
```

完整慢测：

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/xn9kqy58k/reality-sni-bench/main/oneclick.sh) --full
```

## 常用参数

- `--ipv4` / `--ipv6`：只测单栈
- `--rounds 3`：每个域名测试轮数，默认快跑为 1
- `--limit 25`：限制候选数量，`--limit 0` 表示全部
- `--parallel 12`：并发数量
- `--top 3`：只显示前三个适合的唯一域名
- `--geo-prefilter` / `--no-geo-prefilter`：开启/关闭测试前地区筛选
- `--geo` / `--no-geo`：开启/关闭最终地区 ASN 加分
- `--no-cn-dns-check`：关闭国内公共 DNS 评分信号
- `--install-dir /opt/reality-sni-bench`：指定安装目录

## 输出文件

- `reality-sni-report.csv`：测速排名
- `reality-best-snippet.json`：Reality 配置片段模板

## 手动运行

```bash
git clone https://github.com/xn9kqy58k/reality-sni-bench.git
cd reality-sni-bench
cp candidates.example.txt candidates.txt
chmod +x reality-sni-bench.sh
./reality-sni-bench.sh -f candidates.txt -m both -r 3
```

## 依赖

一键脚本会尽量自动安装依赖。手动安装：

```bash
sudo apt update
sudo apt install -y curl dnsutils coreutils gawk sed git python3
```
