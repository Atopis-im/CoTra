# Kunpeng ARM/RoCE 两节点运行手册

本文记录当前两节点 Kunpeng 920 环境中，从检查、编译、构建 GIST 1M
索引到执行分布式查询的完整流程。

## 1. 当前环境

| 项目 | node 0 | node 1 |
| --- | --- | --- |
| 主机名 | `agent-21` | `agent-22` |
| 管理网 IP | `71.54.52.21` | `71.54.52.22` |
| RoCE IP | `33.40.10.121` | `33.40.10.122` |
| RoCE 设备 | `mlx5_0/1` | `mlx5_0/1` |
| RoCE v2 GID index | `3` | `3` |

两个节点共用 `/home/team` 文件系统，因此源代码、数据集、构建目录和索引
输出都只保存一份。不要在两个节点上同时编译同一个构建目录。

固定路径如下：

```text
源码：/home/team/alg_mathlib/m00613325/260807/CoTra
数据：/home/team/alg_mathlib/c30061081/gist_1M_960
构建：/home/team/alg_mathlib/m00613325/260807/CoTra/build-arm-2node-agent-21
```

数据集文件：

```text
base.bin   1000000 x 960 float32
query.bin     1000 x 960 float32
gt.bin        1000 x 100
```

## 2. 每个终端的公共配置

以下变量需要在两个节点各自的运行终端中设置。`RUN_OUTPUT` 必须在两边完全
一致；每次重新构建索引建议换一个新目录，避免读取上次中断留下的文件。

```bash
cd /home/team/alg_mathlib/m00613325/260807/CoTra

export NODE1_RDMA_IP=33.40.10.122
export GID_INDEX=3

# DiskANN 索引构建使用 96 个物理核心，CoTra/RDMA 保持 8 个工作线程。
export INDEX_THREADS=96
export RDMA_THREADS=8
export OPENBLAS_NUM_THREADS=8

# 首次功能验证使用 100；正式质量测试可改回 500。
export BUILD_L=100

SHARED_BUILD_DIR="/home/team/alg_mathlib/m00613325/260807/CoTra/build-arm-2node-agent-21"
RUN_OUTPUT="/home/team/alg_mathlib/c30061081/gist_1M_960/cotra_2node_index_run4"
```

线程变量的默认行为：

- `INDEX_THREADS` 不设置时继承 `THREADS`，默认值为 `8`。
- `RDMA_THREADS` 不设置时继承 `THREADS`，默认值为 `8`。
- 不建议只设置 `THREADS=96`，否则索引和 RDMA 都会扩到 96 个线程。
- `BUILD_L` 不设置时默认 `500`，构建耗时明显高于首次验证使用的 `100`。

也可以通过 `--index-threads` 和 `--rdma-threads` 命令行参数覆盖线程数。

## 3. 更新与编译

因为源码和构建目录均为共享路径，只在 `agent-21` 执行一次：

```bash
git pull --ff-only origin codex/upstream-main-20260807

bash scripts/arm_roce_2node.sh build \
  --build-dir "$SHARED_BUILD_DIR" \
  --output-dir "$RUN_OUTPUT"
```

编译成功后确认两个程序存在：

```bash
test -x "$SHARED_BUILD_DIR/tests/scala_index"
test -x "$SHARED_BUILD_DIR/tests/scala_anns"
```

如果增量编译长时间停在 `Built target rdma_anns`，通常是在单线程编译大型
`third_party/diskann/src/index.cpp`。可检查：

```bash
ps -C cc1plus -o pid,stat,psr,pcpu,pmem,etime,wchan:32,args
```

`cc1plus` 为运行状态且 CPU 接近 `100%` 时属于正常编译。

## 4. 构建两节点索引

确保旧的 `scala_index` 和 `scala_anns` 进程已经退出。

先在 `agent-21` 执行：

```bash
bash scripts/arm_roce_2node.sh index \
  --build-dir "$SHARED_BUILD_DIR" \
  --output-dir "$RUN_OUTPUT"
```

看到 `=== TWO-NODE INDEX BUILD ===` 且进程保持运行后，再在 `agent-22`
执行完全相同的命令：

```bash
bash scripts/arm_roce_2node.sh index \
  --build-dir "$SHARED_BUILD_DIR" \
  --output-dir "$RUN_OUTPUT"
```

正确配置时，启动命令中应出现：

```text
-T 96 -t 8
```

运行日志中应出现：

```text
reset CPU num:96
OpenMP index build threads: 96
```

索引构建进度每完成 10 万个点才刷新一次，因此 `0%` 后不会连续逐点更新。
图构建阶段进程 CPU 利用率最高可接近 `9600%`，但分区、I/O、同步和合并
阶段会低于这个数值。

两个节点都必须显示以下信息并正常退出：

```text
Index build completed successfully on node 0.
Index build completed successfully on node 1.
```

索引日志位于：

```text
$RUN_OUTPUT/index-node0.log
$RUN_OUTPUT/index-node1.log
```

## 5. 检查索引文件

查询前确认两个分片和顶层索引均已生成：

```bash
ls -lh "$RUN_OUTPUT"/merged_index{0,1}_final_scala.index
ls -lh "$RUN_OUTPUT"/merged_index{0,1}_final_scala.data
ls -lh "$RUN_OUTPUT"/merged_index_top.index
```

至少以下文件必须存在且非空：

```bash
test -s "$RUN_OUTPUT/merged_index0_final_scala.index"
test -s "$RUN_OUTPUT/merged_index1_final_scala.index"
test -s "$RUN_OUTPUT/merged_index0_final_scala.data"
test -s "$RUN_OUTPUT/merged_index1_final_scala.data"
test -s "$RUN_OUTPUT/merged_index_top.index"
```

## 6. 执行两节点查询

只有在两个节点的索引命令都成功退出后才能开始查询。

先在 `agent-21` 执行：

```bash
bash scripts/arm_roce_2node.sh search \
  --build-dir "$SHARED_BUILD_DIR" \
  --output-dir "$RUN_OUTPUT"
```

看到 `=== TWO-NODE SEARCH ===` 且进程保持运行后，再在 `agent-22` 执行
相同命令：

```bash
bash scripts/arm_roce_2node.sh search \
  --build-dir "$SHARED_BUILD_DIR" \
  --output-dir "$RUN_OUTPUT"
```

两个节点都应显示：

```text
Search completed successfully on node 0.
Search completed successfully on node 1.
```

查询日志位于：

```text
$RUN_OUTPUT/search-node0.log
$RUN_OUTPUT/search-node1.log
```

汇总日志末尾的 Recall、QPS 和延迟：

```bash
tail -n 100 "$RUN_OUTPUT"/search-node{0,1}.log
```

## 7. 常见问题

### memcached 连接被拒绝

`agent-21` 是 metadata leader。它应显示：

```text
memcache clear and restart
```

`agent-22` 应显示：

```text
waiting for leader memcached at 71.54.52.21:18516
leader memcached is reachable at 71.54.52.21:18516
```

如果失败，在 `agent-21` 检查：

```bash
ss -ltnp | grep ':18516'
ps -ef | grep '[m]emcached'
```

在 `agent-22` 检查：

```bash
printf 'version\r\nquit\r\n' | nc -w 2 71.54.52.21 18516
```

### CPU 利用率只有约 200%

先确认运行的是最新编译出的程序，然后检查日志是否包含：

```text
reset CPU num:96
OpenMP index build threads: 96
```

进一步检查进程 affinity 和各线程状态：

```bash
pid=$(pgrep -n -f '/tests/scala_index')
taskset -pc "$pid"
ps -L -p "$pid" -o pid,tid,psr,pcpu,stat,wchan:24,comm \
  --sort=-pcpu | head -n 20
```

### 两节点互相等待

始终先启动 node 0，再启动 node 1。构建索引和查询不能交叉运行。如果出现
barrier timeout，保留两个节点同一阶段的完整日志，错误会打印缺失的机器 ID。
