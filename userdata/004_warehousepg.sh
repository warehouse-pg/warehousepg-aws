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
	#execute gpstop in case this is a retry
	su -l ${ADMIN} -c "source /home/${ADMIN}/.bashrc; export COORDINATOR_DATA_DIRECTORY=${data_dir}/coordinator/gpseg-1; gpstop -a -M immediate" || true

	rm -rf ${data_dir}/coordinator
	mkdir ${data_dir}/coordinator
	rm -rf ${data_dir}/primary*; 
	mkdir -p ${data_dir}/primary
	#can't use recursive on mount because EFS has directories/files that must be owned by root
	chown ${ADMIN}:${ADMIN} ${data_dir}
	chown ${ADMIN}:${ADMIN} ${data_dir}/coordinator
	chown ${ADMIN}:${ADMIN} ${data_dir}/primary

	#default_tablespace
	rm -rf ${s3_data_dir}/whpg
	mkdir -p ${s3_data_dir}/whpg
	#can't use recursive on mount because S3Files has directories/files that must be owned by root
	chown ${ADMIN}:${ADMIN} ${s3_data_dir}
	chown ${ADMIN}:${ADMIN} ${s3_data_dir}/whpg
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
set_tablespaces()
{
	#remove files from local NVMe disks on all nodes
	su -l ${ADMIN} -c "gpssh -f ${INSTALL_DIR}/all_nodes.txt \"rm -rf /cache1/gptemp/*\""
	#drop tablespaces
	su -l ${ADMIN} -c "psql -c \"DROP TABLESPACE IF EXISTS gptemp;\""
	su -l ${ADMIN} -c "psql -c \"DROP TABLESPACE IF EXISTS s3data;\""
	#create tablespaces
	su -l ${ADMIN} -c "psql -c \"CREATE TABLESPACE gptemp LOCATION '/cache1/gptemp';\""
	su -l ${ADMIN} -c "psql -c \"CREATE TABLESPACE s3data LOCATION '/s3data/whpg';\""
	#configure whpg to use tablespaces
	su -l ${ADMIN} -c "gpconfig -c temp_tablespaces -v \"gptemp\"; gpconfig -c default_tablespace -v \"s3data\"; gpstop -u"

	#save info from catalog so local NVMe disks can be reconfigured on boot
	catalog_version=$(su -l ${ADMIN} -c "source /home/${ADMIN}/.bashrc; pg_controldata \${COORDINATOR_DATA_DIRECTORY} | grep \"Catalog version number\"" | awk -F ':' '{print $2}' | xargs)
	temp_dir="GPDB_7_${catalog_version}"
	echo "${temp_dir}" > ${s3_data_dir}/temp_dir.txt
	chown ${ADMIN}:${ADMIN} ${s3_data_dir}/temp_dir.txt
}
configure_memory()
{
	#assumes all nodes in the cluster are the same size

	#defaulting to 10
	max_concurrency="10"

	swap_size_bytes=$(free -t | grep Swap | awk -F ' ' '{print $2}')
	swap_size_mb=$((swap_size_bytes/1024))

	mem_size_bytes=$(free -t | grep Mem | awk -F ' ' '{print $2}')
	mem_size_mb=$((mem_size_bytes/1024))

	gp_vmem_mb=$(( (( (swap_size_mb + mem_size_mb) - (7500 + (mem_size_mb/20)) )*7)/10 ))
	gp_vmem_protect_limit_mb=$((gp_vmem_mb/SEGS_PER_NODE))

	max_statement_mem_mb=$(( (gp_vmem_protect_limit_mb *9)/10 ))
	statement_mem_mb=$(( max_statement_mem_mb/max_concurrency ))

	echo "gpconfig -c max_statement_mem -v \"${max_statement_mem_mb}MB\""
	su -l ${ADMIN} -c "gpconfig -c max_statement_mem -v \"${max_statement_mem_mb}MB\""

	echo "gpconfig -c statement_mem -v \"${statement_mem_mb}MB\""
	su -l ${ADMIN} -c "gpconfig -c statement_mem -v \"${statement_mem_mb}MB\""
	
	echo "gpconfig -c gp_vmem_protect_limit -v \"${gp_vmem_protect_limit_mb}\""
	su -l ${ADMIN} -c "gpconfig -c gp_vmem_protect_limit -v \"${gp_vmem_protect_limit_mb}\""

	echo "gpconfig -c gp_resource_manager -v queue"
	su -l ${ADMIN} -c "gpconfig -c gp_resource_manager -v queue"

	echo "gpstop -ra"
	su -l ${ADMIN} -c "gpstop -ra"
	echo "psql -c \"ALTER RESOURCE QUEUE pg_default WITH (ACTIVE_STATEMENTS=${max_concurrency});\""
	su -l ${ADMIN} -c "psql -c \"ALTER RESOURCE QUEUE pg_default WITH (ACTIVE_STATEMENTS=${max_concurrency});\""
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
setup_pxf_s3()
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
install_madlib()
{
	echo "/usr/local/madlib/bin/madpack -s madlib -p greenplum -c ${ADMIN}@cdw:5432/${DATABASE_NAME} install"
	su -l ${ADMIN} -c "/usr/local/madlib/bin/madpack -s madlib -p greenplum -c ${ADMIN}@cdw:5432/${DATABASE_NAME} install"
}

set_env

if [ "${NODE_INDEX}" -eq "0" ]; then
	cache_keys
	create_directories
	create_initsystem_file
	init_system
	set_tablespaces
	configure_memory
	install_pxf
	install_pgaa
	setup_pxf_s3
	install_madlib
fi
