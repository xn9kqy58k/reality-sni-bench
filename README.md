# Reality SNI Bench

给 VPS 本机跑的 VLESS/Reality SNI 候选域名优选脚本。它只做正常 DNS、TLS 和 HTTPS 探测，用来筛出更适合做 VLESS SNI 或 Reality `dest` / `serverNames` 的候选域名。

## 一键运行

默认不再弹交互菜单，复制就跑。脚本会先检测当前 VPS 出口地区/ASN，优先挑同 ASN、同城市、同地区或同国家的候选，再用快跑配置测 IPv4 + IPv6：前 25 个候选、每个 1 轮、不开最终 geo 加分。

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
- `--rounds 5`：每个域名测试 5 轮；一键脚本默认 1 轮
- `--limit 25`：限制候选域名数量；一键脚本默认 25，`--limit 0` 表示测全部
- `--parallel 12`：并发测试域名/地址族数量；一键脚本默认 12，网络很弱时可调低
- `--full`：完整慢测，等价于全部候选 + 3 轮 + geo 加权
- `--add example.com`：追加一个候选域名，可重复写多次
- `--full-tls-probe`：额外启用旧版 openssl ALPN 探测；更细但更慢
- `--no-strict`：不强制 TLS 1.3 + 证书校验通过
- `--geo-prefilter`：测试前按当前 VPS 出口 ASN/城市/地区/国家优先筛候选，一键脚本默认开启
- `--no-geo-prefilter`：关闭测试前地区筛选，按候选文件顺序测试
- `--geo`：开启本机出口和候选边缘 IP 的地区/ASN 加权；一键脚本默认关闭，避免首次运行大量外部查询
- `--no-geo`：关闭 geo 加权
- `--no-cn-dns-check`：关闭国内公共 DNS 预检查
- `--install-dir /opt/reality-sni-bench`：指定安装目录

也可以用管道形式：

```bash
curl -fsSL https://raw.githubusercontent.com/xn9kqy58k/reality-sni-bench/main/oneclick.sh | bash -s -- --ipv4 --rounds 5
curl -fsSL https://raw.githubusercontent.com/xn9kqy58k/reality-sni-bench/main/oneclick.sh | bash -s -- --ipv6 --rounds 5
curl -fsSL https://raw.githubusercontent.com/xn9kqy58k/reality-sni-bench/main/oneclick.sh | bash -s -- --dual --full
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

- `reality-sni-report.csv`：候选域名排名、地址族、握手耗时、TLS 1.3、证书校验、ALPN、HTTP 状态码、实际连接 IP、DNS 解析 IP、地域/ASN 加分和候选备注。
- `reality-best-snippet.json`：分别生成 IPv4 和 IPv6 的 Reality 配置片段，需要替换 `privateKey`、`publicKey` 和 `shortIds`。

## 优选逻辑

脚本分三层优选：

1. 候选池预筛：默认池只放国外大厂、云厂商、CDN、软件分发、更新服务和数据中心入口，例如 Cloudflare、Microsoft、Apple、AWS/Amazon、Adobe、Oracle、IBM、Intel、NVIDIA、Cisco、Dell、HP、VMware、Mozilla、Akamai/Fastly、Steam/Epic。避免国内 CDN、随机小 SaaS 和泛泛的 `www` 首页域名。
2. 大陆可达预筛：默认删除 Google、Meta、X、Discord、Docker、GitHub object/raw、npm、部分 Microsoft auth CDN 等大陆常见不可达或不稳定域名。一键脚本也会把旧版候选池里的国内 CDN、普通 SaaS 和旧 `www` 默认项清掉；主测试脚本会把手动塞进去的同类高风险域名直接丢弃。
3. 国内 DNS 预检查：默认用阿里 DNS、DNSPod、百度 DNS、114 DNS 做 A/AAAA 解析预检。国内公共 DNS 都解析不到的候选不进榜，避免 VPS 自己能连但国内客户端明显不合适。
4. 硬指标筛选：Reality 的 SNI 必须像正常 HTTPS 站点，所以先看 TLS 1.3、证书链/主机名校验、HTTPS 成功率、ALPN、握手耗时和 DNS 发散程度。`200/204/30x` 比 `401/403/404` 更优，`400` 这类认证接口根路径不再高分。
5. 地域/ASN 加权：脚本会检测 VPS 本机出口 IP，再对候选实际连接到的 `remote_ip` 做地理和 ASN 查询。优先级是同 ASN/同机房网络 > 同城市 > 同区域 > 同国家。结果会写入 `geo_bonus` 和 `geo_match`。
6. 推荐等级：输出 `PRIMARY / BACKUP / AVOID`，配置片段只会从非 `AVOID` 候选里取值。

现实边界：公网 HTTPS 探测无法直接知道“同一个物理机房”。脚本用可公开验证的信号近似：同 ASN/同云厂商网络最接近“同机房/同园区”，其次是同城市、同区域、同国家，再结合握手耗时和成功率排序。

更严格的大陆可达判断需要大陆探测点，例如你自己的国内探针、ITDOG/多地 HTTP 检测结果或同机场入口样本。没有大陆探测点时，脚本只能用内置风险表做默认规避。

- HTTPS 正常可达，证书链和主机名校验通过。
- 支持 TLS 1.3。
- ALPN 优先 `h2`，其次 `http/1.1`。
- 多轮测试成功率高。
- TLS 握手耗时低。
- HTTP 返回码不是异常 5xx 或连接失败。
- DNS 解析不过度发散。
- IPv4 和 IPv6 分开排名，因为同一个 SNI 在两条线路上的表现可能完全不同。

默认启用地域/ASN 加权。需要关闭时：

```bash
./reality-sni-bench.sh -f candidates.txt --no-geo
```

## 依赖

`oneclick.sh` 会尽量自动安装依赖。手动安装示例：

```bash
sudo apt update
sudo apt install -y curl openssl dnsutils coreutils gawk sed git
```

## 注意

不要把候选列表做成大规模公共扫描。更稳的做法是维护一份与你 VPS 所在地区、线路和业务画像相近的小候选池，然后定期复测前 10 名。
