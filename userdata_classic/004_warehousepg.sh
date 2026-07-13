#!/bin/bash
set -e

INSTALL_DIR="/opt/edb/warehousepg"

CONFIG_FILE="config.sh"
source ${INSTALL_DIR}/${CONFIG_FILE}

DATA_DISKS=$(cat ${INSTALL_DIR}/data_disks.txt | wc -l)
SEGMENTS_PER_DISK=$((SEGMENT_COUNT/DATA_DISKS))

echo "DATA_DISKS: ${DATA_DISKS}"
echo "SEGMENTS_PER_DISK: ${SEGMENTS_PER_DISK}"

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
cache_keys()
{
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
install_pxf()
{
	su -l ${ADMIN} -c "pxf cluster stop" || true

	PXF_DIR="/usr/local/edb-whpg7-pxf"
	PXF_CONF="${PXF_DIR}/conf"
	JAVA_HOME="/usr/lib/jvm/jre-17-openjdk"

	su -l ${ADMIN} -c "gpssh -f ${INSTALL_DIR}/all_nodes.txt \"sed -i '/pxf/ d' ~/.bashrc; echo 'export PXF_CONF=${PXF_CONF}' >> ~/.bashrc; echo 'export PATH=\"\${PATH}:${PXF_DIR}/bin\"' >> ~/.bashrc\""
	su -l ${ADMIN} -c "gpssh -f ${INSTALL_DIR}/all_nodes.txt \"sed -i '/JAVA_HOME/ d' ~/.bashrc; echo 'export JAVA_HOME=${JAVA_HOME}' >> ~/.bashrc\""

	echo "pxf cluster register"
	su -l ${ADMIN} -c "pxf cluster register"
	echo "pxf cluster start"
	su -l ${ADMIN} -c "pxf cluster start"

	count=$(su -l ${ADMIN} -c "psql -t -A -c \"select count(*) from pg_extension where extname = 'pxf'\"")
	if [ "$count" -eq "0" ]; then
		echo "psql -c \"CREATE EXTENSION pxf\""
		su -l ${ADMIN} -c "psql -c \"CREATE EXTENSION pxf\""
	else
		echo "psql -c \"ALTER EXTENSION pxf UPDATE\""
		su -l ${ADMIN} -c "psql -c \"ALTER EXTENSION pxf UPDATE\""
	fi
}
install_pgaa()
{
	su -l ${ADMIN} -c "gpconfig -c shared_preload_libraries -v 'pgaa,pgfs'"
	su -l ${ADMIN} -c "gpstop -ra"
	su -l ${ADMIN} -c "psql -c \"create extension pgaa cascade;\""
}
setup_s3()
{
	pxf_profile="/usr/local/edb-whpg7-pxf/servers/default/s3-site.xml"
	echo "<?xml version=\"1.0\" encoding=\"UTF-8\"?>" > ${pxf_profile}
	echo "<configuration>" >> ${pxf_profile}
	echo "  <property>" >> ${pxf_profile}
	echo "    <name>fs.s3a.aws.credentials.provider</name>" >> ${pxf_profile}
	echo "    <value>com.amazonaws.auth.InstanceProfileCredentialsProvider</value>" >> ${pxf_profile}
	echo "  </property>" >> ${pxf_profile}
	echo "  <property>" >> ${pxf_profile}
	echo "    <name>fs.s3a.endpoint</name>" >> ${pxf_profile}
	echo "    <value>s3.us-east-1.amazonaws.com</value>" >> ${pxf_profile}
	echo "  </property>" >> ${pxf_profile}
	echo "  <property>" >> ${pxf_profile}
	echo "    <name>fs.s3a.fast.upload</name>" >> ${pxf_profile}
	echo "    <value>true</value>" >> ${pxf_profile}
	echo "  </property>" >> ${pxf_profile}
	echo "</configuration>" >> ${pxf_profile}

	su -l ${ADMIN} -c "pxf cluster sync"
	su -l ${ADMIN} -c "pxf cluster start"
}
signal_complete()
{
	/usr/local/bin/cfn-signal --region ${REGION} --stack ${STACK} "${SIGNAL_COMPLETE_URL}"
}

set_env

if [ "${NODE_INDEX}" -eq "0" ]; then
	cache_keys
	create_directories
	create_initsystem_file
	init_system
	install_pxf
	install_pgaa
	setup_s3
fi

#all nodes need to send a signal that it is complete.
signal_complete
