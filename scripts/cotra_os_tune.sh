# # 1) 先看现状（只读，不改任何东西）
# bash cotra_os_tune.sh discover

# # 2) 应用运行时调优（root，无需重启）
# sudo bash cotra_os_tune.sh apply

# # 3) 把 NIC 中断钉到非计算核（root）
# #    方式A：scala_anns 正在跑时，传它的 pid，自动避开它实际占用的核
# sudo bash cotra_os_tune.sh irq $(pgrep -x scala_anns)
# #    方式B：没在跑时，默认用最高 4 个核（96核机器→92-95，即 node3 空闲核）
# sudo bash cotra_os_tune.sh irq

# # 4) 跑的时候验证 hugepage 真被吃掉了
# bash cotra_os_tune.sh verify $(pgrep -x scala_anns)



# 1. THP 当前模式：[always] / [madvise] / [never] —— 方括号是当前值
cat /sys/kernel/mm/transparent_hugepage/enabled

# 2. 基础页大小（512MB hugepage 暗示 base=64KB，确认一下）
getconf PAGESIZE

# 3. 512MB hugepage 池里现在有几个（0=没有，且没 root 也分配不了）
grep -E 'HugePages_Total|HugePages_Free' /proc/meminfo

# 4. 节点是不是独占的？有别人在跑东西就是 straggler 大头
uptime
who
top -bn1 | head -20

# 5. 找一下真正的 search 日志在哪（你刚才 grep 没找到文件）
find ~ -name 'search-node*.log' 2>/dev/null
# 然后在找到的日志里确认那个 WARN：
# grep -r "hugepage" <日志目录>