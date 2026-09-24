#!/bin/bash
set -e
INSTALL_DIR="/opt/edb/warehousepg"

CONFIG_FILE="config.sh"
source ${INSTALL_DIR}/${CONFIG_FILE}

#random password which must be changed after first use. Only stored in CloudFormation Stack Output
WEM_ADMIN_PASSWORD=$(tr -dc 'A-Za-z0-9' < /dev/urandom | head -c 10)

install_clickhouse()
{
	curl -1sSLf "https://downloads.enterprisedb.com/${EDB_SUBSCRIPTION_TOKEN}/clickhouse/setup.rpm.sh" | sudo -E bash
	yum install -y edb-clickhouse-server edb-clickhouse-client
}
configure_clickhouse()
{
	conf_dir="/etc/clickhouse-server/config.d"
	conf_file="${conf_dir}/listen.xml"
	echo "creating ${conf_file}"
	echo "<clickhouse>" > ${conf_file}
	echo "    <listen_host>0.0.0.0</listen_host>" >> ${conf_file}
	echo "</clickhouse>" >> ${conf_file}
	cat ${conf_file}

	conf_dir="/etc/clickhouse-server/users.d"
	conf_file="${conf_dir}/default-password.xml"
	echo "creating ${conf_file}"
	echo "<clickhouse>" > ${conf_file}
	echo "    <users>" >> ${conf_file}
	echo "        <default>" >> ${conf_file}
	echo "            <password>${WEM_ADMIN_PASSWORD}</password>" >> ${conf_file}
	echo "        </default>" >> ${conf_file}
	echo "    </users>" >> ${conf_file}
	echo "</clickhouse>" >> ${conf_file}
	cat ${conf_file}
}
start_clickhouse()
{
	echo "systemctl daemon-reload"
	systemctl daemon-reload
	echo "systemctl restart clickhouse-server"
	systemctl restart clickhouse-server
}
configure_hba()
{	
	echo "add missing trust for segments to connect to coordinator"
	if [ "${INSTANCE_COUNT}" -gt "1" ]; then
		standby=$(head -n1 ${INSTALL_DIR}/segment_nodes.txt)
		rm -f ${INSTALL_DIR}/new_hba.txt
		for i in $(tail -n +2 ${INSTALL_DIR}/segment_nodes.txt); do
			echo "host all ${ADMIN} ${i} trust" >> ${INSTALL_DIR}/new_hba.txt
		done
		su -l ${ADMIN} -c "cat ${INSTALL_DIR}/new_hba.txt >> /data1/coordinator/gpseg-1/pg_hba.conf"
		su -l ${ADMIN} -c "scp ${INSTALL_DIR}/new_hba.txt ${standby}:${INSTALL_DIR}/new_hba.txt"
		su -l ${ADMIN} -c "ssh ${standby} 'cat ${INSTALL_DIR}/new_hba.txt >> /data1/coordinator/gpseg-1/pg_hba.conf'"
		su -l ${ADMIN} -c "gpstop -u"
	fi
}	
install_wem()
{
	echo "install wem"
	dnf install -y whpg-enterprise-manager
}
configure_wem()
{
	echo "configuring wem."
	COOKIE_SECRET=$(openssl rand -base64 32)

	wem_conf=/etc/wem/wem.conf

	count=$(su -l ${ADMIN} -c "psql -tAc \"SELECT COUNT(*) FROM pg_database WHERE datname='wem'\"")
	if [ "${count}" -eq "0" ]; then
		su -l ${ADMIN} -c "psql -c \"CREATE DATABASE wem;\""
	fi

	sed -i -E "s|^#?[[:space:]]*WHPG_HOST=.*|WHPG_HOST=cdw|" ${wem_conf}
	sed -i -E "s|^#?[[:space:]]*WHPG_PORT=.*|WHPG_PORT=5432|" ${wem_conf}
	sed -i -E "s|^#?[[:space:]]*WHPG_DATABASE=.*|WHPG_DATABASE=wem|" ${wem_conf}
	sed -i -E "s|^#?[[:space:]]*WHPG_USER=.*|WHPG_USER=${ADMIN}|" ${wem_conf}

	sed -i -E "s|^#?[[:space:]]*CLICKHOUSE_URL=.*|CLICKHOUSE_URL=clickhouse://default:${WEM_ADMIN_PASSWORD}@cdw:9000|" ${wem_conf}

	sed -i -E "s|^#?[[:space:]]*WEM_HOST=.*|WEM_HOST=cdw|" ${wem_conf}
	sed -i -E "s|^#?[[:space:]]*WEM_PORT=.*|WEM_PORT=5432|" ${wem_conf}
	sed -i -E "s|^#?[[:space:]]*WEM_DATABASE=.*|WEM_DATABASE=wem|" ${wem_conf}
	sed -i -E "s|^#?[[:space:]]*WEM_USER=.*|WEM_USER=${ADMIN}|" ${wem_conf}
	sed -i -E "s|^#?[[:space:]]*WEM_PASSWORD=.*|WEM_PASSWORD=|" ${wem_conf}

	sed -i -E "s|^#?[[:space:]]*WEM_COOKIE_SECRET=.*|WEM_COOKIE_SECRET=${COOKIE_SECRET}|" ${wem_conf}
	sed -i -E "s|^#?[[:space:]]*WEM_INSECURE_COOKIES=.*|WEM_INSECURE_COOKIES=1|" ${wem_conf}
	sed -i -E "s|^#?[[:space:]]*WEM_ADMIN_PASSWORD=.*|WEM_ADMIN_PASSWORD=${WEM_ADMIN_PASSWORD}|" ${wem_conf}

	cat ${wem_conf}
}
start_wem()
{
	echo "starting wem."
	systemctl enable wem
	systemctl restart wem
	sleep 5
	systemctl status wem --no-pager
}
install_host_agent()
{
	dnf install -y edb-acp-host-agent edb-otelcol
}
configure_host_agent()
{
	echo "configuring host agent."
	config_dir="/etc/edb/acp-host-agent"
	config_file="${config_dir}/acp-host-agent.conf"
	sed -i -E "s|^#?[[:space:]]*WEM_CONNECT_ADDRESS=.*|WEM_CONNECT_ADDRESS=cdw:8081|" ${config_file}
	cat ${config_file}
}
start_host_agent()
{
	echo "starting host agent."
	systemctl enable acp-host-agent
	systemctl restart acp-host-agent
	sleep 3
	systemctl status acp-host-agent --no-pager
}
send_cfn_signals()
{
	wem_host=$(ifconfig | grep -w inet | grep -v 127.0.0.1 | awk -F ' ' '{print $2}')
	#WEM temporary password
	cfn-signal --region $REGION --stack $STACK --id "TEMPORARY_PASSWORD" --data "${WEM_ADMIN_PASSWORD}" "${WEM_PASSWORD_SIGNAL}"

	#WEM URL
	public_ip=$(aws ec2 describe-instances --filters "Name=instance-id,Values=${INSTANCE_ID}" "Name=instance-state-name,Values=running" --query 'Reservations[].Instances[].[PublicIpAddress]' --output text)
	if [ "${public_ip}" == "" ]; then
		WEM_URL="http://${wem_host}:8080"
	else

		WEM_URL="http://${public_ip}:8080"
	fi
	cfn-signal --region $REGION --stack $STACK --id "WEM_URL" --data "${WEM_URL}" "${WEM_URL_SIGNAL}"
}
if [ "${NODE_INDEX}" -eq "0" ]; then
	install_clickhouse
	configure_clickhouse
	start_clickhouse

	install_wem
	configure_wem
	start_wem

	send_cfn_signals
fi
#host agent
install_host_agent
configure_host_agent
start_host_agent
