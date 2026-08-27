#!/bin/bash
set -e
INSTALL_DIR="/opt/edb/warehousepg"

CONFIG_FILE="config.sh"
source ${INSTALL_DIR}/${CONFIG_FILE}

prometheus_dir="/usr/local/prometheus"
loki_dir="/usr/local/loki"
collector_dir="/var/lib/whpg-observability-collector"
collector_conf="collector.conf"

wem_conf=/etc/wem/wem.conf
wem_bin=/usr/local/greenplum-db/wem
wem_host=$(ifconfig | grep -w inet | grep -v 127.0.0.1 | awk -F ' ' '{print $2}')

host_agent_conf=/etc/edb/acp-host-agent/acp-host-agent.conf

#random password which must be changed after first use. Only stored in CloudFormation Stack Output
WEM_ADMIN_PASSWORD=$(tr -dc 'A-Za-z0-9' < /dev/urandom | head -c 10)

install_prometheus()
{
	mkdir -p ${prometheus_dir}
	curl -LO https://github.com/prometheus/prometheus/releases/download/v3.14.0/prometheus-3.14.0.linux-amd64.tar.gz --output-dir ${INSTALL_DIR}
	tar xvf ${INSTALL_DIR}/prometheus-3.14.0.linux-amd64.tar.gz --strip-components=1 -C ${prometheus_dir}
	rm ${INSTALL_DIR}/prometheus-3.14.0.linux-amd64.tar.gz
	chown -R ${ADMIN}:${ADMIN} ${prometheus_dir}
}
configure_prometheus()
{
	prometheus_yml="prometheus.yml"
	echo "configuring prometheus."
	echo "global:" > ${prometheus_dir}/${prometheus_yml}
	echo "  scrape_interval: 30s" >> ${prometheus_dir}/${prometheus_yml}
	echo "  evaluation_interval: 30s" >> ${prometheus_dir}/${prometheus_yml}
	echo "scrape_configs:" >> ${prometheus_dir}/${prometheus_yml}
	echo "  - job_name: 'wem'" >> ${prometheus_dir}/${prometheus_yml}
	echo "    static_configs:" >> ${prometheus_dir}/${prometheus_yml}
	echo "      - targets: ['localhost:8080']" >> ${prometheus_dir}/${prometheus_yml}
	echo "    metrics_path: /prom/metrics" >> ${prometheus_dir}/${prometheus_yml}
	echo "    scrape_interval: 15s" >> ${prometheus_dir}/${prometheus_yml}
	cat ${prometheus_dir}/${prometheus_yml}
	chown ${ADMIN}:${ADMIN} ${prometheus_dir}/${prometheus_yml}
}
create_prometheus_service()
{
	startup_service="prometheus.service"
	echo "[Unit]" > ${INSTALL_DIR}/${startup_service}
	echo "Description=Prometheus monitoring server" >> ${INSTALL_DIR}/${startup_service}
	echo "After=network-online.target" >> ${INSTALL_DIR}/${startup_service}
	echo "Wants=network-online.target" >> ${INSTALL_DIR}/${startup_service}
	echo "" >> ${INSTALL_DIR}/${startup_service}
	echo "[Service]" >> ${INSTALL_DIR}/${startup_service}
	echo "Type=simple" >> ${INSTALL_DIR}/${startup_service}
	echo "User=${ADMIN}" >> ${INSTALL_DIR}/${startup_service}
	echo "Group=${ADMIN}" >> ${INSTALL_DIR}/${startup_service}
	echo "ExecStart=${prometheus_dir}/prometheus --config.file=${prometheus_dir}/prometheus.yml --web.enable-remote-write-receiver --storage.tsdb.path=${prometheus_dir}/data --web.listen-address=:9095" >> ${INSTALL_DIR}/${startup_service}
	echo "Restart=on-failure" >> ${INSTALL_DIR}/${startup_service}
	echo "RestartSec=5" >> ${INSTALL_DIR}/${startup_service}
	echo "" >> ${INSTALL_DIR}/${startup_service}
	echo "[Install]" >> ${INSTALL_DIR}/${startup_service}
	echo "WantedBy=multi-user.target" >> ${INSTALL_DIR}/${startup_service}
	chmod 644 ${INSTALL_DIR}/${startup_service}
	cat ${INSTALL_DIR}/${startup_service}
	cp ${INSTALL_DIR}/${startup_service} /etc/systemd/system/${startup_service}
	systemctl daemon-reload
	systemctl enable ${startup_service}
	systemctl restart ${startup_service}
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
		su -l ${ADMIN} -c "cat ${INSTALL_DIR}/new_hba.txt >> /data/coordinator/gpseg-1/pg_hba.conf"
		su -l ${ADMIN} -c "scp ${INSTALL_DIR}/new_hba.txt ${standby}:${INSTALL_DIR}/new_hba.txt"
		su -l ${ADMIN} -c "ssh ${standby} 'cat ${INSTALL_DIR}/new_hba.txt >> /data/coordinator/gpseg-1/pg_hba.conf'"
		su -l ${ADMIN} -c "gpstop -u"
	fi
}	
install_loki()
{
	mkdir -p ${loki_dir}/data/chunks ${loki_dir}/data/rules
	curl -LO https://github.com/grafana/loki/releases/download/v3.7.6/loki-linux-amd64.zip --output-dir ${INSTALL_DIR}
	unzip ${INSTALL_DIR}/loki-linux-amd64.zip -d ${loki_dir}
	mv ${loki_dir}/loki-linux-amd64 ${loki_dir}/loki
	chmod +x ${loki_dir}/loki
	rm ${INSTALL_DIR}/loki-linux-amd64.zip
	chown -R ${ADMIN}:${ADMIN} ${loki_dir}
}
configure_loki()
{
	loki_yml="loki-local-config.yaml"
	echo "configuring loki."
	echo "auth_enabled: false" > ${loki_dir}/${loki_yml}
	echo "" >> ${loki_dir}/${loki_yml}
	echo "server:" >> ${loki_dir}/${loki_yml}
	echo "  http_listen_port: 3100" >> ${loki_dir}/${loki_yml}
	echo "  grpc_listen_port: 9096" >> ${loki_dir}/${loki_yml}
	echo "  log_level: info" >> ${loki_dir}/${loki_yml}
	echo "  grpc_server_max_concurrent_streams: 1000" >> ${loki_dir}/${loki_yml}
	echo "" >> ${loki_dir}/${loki_yml}
	echo "common:" >> ${loki_dir}/${loki_yml}
	echo "  instance_addr: 127.0.0.1" >> ${loki_dir}/${loki_yml}
	echo "  path_prefix: ${loki_dir}/data" >> ${loki_dir}/${loki_yml}
	echo "  storage:" >> ${loki_dir}/${loki_yml}
	echo "    filesystem:" >> ${loki_dir}/${loki_yml}
	echo "      chunks_directory: ${loki_dir}/data/chunks" >> ${loki_dir}/${loki_yml}
	echo "      rules_directory: ${loki_dir}/data/rules" >> ${loki_dir}/${loki_yml}
	echo "  replication_factor: 1" >> ${loki_dir}/${loki_yml}
	echo "  ring:" >> ${loki_dir}/${loki_yml}
	echo "    kvstore:" >> ${loki_dir}/${loki_yml}
	echo "      store: inmemory" >> ${loki_dir}/${loki_yml}
	echo "" >> ${loki_dir}/${loki_yml}
	echo "query_range:" >> ${loki_dir}/${loki_yml}
	echo "  results_cache:" >> ${loki_dir}/${loki_yml}
	echo "    cache:" >> ${loki_dir}/${loki_yml}
	echo "      embedded_cache:" >> ${loki_dir}/${loki_yml}
	echo "        enabled: true" >> ${loki_dir}/${loki_yml}
	echo "        max_size_mb: 100" >> ${loki_dir}/${loki_yml}
	echo "" >> ${loki_dir}/${loki_yml}
	echo "limits_config:" >> ${loki_dir}/${loki_yml}
	echo "  metric_aggregation_enabled: true" >> ${loki_dir}/${loki_yml}
	echo "  enable_multi_variant_queries: true" >> ${loki_dir}/${loki_yml}
	echo "" >> ${loki_dir}/${loki_yml}
	echo "schema_config:" >> ${loki_dir}/${loki_yml}
	echo "  configs:" >> ${loki_dir}/${loki_yml}
	echo "    - from: 2020-10-24" >> ${loki_dir}/${loki_yml}
	echo "      store: tsdb" >> ${loki_dir}/${loki_yml}
	echo "      object_store: filesystem" >> ${loki_dir}/${loki_yml}
	echo "      schema: v13" >> ${loki_dir}/${loki_yml}
	echo "      index:" >> ${loki_dir}/${loki_yml}
	echo "        prefix: index_" >> ${loki_dir}/${loki_yml}
	echo "        period: 24h" >> ${loki_dir}/${loki_yml}
	echo "" >> ${loki_dir}/${loki_yml}
	echo "pattern_ingester:" >> ${loki_dir}/${loki_yml}
	echo "  enabled: true" >> ${loki_dir}/${loki_yml}
	echo "  metric_aggregation:" >> ${loki_dir}/${loki_yml}
	echo "    loki_address: localhost:3100" >> ${loki_dir}/${loki_yml}
	echo "" >> ${loki_dir}/${loki_yml}
	echo "ruler:" >> ${loki_dir}/${loki_yml}
	echo "  alertmanager_url: http://localhost:9093" >> ${loki_dir}/${loki_yml}
	echo "" >> ${loki_dir}/${loki_yml}
	echo "frontend:" >> ${loki_dir}/${loki_yml}
	echo "  encoding: protobuf" >> ${loki_dir}/${loki_yml}
	cat ${loki_dir}/${loki_yml}
	chown ${ADMIN}:${ADMIN} ${loki_dir}/${loki_yml}
}
create_loki_service()
{
	startup_service="loki.service"
	echo "[Unit]" > ${INSTALL_DIR}/${startup_service}
	echo "Description=Loki log aggregation server" >> ${INSTALL_DIR}/${startup_service}
	echo "After=network-online.target" >> ${INSTALL_DIR}/${startup_service}
	echo "Wants=network-online.target" >> ${INSTALL_DIR}/${startup_service}
	echo "" >> ${INSTALL_DIR}/${startup_service}
	echo "[Service]" >> ${INSTALL_DIR}/${startup_service}
	echo "Type=simple" >> ${INSTALL_DIR}/${startup_service}
	echo "User=${ADMIN}" >> ${INSTALL_DIR}/${startup_service}
	echo "Group=${ADMIN}" >> ${INSTALL_DIR}/${startup_service}
	echo "ExecStart=${loki_dir}/loki -config.file=${loki_dir}/loki-local-config.yaml" >> ${INSTALL_DIR}/${startup_service}
	echo "Restart=on-failure" >> ${INSTALL_DIR}/${startup_service}
	echo "RestartSec=5" >> ${INSTALL_DIR}/${startup_service}
	echo "" >> ${INSTALL_DIR}/${startup_service}
	echo "[Install]" >> ${INSTALL_DIR}/${startup_service}
	echo "WantedBy=multi-user.target" >> ${INSTALL_DIR}/${startup_service}
	chmod 644 ${INSTALL_DIR}/${startup_service}
	cat ${INSTALL_DIR}/${startup_service}
	cp ${INSTALL_DIR}/${startup_service} /etc/systemd/system/${startup_service}
	systemctl daemon-reload
	systemctl enable ${startup_service}
	systemctl restart ${startup_service}
}
install_collector()
{
	dnf install -y edb-whpg-observability-collector
	chown -R ${ADMIN}:${ADMIN} ${collector_dir}
}
configure_collector()
{
	echo "configuring collector."
	sed -i -E "s|^#[[:space:]]*WHPG_OBS_DSN=.*|WHPG_OBS_DSN=\"host=cdw port=5432 dbname=${DATABASE_NAME} user=${ADMIN} sslmode=disable\"|" ${collector_dir}/${collector_conf}
	sed -i -E "s|^#[[:space:]]*LOKI_ENDPOINT=.*|LOKI_ENDPOINT=\"http://cdw:3100/loki/api/v1/push\"|" ${collector_dir}/${collector_conf}
	sed -i -E "s|^#[[:space:]]*PROMETHEUS_ENDPOINT=.*|PROMETHEUS_ENDPOINT=\"http://cdw:9095/api/v1/write\"|" ${collector_dir}/${collector_conf}
	cat ${collector_dir}/${collector_conf}
}
wait_for_loki()
{
	echo -ne "waiting for loki to become ready..."
	status="404"
	while [ "${status}" != "200" ]; do
		echo -ne "."
		sleep 10
		status=$(curl -s -o /dev/null -w "%{http_code}" http://cdw:3100/ready || true)
	done
	echo "."
}
start_collector()
{
	echo "starting collector."
	wait_for_loki
	su -l ${ADMIN} -c "cd ${collector_dir} && ./deploy-observability"
	sleep 2
	systemctl enable alloy
	systemctl status alloy --no-pager || true
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

	count=$(su -l ${ADMIN} -c "psql -tAc \"SELECT COUNT(*) FROM pg_database WHERE datname='wem'\"")
	if [ "${count}" -eq "0" ]; then
		su -l ${ADMIN} -c "psql -c \"CREATE DATABASE wem;\""
	fi

	sed -i -E "s|^#?[[:space:]]*WHPG_HOST=.*|WHPG_HOST=localhost|" ${wem_conf}
	sed -i -E "s|^#?[[:space:]]*WHPG_PORT=.*|WHPG_PORT=5432|" ${wem_conf}
	sed -i -E "s|^#?[[:space:]]*WHPG_DATABASE=.*|WHPG_DATABASE=${DATABASE_NAME}|" ${wem_conf}
	sed -i -E "s|^#?[[:space:]]*WHPG_USER=.*|WHPG_USER=${ADMIN}|" ${wem_conf}

	sed -i -E "s|^#?[[:space:]]*PROMETHEUS_URL=.*|PROMETHEUS_URL=http://localhost:9095|" ${wem_conf}
	sed -i -E "s|^#?[[:space:]]*LOKI_URL=.*|LOKI_URL=http://localhost:3100|" ${wem_conf}

	sed -i -E "s|^#?[[:space:]]*WEM_HOST=.*|WEM_HOST=localhost|" ${wem_conf}
	sed -i -E "s|^#?[[:space:]]*WEM_PORT=.*|WEM_PORT=5432|" ${wem_conf}
	sed -i -E "s|^#?[[:space:]]*WEM_DATABASE=.*|WEM_DATABASE=wem|" ${wem_conf}
	sed -i -E "s|^#?[[:space:]]*WEM_USER=.*|WEM_USER=${ADMIN}|" ${wem_conf}
	sed -i -E "s|^#?[[:space:]]*WEM_PASSWORD=.*|WEM_PASSWORD=|" ${wem_conf}

	sed -i -E "s|^#?[[:space:]]*WEM_COOKIE_SECRET=.*|WEM_COOKIE_SECRET=${COOKIE_SECRET}|" ${wem_conf}
	sed -i -E "s|^#?[[:space:]]*WEM_INSECURE_COOKIES=.*|WEM_INSECURE_COOKIES=1|" ${wem_conf}
	sed -i -E "s|^#?[[:space:]]*WEM_ADMIN_PASSWORD=.*|WEM_ADMIN_PASSWORD=${WEM_ADMIN_PASSWORD}|" ${wem_conf}

	# host agent (HBA editor, etc.) needs a real externally-reachable callback URL,
	# not localhost - this must match how you actually access the WEM UI
	if grep -q '^#\?[[:space:]]*WEM_AGENT_CALLBACK_BASE_URL=' ${wem_conf}; then
		sed -i -E "s|^#?[[:space:]]*WEM_AGENT_CALLBACK_BASE_URL=.*|WEM_AGENT_CALLBACK_BASE_URL=http://${wem_host}:8080|" ${wem_conf}
	else
		echo "WEM_AGENT_CALLBACK_BASE_URL=http://${wem_host}:8080" >> ${wem_conf}
	fi

	cat ${wem_conf}
}
fix_plpython()
{
	echo "checking plpython3u language registration in ${DATABASE_NAME}..."
	count=$(su -l ${ADMIN} -c "psql -d ${DATABASE_NAME} -tAc \"SELECT COUNT(*) FROM pg_extension WHERE extname='plpython3u'\"")
	if [ "${count}" -eq "0" ]; then
		echo "plpython3u exists as a bare language, not an extension - converting."
		su -l ${ADMIN} -c "psql -d ${DATABASE_NAME} -c \"CREATE EXTENSION plpython3u FROM unpackaged;\""
	else
		echo "plpython3u is already a proper extension, nothing to do."
	fi
}
preflight_check()
{
	echo "running pre-flight setup check."
	set -a
	source ${wem_conf}
	set +a
	if ! ${wem_bin}/wem setup --non-interactive; then
		echo "ERROR: wem setup pre-flight check failed. See output above."
		exit 1
	fi
}
start_wem()
{
	echo "starting wem."
	systemctl enable wem
	systemctl restart wem
	sleep 5
	systemctl status wem --no-pager
}
verify_wem()
{
	echo "verifying wem."
	set -a
	source ${wem_conf}
	set +a
	${wem_bin}/wem setup --verify
	${wem_bin}/wem doctor || true
	echo ""
	echo "Note: TLS negotiation and cookie-security findings above are expected in this demo (no TLS/HTTPS configured)."
	echo "Note: 'wem.dashboard_users'/'wem.canary_checks' schema findings are a known false positive of 'wem doctor' when WEM_DATABASE is a separate dedicated database from WHPG_DATABASE (as it is here) - 'wem setup --verify' above is the authoritative check and already confirmed these tables exist."
}
install_host_agent()
{
	dnf install -y edb-acp-host-agent
}
configure_host_agent()
{
	echo "configuring host agent."
	sed -i -E "s|^#?[[:space:]]*WEM_TASK_QUEUES=.*|WEM_TASK_QUEUES=coordinator-tasks|" ${host_agent_conf}
	sed -i -E "s|^#?[[:space:]]*WEM_CONNECT_ADDRESS=.*|WEM_CONNECT_ADDRESS=${wem_host}:8081|" ${host_agent_conf}
	sed -i -E "s|^#?[[:space:]]*WEM_DATABASE=.*|WEM_DATABASE=wem|" ${host_agent_conf}
	cat ${host_agent_conf}
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
	#prometheus
	install_prometheus
	configure_prometheus
	create_prometheus_service

	#pg_hba
	configure_hba

	#loki
	install_loki
	configure_loki
	create_loki_service

	#wem 
	install_wem
	configure_wem
	fix_plpython
	preflight_check
	start_wem
	verify_wem

	#host agent
	install_host_agent
	configure_host_agent
	start_host_agent
	send_cfn_signals
fi
#collector on all nodes
install_collector
configure_collector
start_collector
