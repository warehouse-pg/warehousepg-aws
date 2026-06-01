#!/bin/bash
set -e

INSTALL_DIR="/opt/edb/warehousepg"

CONFIG_FILE="config.sh"
source ${INSTALL_DIR}/${CONFIG_FILE}
data_dir="/data"
s3_data_dir="/s3data"

set_env()
{
	echo "GPHOME=/usr/edb/whpg7" >> /home/${ADMIN}/.bashrc
	echo "export GPHOME" >> /home/${ADMIN}/.bashrc
	echo "PATH=\$GPHOME/bin:\$PATH" >> /home/${ADMIN}/.bashrc
	echo "export PATH" >> /home/${ADMIN}/.bashrc
	echo "LD_LIBRARY_PATH=\$GPHOME/lib" >> /home/${ADMIN}/.bashrc
	echo "export LD_LIBRARY_PATH" >> /home/${ADMIN}/.bashrc

	if [[ "${NODE_INDEX}" -eq "0" || "${NODE_INDEX}" -eq "1" ]]; then
		echo "COORDINATOR_DATA_DIRECTORY=${data_dir}/coordinator/gpseg-1" >> /home/${ADMIN}/.bashrc
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
	#execute gpstop in case this is a retry
	su -l ${ADMIN} -c "source /home/${ADMIN}/.bashrc; export COORDINATOR_DATA_DIRECTORY=${data_dir}/coordinator/gpseg-1; gpstop -a -M immediate" || true

	rm -rf ${data_dir}/coordinator
	mkdir ${data_dir}/coordinator
	rm -rf ${s3_data_dir}/coordinator
	mkdir -p ${s3_data_dir}/coordinator/gpseg-1
	rm -rf ${data_dir}/primary*; 
	mkdir -p ${data_dir}/primary
	rm -rf ${s3_data_dir}/primary* 
	mkdir -p ${s3_data_dir}/primary 

	#can't use recursive on mounts because EFS has directories/files that must be owned by root
	chown ${ADMIN}:${ADMIN} ${data_dir}
	chown ${ADMIN}:${ADMIN} ${data_dir}/coordinator
	chown ${ADMIN}:${ADMIN} ${data_dir}/primary
	chown ${ADMIN}:${ADMIN} ${s3_data_dir}
	chown ${ADMIN}:${ADMIN} ${s3_data_dir}/primary
	chown -R ${ADMIN}:${ADMIN} ${s3_data_dir}/coordinator
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
	for s in $(seq 1 ${SEGS_PER_NODE}); do
		data_directory+="${data_dir}/primary "
	done
	data_directory+=")"

	#add new configs	
	echo "${data_directory}" >> ${INSTALL_DIR}/gpinitsystem_config
	echo "COORDINATOR_DIRECTORY=${data_dir}/coordinator" >> ${INSTALL_DIR}/gpinitsystem_config
	echo "DATABASE_NAME=${DATABASE_NAME}" >> ${INSTALL_DIR}/gpinitsystem_config
	echo "MACHINE_LIST_FILE=${INSTALL_DIR}/segment_nodes.txt" >> ${INSTALL_DIR}/gpinitsystem_config
	#hard coded
	echo "COORDINATOR_PORT=5432" >> ${INSTALL_DIR}/gpinitsystem_config
	echo "HBA_HOSTNAMES=1" >> ${INSTALL_DIR}/gpinitsystem_config

	chown ${ADMIN}:${ADMIN} ${INSTALL_DIR}/gpinitsystem_config
	chown ${ADMIN}:${ADMIN} ${INSTALL_DIR}/segment_nodes.txt
	cat ${INSTALL_DIR}/gpinitsystem_config
}
init_system()
{
	parallel_processes="${SEGS_PER_NODE}"
	su -l ${ADMIN} -c "source /home/${ADMIN}/.bashrc; cd /home/${ADMIN}; gpinitsystem -c ${INSTALL_DIR}/gpinitsystem_config -a -B ${parallel_processes}"
}
move_base_dir()
{
	#stop database
	su -l ${ADMIN} -c "source /home/${ADMIN}/.bashrc; gpstop -a -M immediate" || true

	#move coordinator base directory
	echo "mv ${data_dir}/coordinator/gpseg-1/base ${s3_data_dir}/coordinator/gpseg-1/"
	mv ${data_dir}/coordinator/gpseg-1/base ${s3_data_dir}/coordinator/gpseg-1/
	echo "ln -s ${s3_data_dir}/coordinator/gpseg-1/base ${data_dir}/coordinator/gpseg-1/base"
	ln -s ${s3_data_dir}/coordinator/gpseg-1/base ${data_dir}/coordinator/gpseg-1/base

	#move segments base directories
	echo "Make base directories"
	for i in $(ls ${data_dir}/primary/); do 
		echo "mkdir ${s3_data_dir}/primary/${i}"
		mkdir ${s3_data_dir}/primary/${i}
		echo "chown ${ADMIN}:${ADMIN} ${s3_data_dir}/primary/${i}"
		chown ${ADMIN}:${ADMIN} ${s3_data_dir}/primary/${i}
	done
	echo "Move base directories"
 	for i in $(ls ${data_dir}/primary/); do 
		echo "mv ${data_dir}/primary/${i}/base ${s3_data_dir}/primary/${i}"
		mv ${data_dir}/primary/${i}/base ${s3_data_dir}/primary/${i}
	 done

	echo "Add symbolic links"
	for i in $(ls ${data_dir}/primary/); do 
		echo "ln -s ${s3_data_dir}/primary/${i}/base ${data_dir}/primary/${i}/base"
		ln -s ${s3_data_dir}/primary/${i}/base ${data_dir}/primary/${i}/base
	done

	#start database
	su -l ${ADMIN} -c "source /home/${ADMIN}/.bashrc; gpstart -a"

}
set_temp_tablespace()
{
	su -l ${ADMIN} -c "source /home/${ADMIN}/.bashrc; psql -c \"drop tablespace if exists gptemp;\""
	su -l ${ADMIN} -c "source /home/${ADMIN}/.bashrc; psql -c \"create tablespace gptemp location '/cache1/gptemp';\""
	su -l ${ADMIN} -c "source /home/${ADMIN}/.bashrc; gpconfig -c temp_tablespaces -v \"gptemp\"; gpstop -u"
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
	move_base_dir
	set_temp_tablespace
	disable_password_auth
fi

#all nodes need to send a signal that it is complete.
signal_complete
