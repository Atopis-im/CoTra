#for round in 1 2;do 
#	date 
#	for counter in port_xmit_data port_rcv_data; do 
#		printf '%s: ' "$counter" 
#		cat "/sys/class/infiniband/mlx5_0/ports/1/counters/$counter" 
#	done 
#	sleep 10 
#done

#pid=$(pgrep -n -f '/tests/scala_anns') 
#gdb -q -batch -ex 'set pagination off' -ex 'thread apply all bt 8' -p "$pid" > "/tmp/scala_anns-$(hostname).bt" 2>&1 
#sed -n '1,240p' "/tmp/scala_anns-$(hostname).bt"

pid=$(pgrep -n -f '/tests/scala_anns') 
gdb -q -batch \
	-ex 'add-auto-load-safe-path /usr/lib64/libthread_db-1.0.so' \
       	-ex 'add-auto-load-safe-path /home/team/alg_mathlib/h00651839/tools/gcc/lib64/libstdc++.so.6.0.28-gdb.py' \
       	-ex 'set pagination off' \
       	-ex 'bt 20' \
       	-ex 'thread apply all bt 12' \
       	-p "$pid" > "/tmp/scala_anns-$(hostname)-full.bt" 2>&1 
sed -n '1,360p' "/tmp/scala_anns-$(hostname)-full.bt"
