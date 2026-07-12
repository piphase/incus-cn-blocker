# Incus CN Blocker

项目用于阻止 Incus 容器主动访问中国大陆 IPv4 网段，同时尽量避免影响宿主机自身网络。

## 一键安装

只安装，不立即启用：

```bash
curl -fsSL https://raw.githubusercontent.com/piphase/incus-cn-blocker/main/install.sh | sudo bash
```

安装后立即启用并拉取最新 CIDR：

```bash
curl -fsSL https://raw.githubusercontent.com/piphase/incus-cn-blocker/main/install.sh | sudo bash -s -- --enable
```

如果访问 GitHub 不稳定，可以带代理：

```bash
curl -fsSL https://raw.githubusercontent.com/piphase/incus-cn-blocker/main/install.sh | \
  sudo bash -s -- --enable --proxy http://127.0.0.1:10808
```

如果你的桥接名不是默认的 `incusbr0`：

```bash
curl -fsSL https://raw.githubusercontent.com/piphase/incus-cn-blocker/main/install.sh | \
  sudo bash -s -- --enable --bridge incusbr1
```

## 设计目标

- 只在 `forward` 链里处理从 `incusbr0` 进入的流量，不碰宿主机的 `input` / `output`
- 首次安装时自动备份当前完整 `nftables` 规则
- 后续只维护一张自定义表：`table inet incus_cn_block`
- 支持交互式菜单，也支持命令行子命令
- 可选 `systemd timer` 定时更新中国 CIDR 缓存

## 文件说明

- `install.sh`
  Linux 一键安装入口。适合 `curl | bash` 直接执行
- `manage-incus-cn-block.sh`
  主脚本，支持安装、启用、关闭、更新、状态查询、恢复初始规则、卸载
- `incus-cn-blocker-apply.service`
  开机后用缓存重新应用规则
- `incus-cn-blocker-update.service`
  刷新中国 CIDR 缓存
- `incus-cn-blocker-update.timer`
  每 12 小时自动刷新一次缓存

## 本地快速开始

```bash
chmod +x ./manage-incus-cn-block.sh
sudo ./manage-incus-cn-block.sh install
sudo ./manage-incus-cn-block.sh enable
sudo ./manage-incus-cn-block.sh status
```

直接运行不带参数也可以进入交互式菜单：

```bash
sudo ./manage-incus-cn-block.sh
```

## 常用命令

```bash
sudo /usr/local/sbin/incus-cn-blocker enable
sudo /usr/local/sbin/incus-cn-blocker disable
sudo /usr/local/sbin/incus-cn-blocker update --apply-if-enabled
sudo /usr/local/sbin/incus-cn-blocker restore-initial
sudo /usr/local/sbin/incus-cn-blocker status
```

## 安全模型

- `enable` 只会创建或替换 `table inet incus_cn_block`
- `disable` 只会删除这张自定义表
- `update` 只会更新缓存，并在当前状态为已启用时重新应用
- `restore-initial` 会用首次安装时的完整备份覆盖当前整套 `nftables` 规则

`restore-initial` 是高影响操作。它适合“回到最初基线”，但如果你在安装之后又手工改过宿主机防火墙，那些改动也会一起丢失。

## 数据源和代理

默认数据源：

`https://raw.githubusercontent.com/misakaio/chnroutes2/master/chnroutes.txt`

如果访问 GitHub 不稳定，可以加代理环境变量：

```bash
sudo FETCH_PROXY=http://127.0.0.1:10808 /usr/local/sbin/incus-cn-blocker enable
```

也可以在安装时就指定：

```bash
curl -fsSL https://raw.githubusercontent.com/piphase/incus-cn-blocker/main/install.sh | \
  sudo bash -s -- --proxy http://127.0.0.1:10808
```

## 可调参数

```bash
BRIDGE_NAME=incusbr1
ROUTE_URL=https://example.com/chnroutes.txt
FETCH_PROXY=http://127.0.0.1:10808
TIMER_INTERVAL=6h
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
- 中国 CIDR 缓存依赖外部下载源
- 没有做“自动回滚计时器”，因为默认规则只动 `forward` 链，已经尽量把爆炸半径压小

如果你打算发到 GitHub，建议下一步再补两样东西：

- 一个 `LICENSE`
- 一个简单的 `CHANGELOG.md`
