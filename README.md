# Incus CN Blocker

这个项目用于阻止 Incus 容器主动访问中国大陆 IPv4 网段，同时尽量避免影响宿主机自身网络。

## 一键使用

默认直接进入中文交互菜单：

```bash
curl -fsSL https://raw.githubusercontent.com/piphase/incus-cn-blocker/main/install.sh | sudo bash
```

首次进入菜单前，脚本会先自动备份当前机器的 `nftables` 配置。  
即使你没有继续选择“安装”或“启用”，初始备份也会先落盘，避免后续没有回滚点。

如果你明确想跳过菜单，直接启用拦截：

```bash
curl -fsSL https://raw.githubusercontent.com/piphase/incus-cn-blocker/main/install.sh | \
  sudo bash -s -- --enable
```

如果桥接名不是默认的 `incusbr0`：

```bash
curl -fsSL https://raw.githubusercontent.com/piphase/incus-cn-blocker/main/install.sh | \
  sudo bash -s -- --bridge incusbr1
```

## 交互菜单

进入菜单后，主要选项是：

- `1` 安装/更新本地脚本与定时任务
- `2` 启用拦截
- `3` 关闭拦截
- `4` 更新中国 IPv4 数据库
- `5` 查看状态
- `6` 恢复初始 `nftables` 配置
- `99` 卸载
- `0` 退出

## 设计目标

- 只在 `forward` 链里处理从 `incusbr0` 进入的流量，不碰宿主机的 `input` / `output`
- 第一次运行时先自动备份完整 `nftables` 规则
- 后续只维护一张自定义表：`table inet incus_cn_block`
- 既支持中文交互菜单，也支持命令行子命令
- 可选 `systemd timer` 定时更新中国 IPv4 数据库

## 文件说明

- `install.sh`
  Linux 一键入口，默认拉起中文交互菜单
- `manage-incus-cn-block.sh`
  主脚本，负责安装、启用、关闭、更新、状态查询、恢复和卸载
- `incus-cn-blocker-apply.service`
  开机后用缓存重新应用规则
- `incus-cn-blocker-update.service`
  刷新中国 IPv4 数据库
- `incus-cn-blocker-update.timer`
  每 12 小时自动刷新一次数据库

## 常用命令

如果你已经通过菜单安装过本地脚本，后续也可以直接运行：

```bash
sudo /usr/local/sbin/incus-cn-blocker
sudo /usr/local/sbin/incus-cn-blocker status
sudo /usr/local/sbin/incus-cn-blocker enable
sudo /usr/local/sbin/incus-cn-blocker disable
sudo /usr/local/sbin/incus-cn-blocker update --apply-if-enabled
sudo /usr/local/sbin/incus-cn-blocker restore-initial
```

## 安全模型

- `enable` 只会创建或替换 `table inet incus_cn_block`
- `disable` 只会删除这张自定义表
- `update` 只会更新中国 IPv4 数据库，并在当前状态为已启用时重新应用
- `restore-initial` 会用第一次备份的完整规则覆盖当前整套 `nftables`

`restore-initial` 是高影响操作。  
如果你在第一次备份之后手工修改过宿主机其他防火墙规则，这些改动也会一起丢失。

## 数据源

默认数据源：

`https://raw.githubusercontent.com/misakaio/chnroutes2/master/chnroutes.txt`

## 可调参数

```bash
BRIDGE_NAME=incusbr1
ROUTE_URL=https://example.com/chnroutes.txt
TIMER_INTERVAL=6h
CACHE_MIN_PREFIXES=1000
STATE_DIR=/var/lib/incus-cn-blocker
BIN_TARGET=/usr/local/sbin/incus-cn-blocker
UNIT_DIR=/etc/systemd/system
```

示例：

```bash
curl -fsSL https://raw.githubusercontent.com/piphase/incus-cn-blocker/main/install.sh | \
  sudo bash -s -- --bridge incusbr1 --timer-interval 6h
```

## 当前边界

- 当前版本只处理 IPv4，不处理 IPv6
- 当前版本更新的是中国 IPv4 CIDR 列表，不是 MaxMind 之类的 GeoIP MMDB
- 中国网站如果走海外 CDN 节点，单靠这套 IP 级拦截无法完全覆盖
- 没有做“自动回滚计时器”，因为默认规则只动 `forward` 链，已经尽量压低爆炸半径
