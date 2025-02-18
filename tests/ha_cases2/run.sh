#!/bin/bash

set -eu

cur=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
source $cur/../_utils/test_prepare
WORK_DIR=$TEST_DIR/$TEST_NAME
API_VERSION="v1alpha1"
# import helper functions
source $cur/lib.sh

function test_running() {
	echo "[$(date)] <<<<<< start test_running >>>>>>"
	cleanup
	prepare_sql
	start_cluster

	# make sure task to step in "Sync" stage
	run_dm_ctl_with_retry $WORK_DIR "127.0.0.1:$MASTER_PORT3" \
		"query-status test" \
		"\"stage\": \"Running\"" 2 \
		"\"unit\": \"Sync\"" 2

	echo "use sync_diff_inspector to check full dump loader"
	check_sync_diff $WORK_DIR $cur/conf/diff_config.toml

	echo "flush logs to force rotate binlog file"
	run_sql "flush logs;" $MYSQL_PORT1 $MYSQL_PASSWORD1
	run_sql "flush logs;" $MYSQL_PORT2 $MYSQL_PASSWORD2

	echo "apply increment data before restart dm-worker to ensure entering increment phase"
	run_sql_file_withdb $cur/data/db1.increment.sql $MYSQL_HOST1 $MYSQL_PORT1 $MYSQL_PASSWORD1 $ha_test
	run_sql_file_withdb $cur/data/db2.increment.sql $MYSQL_HOST2 $MYSQL_PORT2 $MYSQL_PASSWORD2 $ha_test

	sleep 3 # wait for flush checkpoint
	echo "use sync_diff_inspector to check increment data"
	check_sync_diff $WORK_DIR $cur/conf/diff_config.toml
	echo "[$(date)] <<<<<< finish test_running >>>>>>"
}

function test_multi_task_running() {
	echo "[$(date)] <<<<<< start test_multi_task_running >>>>>>"
	cleanup
	prepare_sql_multi_task
	start_multi_tasks_cluster

	# make sure task to step in "Sync" stage
	run_dm_ctl_with_retry $WORK_DIR "127.0.0.1:$MASTER_PORT3" \
		"query-status test" \
		"\"stage\": \"Running\"" 2 \
		"\"unit\": \"Sync\"" 2
	run_dm_ctl_with_retry $WORK_DIR "127.0.0.1:$MASTER_PORT3" \
		"query-status test2" \
		"\"stage\": \"Running\"" 2 \
		"\"unit\": \"Sync\"" 2

	echo "use sync_diff_inspector to check full dump loader"
	check_sync_diff $WORK_DIR $cur/conf/diff_config.toml
	check_sync_diff $WORK_DIR $cur/conf/diff_config_multi_task.toml

	echo "flush logs to force rotate binlog file"
	run_sql "flush logs;" $MYSQL_PORT1 $MYSQL_PASSWORD1
	run_sql "flush logs;" $MYSQL_PORT2 $MYSQL_PASSWORD2

	echo "apply increment data before restart dm-worker to ensure entering increment phase"
	run_sql_file_withdb $cur/data/db1.increment.sql $MYSQL_HOST1 $MYSQL_PORT1 $MYSQL_PASSWORD1 $ha_test
	run_sql_file_withdb $cur/data/db2.increment.sql $MYSQL_HOST2 $MYSQL_PORT2 $MYSQL_PASSWORD2 $ha_test
	run_sql_file_withdb $cur/data/db1.increment.sql $MYSQL_HOST1 $MYSQL_PORT1 $MYSQL_PASSWORD1 $ha_test2
	run_sql_file_withdb $cur/data/db2.increment.sql $MYSQL_HOST2 $MYSQL_PORT2 $MYSQL_PASSWORD2 $ha_test2

	sleep 5 # wait for flush checkpoint
	echo "use sync_diff_inspector to check increment data"
	check_sync_diff $WORK_DIR $cur/conf/diff_config.toml 50 || print_debug_status
	check_sync_diff $WORK_DIR $cur/conf/diff_config_multi_task.toml 50 || print_debug_status
	echo "[$(date)] <<<<<< finish test_multi_task_running >>>>>>"
}

function print_debug_status() {
	run_dm_ctl $WORK_DIR "127.0.0.1:$MASTER_PORT3" \
		"query-status test" \
		"fail me!" 1 &&
		run_dm_ctl $WORK_DIR "127.0.0.1:$MASTER_PORT3" \
			"query-status test2" \
			"fail me!" 1 && exit 1
}

function test_pause_task() {
	echo "[$(date)] <<<<<< start test_pause_task >>>>>>"
	test_multi_task_running

	run_dm_ctl_with_retry $WORK_DIR "127.0.0.1:$MASTER_PORT" \
		"start-relay -s $SOURCE_ID1 worker1" \
		"\"result\": true" 1
	run_dm_ctl_with_retry $WORK_DIR "127.0.0.1:$MASTER_PORT" \
		"start-relay -s $SOURCE_ID2 worker2" \
		"\"result\": true" 1

	echo "start dumping SQLs into source"
	load_data $MYSQL_PORT1 $MYSQL_PASSWORD1 "a" &
	load_data $MYSQL_PORT2 $MYSQL_PASSWORD2 "b" &

	task_name=(test test2)
	for name in ${task_name[@]}; do
		echo "pause tasks $name"

		# because some SQL may running (often remove checkpoint record), pause will cause that SQL failed
		# thus `result` is not true
		run_dm_ctl $WORK_DIR "127.0.0.1:$MASTER_PORT" \
			"pause-task $name"

		# pause twice, just used to test pause by the way
		run_dm_ctl $WORK_DIR "127.0.0.1:$MASTER_PORT" \
			"pause-task $name"

		run_dm_ctl $WORK_DIR "127.0.0.1:$MASTER_PORT" \
			"query-status $name" \
			"\"stage\": \"Paused\"" 2
	done

	sleep 1

	for name in ${task_name[@]}; do
		echo "resume tasks $name"
		run_dm_ctl $WORK_DIR "127.0.0.1:$MASTER_PORT" \
			"resume-task $name" \
			"\"result\": true" 3

		# resume twice, just used to test resume by the way
		run_dm_ctl $WORK_DIR "127.0.0.1:$MASTER_PORT" \
			"resume-task $name" \
			"\"result\": true" 3

		run_dm_ctl $WORK_DIR "127.0.0.1:$MASTER_PORT" \
			"query-status $name" \
			"\"stage\": \"Running\"" 4
	done

	# waiting for syncing
	wait
	sleep 1

	echo "use sync_diff_inspector to check increment data"
	check_sync_diff $WORK_DIR $cur/conf/diff_config.toml
	check_sync_diff $WORK_DIR $cur/conf/diff_config_multi_task.toml
	echo "[$(date)] <<<<<< finish test_pause_task >>>>>>"
}

function test_stop_task() {
	echo "[$(date)] <<<<<< start test_stop_task >>>>>>"
	test_multi_task_running

	run_dm_ctl_with_retry $WORK_DIR "127.0.0.1:$MASTER_PORT" \
		"start-relay -s $SOURCE_ID1 worker1" \
		"\"result\": true" 1
	run_dm_ctl_with_retry $WORK_DIR "127.0.0.1:$MASTER_PORT" \
		"start-relay -s $SOURCE_ID2 worker2" \
		"\"result\": true" 1

	echo "start dumping SQLs into source"
	load_data $MYSQL_PORT1 $MYSQL_PASSWORD1 "a" &
	load_data $MYSQL_PORT2 $MYSQL_PASSWORD2 "b" &

	task_name=(test test2)
	task_config=(dm-task.yaml dm-task2.yaml)
	for name in ${task_name[@]}; do
		echo "stop tasks $name"
		run_dm_ctl $WORK_DIR "127.0.0.1:$MASTER_PORT" \
			"stop-task $name" \
			"\"result\": true" 3

		run_dm_ctl $WORK_DIR "127.0.0.1:$MASTER_PORT" \
			"query-status $name" \
			"\"result\": false" 1
	done

	sleep 1

	run_dm_ctl_with_retry $WORK_DIR 127.0.0.1:$MASTER_PORT2 "list-member --worker" '"stage": "bound",' 2

	for idx in $(seq 0 1); do
		echo "start tasks $cur/conf/${task_config[$idx]}"
		run_dm_ctl $WORK_DIR "127.0.0.1:$MASTER_PORT" \
			"start-task $cur/conf/${task_config[$idx]}" \
			"\"result\": true" 3 \
			"\"source\": \"$SOURCE_ID1\"" 1 \
			"\"source\": \"$SOURCE_ID2\"" 1

		run_dm_ctl $WORK_DIR "127.0.0.1:$MASTER_PORT" \
			"query-status ${task_name[$idx]}" \
			"\"stage\": \"Running\"" 4
	done

	# waiting for syncing
	wait
	sleep 1

	echo "use sync_diff_inspector to check increment data"
	check_sync_diff $WORK_DIR $cur/conf/diff_config.toml
	check_sync_diff $WORK_DIR $cur/conf/diff_config_multi_task.toml
	echo "[$(date)] <<<<<< finish test_stop_task >>>>>>"
}

function test_multi_task_reduce_and_restart_worker() {
	echo "[$(date)] <<<<<< start test_multi_task_reduce_and_restart_worker >>>>>>"
	test_multi_task_running

	echo "start dumping SQLs into source"
	load_data $MYSQL_PORT1 $MYSQL_PASSWORD1 "a" &
	load_data $MYSQL_PORT2 $MYSQL_PASSWORD2 "b" &
	load_data $MYSQL_PORT1 $MYSQL_PASSWORD1 "a" $ha_test2 &
	load_data $MYSQL_PORT2 $MYSQL_PASSWORD2 "b" $ha_test2 &
	worker_ports=($WORKER1_PORT $WORKER2_PORT $WORKER3_PORT $WORKER4_PORT $WORKER5_PORT)

	# find which worker is in use
	task_name=(test test2)
	worker_inuse=("") # such as ("worker1" "worker4")
	status=$($PWD/bin/dmctl.test DEVEL --master-addr "127.0.0.1:$MASTER_PORT" query-status test |
		grep 'worker' | awk -F: '{print $2}')
	echo $status
	for w in ${status[@]}; do
		worker_inuse=(${worker_inuse[*]} ${w:0-9:7})
		echo "find workers: ${w:0-9:7} for task: test"
	done
	echo "find all workers: ${worker_inuse[@]} (total: ${#worker_inuse[@]})"

	for idx in $(seq 1 5); do
		if [[ ! " ${worker_inuse[@]} " =~ " worker${idx} " ]]; then
			echo "restart unuse worker${idx}"

			echo "try to kill worker port ${worker_ports[$(($idx - 1))]}"
			ps aux | grep dm-worker${idx} | awk '{print $2}' | xargs kill || true
			run_dm_ctl_with_retry $WORK_DIR 127.0.0.1:$MASTER_PORT2 "list-member --worker --name=worker$idx" '"stage": "offline"' 1

			echo "start dm-worker${idx}"
			run_dm_worker $WORK_DIR/worker${idx} ${worker_ports[$(($idx - 1))]} $cur/conf/dm-worker${idx}.toml
			check_rpc_alive $cur/../bin/check_worker_online 127.0.0.1:${worker_ports[$(($idx - 1))]}
		fi
	done

	for ((i = 0; i < ${#worker_inuse[@]}; i++)); do
		wk=${worker_inuse[$i]:0-1:1}                                 # get worker id, such as ("1", "4")
		echo "try to kill worker port ${worker_ports[$(($wk - 1))]}" # get relative worker port
		ps aux | grep dm-${worker_inuse[$i]} | awk '{print $2}' | xargs kill || true
		check_port_offline ${worker_ports[$(($wk - 1))]} 20
		# just one worker was killed should be safe
		echo "${worker_inuse[$i]} was killed"
		for name in ${task_name[@]}; do
			run_dm_ctl_with_retry $WORK_DIR "127.0.0.1:$MASTER_PORT" \
				"query-status $name" \
				"\"stage\": \"Running\"" 2
		done
		if [ $i = 0 ]; then
			# waiting for syncing
			wait
			sleep 2
			echo "use sync_diff_inspector to check increment data"
			check_sync_diff $WORK_DIR $cur/conf/diff_config.toml
			check_sync_diff $WORK_DIR $cur/conf/diff_config_multi_task.toml
			echo "data checked after one worker was killed"
		fi
	done
	echo "[$(date)] <<<<<< finish test_multi_task_reduce_and_restart_worker >>>>>>"
}

function test_isolate_master_and_worker() {
	echo "[$(date)] <<<<<< start test_isolate_master_and_worker >>>>>>"

	test_multi_task_running

	# join master4 and master5
	run_dm_master $WORK_DIR/master-join4 $MASTER_PORT4 $cur/conf/dm-master-join4.toml
	check_rpc_alive $cur/../bin/check_master_online 127.0.0.1:$MASTER_PORT4
	sleep 5
	run_dm_master $WORK_DIR/master-join5 $MASTER_PORT5 $cur/conf/dm-master-join5.toml
	check_rpc_alive $cur/../bin/check_master_online 127.0.0.1:$MASTER_PORT5
	sleep 5

	master_ports=($MASTER_PORT1 $MASTER_PORT2 $MASTER_PORT3 $MASTER_PORT4 $MASTER_PORT5)
	alive=(1 2 3 4 5)

	leader=($(get_leader $WORK_DIR 127.0.0.1:${master_ports[${alive[0]} - 1]}))
	leader_idx=${leader:6}
	echo "try to isolate leader dm-master$leader_idx"
	isolate_master $leader_idx "isolate"
	for idx in "${!alive[@]}"; do
		if [[ ${alive[idx]} = $leader_idx ]]; then
			unset 'alive[idx]'
		fi
	done
	alive=("${alive[@]}")

	new_leader=($(get_leader $WORK_DIR 127.0.0.1:${master_ports[${alive[0]} - 1]}))
	new_leader_idx=${new_leader:6}
	new_leader_port=${master_ports[$new_leader_idx - 1]}
	follower_idx=${alive[0]}
	if [[ $follower_idx = $new_leader_idx ]]; then
		follower_idx=${alive[1]}
	fi

	echo "try to isolate follower dm-master$follower_idx"
	isolate_master $follower_idx "isolate"
	for idx in "${!alive[@]}"; do
		if [[ ${alive[idx]} = $follower_idx ]]; then
			unset 'alive[idx]'
		fi
	done
	alive=("${alive[@]}")

	# find which worker is in use
	task_name=(test test2)
	worker_inuse=("") # such as ("worker1" "worker4")
	status=$($PWD/bin/dmctl.test DEVEL --master-addr "127.0.0.1:$new_leader_port" query-status test |
		grep 'worker' | awk -F: '{print $2}')
	echo $status
	for w in ${status[@]}; do
		worker_inuse=(${worker_inuse[*]} ${w:0-9:7})
		echo "find workers: ${w:0-9:7} for task: test"
	done
	echo "find all workers: ${worker_inuse[@]} (total: ${#worker_inuse[@]})"

	for ((i = 0; i < ${#worker_inuse[@]}; i++)); do
		wk=${worker_inuse[$i]:0-1:1} # get worker id, such as ("1", "4")
		echo "try to isolate dm-worker$wk"
		isolate_worker $wk "isolate"
	done

	run_dm_ctl_with_retry $WORK_DIR "127.0.0.1:$new_leader_port" \
		"pause-task test" \
		"\"result\": true" 3

	run_sql "DROP TABLE if exists $ha_test.ta;" $TIDB_PORT $TIDB_PASSWORD
	run_sql "DROP TABLE if exists $ha_test.tb;" $TIDB_PORT $TIDB_PASSWORD
	load_data $MYSQL_PORT1 $MYSQL_PASSWORD1 "a" &
	load_data $MYSQL_PORT2 $MYSQL_PASSWORD2 "b" &

	run_dm_ctl_with_retry $WORK_DIR "127.0.0.1:$new_leader_port" \
		"resume-task test" \
		"\"result\": true" 3 # wait for load data wait
	wait
	sleep 3

	echo "use sync_diff_inspector to check increment data"
	check_sync_diff $WORK_DIR $cur/conf/diff_config.toml

	echo "[$(date)] <<<<<< finish test_isolate_master_and_worker >>>>>>"
}

function run() {
	test_pause_task                           # TICASE-990
	test_multi_task_reduce_and_restart_worker # TICASE-968, 994, 995, 964, 966, 979, 981, 982, 985, 986, 989, 993
	test_isolate_master_and_worker            # TICASE-934, 935, 936, 987, 992, 998, 999
	test_stop_task                            # TICASE-991, 984
}

cleanup_data $ha_test
cleanup_data $ha_test2
# also cleanup dm processes in case of last run failed
cleanup_process $*
run $*
cleanup_process $*

echo "[$(date)] <<<<<< test case $TEST_NAME success! >>>>>>"
