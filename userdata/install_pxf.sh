#!/bin/bash
set -e
INSTALL_DIR="/opt/edb/warehousepg"
CONFIG_FILE="config.sh"

source ${INSTALL_DIR}/${CONFIG_FILE}

pxf_version="whpg7"
pxf_package="edb-${pxf_version}-pxf"

install_binaries()
{
	su -l ${ADMIN} -c "gpssh -f ${INSTALL_DIR}/all_nodes.txt \"sudo dnf install ${pxf_package} java -y\""
	su -l ${ADMIN} -c "gpssh -f ${INSTALL_DIR}/all_nodes.txt \"sudo chown ${ADMIN}:${ADMIN} -R /usr/edb/${pxf_version}; sudo chown ${ADMIN}:${ADMIN} -R /usr/local/${pxf_package}\""
}
install_pxf()
{
	su -l ${ADMIN} -c "pxf cluster stop" || true

	PXF_DIR="/usr/local/${pxf_package}"
	PXF_CONF="${PXF_DIR}/conf"
	JAVA_HOME="/usr/lib/jvm/jre-17-openjdk"

	su -l ${ADMIN} -c "gpssh -f ${INSTALL_DIR}/all_nodes.txt \"sed -i '/pxf/ d' ~/.bashrc; echo 'export PXF_CONF=${PXF_CONF}' >> ~/.bashrc; echo 'export PATH=\"\${PATH}:${PXF_DIR}/bin\"' >> ~/.bashrc\""
	su -l ${ADMIN} -c "gpssh -f ${INSTALL_DIR}/all_nodes.txt \"sed -i '/JAVA_HOME/ d' ~/.bashrc; echo 'export JAVA_HOME=${JAVA_HOME}' >> ~/.bashrc\""

	#source /home/${ADMIN}/.bashrc

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
setup_s3()
{
	pxf_profile="/usr/local/${pxf_package}/servers/default/s3-site.xml"
	echo "<?xml version=\"1.0\" encoding=\"UTF-8\"?>" > ${pxf_profile}
	echo "<configuration>" >> ${pxf_profile}
    	echo "    <property>" >> ${pxf_profile}
        echo "        <name>fs.s3a.aws.credentials.provider</name>" >> ${pxf_profile}
        echo "        <value>com.amazonaws.auth.InstanceProfileCredentialsProvider</value>" >> ${pxf_profile}
    	echo "    </property>" >> ${pxf_profile}
    	echo "    <property>" >> ${pxf_profile}
        echo "        <name>fs.s3a.endpoint</name>" >> ${pxf_profile}
        echo "        <value>s3.us-east-1.amazonaws.com</value>" >> ${pxf_profile}
    	echo "    </property>" >> ${pxf_profile}
    	echo "    <property>" >> ${pxf_profile}
        echo "        <name>fs.s3a.fast.upload</name>" >> ${pxf_profile}
        echo "        <value>true</value>" >> ${pxf_profile}
    	echo "    </property>" >> ${pxf_profile}
	echo "</configuration>" >> ${pxf_profile}

	su -l ${ADMIN} -c "pxf cluster sync"
	su -l ${ADMIN} -c "pxf cluster start"
}
install_binaries
install_pxf
setup_s3
