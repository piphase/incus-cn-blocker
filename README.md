# Incus CN Blocker

这是一个偏保守的 `nftables` 方案，用来阻止 Incus 容器主动访问中国大陆 IPv4 网段，同时尽量避免影响宿主机自身网络。

## 设计目标

- 只在 `forward` 链里处理从 `incusbr0` 进入的流量，不碰宿主机的 `input` / `output`
- 首次安装时自动备份当前完整 `nftables` 规则
- 后续只维护一张自定义表：`table inet incus_cn_block`
- 支持交互式菜单，也支持命令行子命令
- 可选 `systemd timer` 定时更新中国 CIDR 缓存

## 文件说明

- `manage-incus-cn-block.sh`
  主脚本，支持安装、启用、关闭、更新、状态查询、恢复初始规则、卸载
- `incus-cn-blocker-apply.service`
  开机后用缓存重新应用规则
- `incus-cn-blocker-update.service`
  刷新中国 CIDR 缓存
- `incus-cn-blocker-update.timer`
  每 12 小时自动刷新一次缓存

## 快速开始

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
sudo ./manage-incus-cn-block.sh enable
sudo ./manage-incus-cn-block.sh disable
sudo ./manage-incus-cn-block.sh update --apply-if-enabled
sudo ./manage-incus-cn-block.sh restore-initial
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
sudo FETCH_PROXY=http://127.0.0.1:10808 ./manage-incus-cn-block.sh enable
```

也可以在安装时就指定：

```bash
sudo FETCH_PROXY=http://127.0.0.1:10808 ./manage-incus-cn-block.sh install
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
sudo BRIDGE_NAME=incusbr1 TIMER_INTERVAL=6h ./manage-incus-cn-block.sh install
```

## 当前边界

- 当前版本只处理 IPv4，不处理 IPv6
- 中国 CIDR 缓存依赖外部下载源
- 没有做“自动回滚计时器”，因为默认规则只动 `forward` 链，已经尽量把爆炸半径压小

如果你打算发到 GitHub，建议下一步再补两样东西：

- 一个 `LICENSE`
- 一个简单的 `CHANGELOG.md`
