#!/bin/bash
#set -e

INSTALL_DIR="/opt/edb/warehousepg"

CONFIG_FILE="config.sh"
source ${INSTALL_DIR}/${CONFIG_FILE}

ready_logfile="${INSTALL_DIR}/node_ready.log"

set_ready()
{
	#all nodes do this
	touch "${ready_logfile}"
}
set_tag()	    
{
	# previous script doesn't complete until NODE_INDEX is set
	if [ "${NODE_INDEX}" -gt "0" ]; then
		name_tag="${STACK}-sdw${NODE_INDEX}"
		#set the name of the segment node
		aws ec2 create-tags --resources ${INSTANCE_ID} --region ${REGION} --tags "Key=Name,Value=${name_tag}"
	fi
}
check_ready()
{
	#checks for all segment nodes to touch the ready file
	counter="0"
	echo -ne "Ready check."
	while [ "${INSTANCE_COUNT}" -ne "${counter}" ]; do
		counter="0"
		for i in $(cat ${INSTALL_DIR}/all_nodes.txt); do
			ssh_check=$(sshpass -p "${ADMIN_PASS}" ssh -o StrictHostKeyChecking=no ${ADMIN}@${i} "ls ${ready_logfile}" 2> /dev/null | wc -l)
			counter=$((counter + ssh_check))
		done
		sleep 5
		echo -ne "."
	done
	echo "."
	echo "All nodes ready for database initialization."
}

set_ready
set_tag

#on Coordinator node
if [ "${NODE_INDEX}" -eq "0" ]; then
	check_ready
fi
