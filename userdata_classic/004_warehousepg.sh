#!/bin/bash
set -e

INSTALL_DIR="/opt/edb/warehousepg"

CONFIG_FILE="config.sh"
source ${INSTALL_DIR}/${CONFIG_FILE}

set_env()
{
	echo "GPHOME=/usr/edb/whpg7" >> /home/${ADMIN}/.bashrc
	echo "export GPHOME" >> /home/${ADMIN}/.bashrc
	echo "PATH=\$GPHOME/bin:\$PATH" >> /home/${ADMIN}/.bashrc
	echo "export PATH" >> /home/${ADMIN}/.bashrc
	echo "LD_LIBRARY_PATH=\$GPHOME/lib" >> /home/${ADMIN}/.bashrc
	echo "export LD_LIBRARY_PATH" >> /home/${ADMIN}/.bashrc

	if [[ "${NODE_INDEX}" -eq "0" || "${NODE_INDEX}" -eq "1" ]]; then
		echo "COORDINATOR_DATA_DIRECTORY=/data1/coordinator/gpseg-1" >> /home/${ADMIN}/.bashrc
		echo "export COORDINATOR_DATA_DIRECTORY" >> /home/${ADMIN}/.bashrc
		echo "PGDATABASE=\"${DATABASE_NAME}\"" >> /home/${ADMIN}/.bashrc
		echo "export PGDATABASE" >> /home/${ADMIN}/.bashrc
	fi

	echo "source \${GPHOME}/greenplum_path.sh" >> /home/$ADMIN/.bashrc
}
exchange_keys()
{
	rm -f /home/${ADMIN}/.ssh/id_rsa
	rm -f /home/${ADMIN}/.ssh/id_rsa.pub
	su -l ${ADMIN} -c "ssh-keygen -t rsa -N '' -f /home/${ADMIN}/.ssh/id_rsa"
	cat /home/${ADMIN}/.ssh/id_rsa.pub >> /home/${ADMIN}/.ssh/authorized_keys

	chown -R ${ADMIN}:${ADMIN} /home/$ADMIN/.ssh
	chmod 600 /home/${ADMIN}/.ssh/authorized_keys

	for node in $(cat ${INSTALL_DIR}/all_nodes.txt); do
		sshpass -p "${ADMIN_PASS}" scp -o StrictHostKeyChecking=no /home/${ADMIN}/.ssh/authorized_keys /home/${ADMIN}/.ssh/id_rsa.pub /home/${ADMIN}/.ssh/id_rsa ${ADMIN}@${node}:/home/${ADMIN}/.ssh/
	done

	#test and cache keys between coordinator and segment nodes
	for node in $(cat ${INSTALL_DIR}/all_nodes.txt); do
		su -l ${ADMIN} -c "ssh -o StrictHostKeyChecking=no ${node} 'uptime > /dev/null'"
	done

	#test and cache keys between segment and coordinator nodes
	for node in $(cat ${INSTALL_DIR}/segment_nodes.txt); do
		su -l ${ADMIN} -c "ssh ${node} \"ssh -o StrictHostKeyChecking=no cdw 'uptime > /dev/null'\""
	done
}
create_directories()
{
	su -l ${ADMIN} -c "source /home/${ADMIN}/.bashrc; export COORDINATOR_DATA_DIRECTORY=/data1/coordinator/gpseg-1; gpstop -a -M immediate" || true
	su -l ${ADMIN} -c "sudo rm -rf /data1/coordinator; mkdir /data1/coordinator; sudo chown -R ${ADMIN}:${ADMIN} /data1/coordinator"
	if [ "${INSTANCE_COUNT}" -gt "1" ]; then
		#hard code for now 
		standby_node="sdw1"
		su -l ${ADMIN} -c "ssh ${standby_node} 'sudo rm -rf /data1/coordinator; sudo mkdir /data1/coordinator; sudo chown -R ${ADMIN}:${ADMIN} /data1/coordinator'"

		#change to gpssh for better performance? 
		for segment_node in $(cat ${INSTALL_DIR}/segment_nodes.txt); do
			su -l ${ADMIN} -c "ssh ${segment_node} 'for i in \$(seq 1 ${DATA_DISKS}); do sudo rm -rf /data\${i}/primary; sudo rm -rf /data\${i}/mirror; sudo mkdir -p /data\${i}/primary; sudo mkdir -p /data\${i}/mirror; sudo chown -R ${ADMIN}:${ADMIN} /data\${i}/primary; sudo chown -R ${ADMIN}:${ADMIN} /data\${i}/mirror; done'"
		done
	else
		#no mirroring for a single node
		for segment_node in $(cat ${INSTALL_DIR}/segment_nodes.txt); do
			su -l ${ADMIN} -c "ssh ${segment_node} 'for i in \$(seq 1 ${DATA_DISKS}); do sudo rm -rf /data\${i}/primary; sudo mkdir -p /data\${i}/primary; sudo chown -R ${ADMIN}:${ADMIN} /data\${i}/primary; done'"
		done
	fi
}
create_initsystem_file()
{
	cp /usr/edb/whpg7/docs/cli_help/gpconfigs/gpinitsystem_config ${INSTALL_DIR}/gpinitsystem_config
	chown ${ADMIN}:${ADMIN} ${INSTALL_DIR}/gpinitsystem_config

	#comment out defaults
	sed -i 's/^declare/#declare/g' ${INSTALL_DIR}/gpinitsystem_config
	sed -i 's/^COORDINATOR_DIRECTORY/#COORDINATOR_DIRECTORY/g' ${INSTALL_DIR}/gpinitsystem_config
	sed -i 's/^DATABASE_NAME/#DATABASE_NAME/g' ${INSTALL_DIR}/gpinitsystem_config
	sed -i 's/^MACHINE_FILE_LIST/#MACHINE_FILE_LIST/g' ${INSTALL_DIR}/gpinitsystem_config
	sed -i 's/^COORDINATOR_PORT/#COORDINATOR_PORT/g' ${INSTALL_DIR}/gpinitsystem_config

	data_directory="declare -a DATA_DIRECTORY=( "
	mirror_data_directory="declare -a MIRROR_DATA_DIRECTORY=( "
	for d in $(seq 1 ${DATA_DISKS}); do
		for s in $(seq 1 ${SEGMENTS_PER_DISK}); do
			data_directory+="/data${d}/primary "
			mirror_data_directory+="/data${d}/mirror "
		done
	done
	data_directory+=")"
	mirror_data_directory+=")"

	#add new configs	
	echo "${data_directory}" >> ${INSTALL_DIR}/gpinitsystem_config
	echo "COORDINATOR_DIRECTORY=/data1/coordinator" >> ${INSTALL_DIR}/gpinitsystem_config
	echo "DATABASE_NAME=${DATABASE_NAME}" >> ${INSTALL_DIR}/gpinitsystem_config
	echo "MACHINE_LIST_FILE=${INSTALL_DIR}/segment_nodes.txt" >> ${INSTALL_DIR}/gpinitsystem_config
	#hard coded
	echo "COORDINATOR_PORT=5432" >> ${INSTALL_DIR}/gpinitsystem_config
	echo "HBA_HOSTNAMES=1" >> ${INSTALL_DIR}/gpinitsystem_config

	#mirrors
	if [ "${INSTANCE_COUNT}" -gt "1" ]; then
		echo "MIRROR_PORT_BASE=7000" >> ${INSTALL_DIR}/gpinitsystem_config
		echo "${mirror_data_directory}" >> ${INSTALL_DIR}/gpinitsystem_config
	fi	
	chown ${ADMIN}:${ADMIN} ${INSTALL_DIR}/gpinitsystem_config
	chown ${ADMIN}:${ADMIN} ${INSTALL_DIR}/segment_nodes.txt
	cat ${INSTALL_DIR}/gpinitsystem_config
}
init_system()
{
	parallel_processes=$((DATA_DISKS * SEGMENTS_PER_DISK))
	if [ "${INSTANCE_COUNT}" -eq "1" ]; then
		echo "single node init"
		su -l ${ADMIN} -c "source /home/${ADMIN}/.bashrc; cd /home/${ADMIN}; gpinitsystem -c ${INSTALL_DIR}/gpinitsystem_config -a -B ${parallel_processes}"
	else
		echo "cluster init"
		#hard code for now 
		standby_node="sdw1"
		su -l ${ADMIN} -c "source /home/${ADMIN}/.bashrc; cd /home/${ADMIN}; gpinitsystem -c ${INSTALL_DIR}/gpinitsystem_config -s ${standby_node} -a -B ${parallel_processes}"
	fi
}
disable_password_auth()
{
	#disable password authentication
	for node in $(cat ${INSTALL_DIR}/all_nodes.txt); do
		su -l ${ADMIN} -c "ssh ${node} 'sudo rm -f /etc/ssh/sshd_config.d/40-password-auth.conf > /dev/null'"
	done
}
signal_complete()
{
	/usr/local/bin/cfn-signal --region ${REGION} --stack ${STACK} "${SIGNAL_COMPLETE_URL}"
}

set_env

if [ "${NODE_INDEX}" -eq "0" ]; then
	exchange_keys
	create_directories
	create_initsystem_file
	init_system
	disable_password_auth
fi

#all nodes need to send a signal that it is complete.
signal_complete
