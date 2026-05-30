#!/bin/bash
set -e
INSTALL_DIR="/opt/edb/warehousepg"

CONFIG_FILE="config.sh"
source ${INSTALL_DIR}/${CONFIG_FILE}

set_os_params()
{
	#these yum statements take a while so comment out for now
	#yum check-update || true
	#yum update -y
	dnf install libevent sshpass gcc kernel-devel m4 flex wget zip bzip2 krb5-devel xfsdump expect cloud-init tk bc psmisc cloud-init epel-release -y
	dnf install python3-pip -y
	pip3 install https://s3.amazonaws.com/cloudformation-examples/aws-cfn-bootstrap-py3-latest.tar.gz
	count=$(cat /etc/passwd | grep ${ADMIN} | wc -l)
	if [ "${count}" -eq "0" ]; then
		echo "add ${ADMIN} user"
		useradd -r -m ${ADMIN}
		echo "${ADMIN} ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/91-warehousepg
		chmod 0400 /etc/sudoers.d/91-warehousepg
	fi
	echo "${ADMIN}:${ADMIN_PASS}" | chpasswd
	mkdir -p ~gpadmin/.ssh
	chown -R gpadmin:gpadmin ~gpadmin/.ssh
	sed -i 's/SELINUX=enforcing/SELINUX=disabled/g' /etc/selinux/config
	sed -i 's/SELINUX=permissive/SELINUX=disabled/g' /etc/selinux/config
	setenforce 0
	sed -i 's/selinux=1/selinux=0/g' /etc/default/grub
	grubby --update-kernel=ALL --args="transparent_hugepage=never"
	echo never > /sys/kernel/mm/transparent_hugepage/enabled
	echo never > /sys/kernel/mm/transparent_hugepage/defrag
	sed -i '/MaxStartups/d' /etc/ssh/sshd_config
	echo "MaxStartups 10000" >> /etc/ssh/sshd_config
	sed -i '/MaxSessions/d' /etc/ssh/sshd_config
	echo "MaxSessions 10000" >> /etc/ssh/sshd_config
	#override the default of not allowing password authentication
	echo "PasswordAuthentication yes" > /etc/ssh/sshd_config.d/40-password-auth.conf
	service sshd restart
	sleep 5

	#sysctl.conf
	PAGE_SIZE=$(getconf PAGE_SIZE)
	PHYSICAL_PAGES=$(getconf _PHYS_PAGES)
	shmall=$((PHYSICAL_PAGES / 2))
	shmmax=$(((PHYSICAL_PAGES / 2) * PAGE_SIZE)) 

	echo "kernel.shmall = ${shmall}" >> /etc/sysctl.conf
	echo "kernel.shmmax = ${shmmax}" >> /etc/sysctl.conf
	echo "kernel.shmmni = 4096" >> /etc/sysctl.conf
	echo "vm.overcommit_memory = 2" >> /etc/sysctl.conf
	echo "vm.overcommit_ratio = 95" >> /etc/sysctl.conf
	echo "net.ipv4.ip_local_port_range = 10000 65535" >> /etc/sysctl.conf
	echo "kernel.sem = 250 2048000 200 8192" >> /etc/sysctl.conf
	echo "kernel.sysrq = 1" >> /etc/sysctl.conf
	echo "kernel.core_uses_pid = 1" >> /etc/sysctl.conf
	echo "kernel.msgmnb = 65536" >> /etc/sysctl.conf
	echo "kernel.msgmax = 65536" >> /etc/sysctl.conf
	echo "kernel.msgmni = 2048" >> /etc/sysctl.conf
	echo "net.ipv4.tcp_syncookies = 1" >> /etc/sysctl.conf
	echo "net.ipv4.conf.default.accept_source_route = 0" >> /etc/sysctl.conf
	echo "net.ipv4.tcp_max_syn_backlog = 4096" >> /etc/sysctl.conf
	echo "net.ipv4.conf.all.arp_filter = 1" >> /etc/sysctl.conf
	echo "net.ipv4.ipfrag_high_thresh = 41943040" >> /etc/sysctl.conf
	echo "net.ipv4.ipfrag_low_thresh = 31457280" >> /etc/sysctl.conf
	echo "net.ipv4.ipfrag_time = 60" >> /etc/sysctl.conf
	echo "net.core.netdev_max_backlog = 10000" >> /etc/sysctl.conf
	echo "net.core.rmem_max = 2097152" >> /etc/sysctl.conf
	echo "net.core.wmem_max = 2097152" >> /etc/sysctl.conf
	echo "vm.swappiness = 10" >> /etc/sysctl.conf
	echo "vm.zone_reclaim_mode = 0" >> /etc/sysctl.conf
	echo "vm.dirty_expire_centisecs = 500" >> /etc/sysctl.conf
	echo "vm.dirty_writeback_centisecs = 100" >> /etc/sysctl.conf
	echo "vm.dirty_background_ratio = 0" >> /etc/sysctl.conf
	echo "vm.dirty_ratio = 0" >> /etc/sysctl.conf
	echo "vm.dirty_background_bytes = 1610612736" >> /etc/sysctl.conf
	echo "vm.dirty_bytes = 4294967296" >> /etc/sysctl.conf
	sysctl -p

	#limits
	echo "* soft nofile 524288" > /etc/security/limits.conf
	echo "* hard nofile 524288" >> /etc/security/limits.conf
	echo "* soft nproc 131072" >> /etc/security/limits.conf
	echo "* hard nproc 131072" >> /etc/security/limits.conf

	#timezone
	timedatectl set-timezone ${TIMEZONE}
}
get_aws_metadata()
{
	TOKEN=$(curl -sX PUT "http://169.254.169.254/latest/api/token" -H "X-aws-ec2-metadata-token-ttl-seconds: 21600")

	#remove previous variables if any are found
	sed -i "/REGION/ d" ${INSTALL_DIR}/${CONFIG_FILE}
	sed -i "/INSTANCE_ID/ d" ${INSTALL_DIR}/${CONFIG_FILE}
	sed -i "/KEY_PAIR/ d" ${INSTALL_DIR}/${CONFIG_FILE}

	REGION=$(curl -sH "X-aws-ec2-metadata-token: $TOKEN" http://169.254.169.254/latest/meta-data/placement/region)
	echo "REGION=\"${REGION}\"" >> ${INSTALL_DIR}/${CONFIG_FILE}

	INSTANCE_ID=$(curl -sH "X-aws-ec2-metadata-token: $TOKEN" http://169.254.169.254/latest/meta-data/instance-id)
	echo "INSTANCE_ID=\"$INSTANCE_ID\"" >> ${INSTALL_DIR}/${CONFIG_FILE}

	KEY_PAIR=$(curl -sH "X-aws-ec2-metadata-token: $TOKEN" http://169.254.169.254/latest/meta-data/public-keys/ | awk -F '=' '{print $2}')
	echo "KEY_PAIR=\"${KEY_PAIR}\"" >> ${INSTALL_DIR}/${CONFIG_FILE}

	if [ "${COORDINATOR_HOST_IND}" -eq "1" ]; then
		sed -i "/NODE_INDEX/ d" ${INSTALL_DIR}/${CONFIG_FILE}
		echo "NODE_INDEX=\"0\"" >> ${INSTALL_DIR}/${CONFIG_FILE}
	fi
}
get_ready_count()
{
	ready_count="0"
	#this checks all instances in the Stack 
	for instance_id in $(aws ec2 describe-instances --region ${REGION} --filters "Name=tag:aws:cloudformation:stack-name,Values=${STACK}" --query 'Reservations[*].Instances[*].[InstanceId]' --output text); do
		for i in $(aws ec2 describe-instance-status --region ${REGION} --instance-ids ${instance_id} --query 'InstanceStatuses[*].{SystemStatus:SystemStatus.Details[0].Status,InstanceStatus:InstanceStatus.Details[0].Status}' --output text | awk -F '\t' '{print $1 "|" $2}'); do
			system_status=$(echo $i | awk -F '|' '{print $1}')
			instance_status=$(echo $i | awk -F '|' '{print $2}')
			if [[ "${system_status}" == "passed" && "${instance_status}" == "passed" ]]; then
				ready_count=$((ready_count+1))
			fi
		done
	done
}
assign_nodes()
{
	#only run on coordinator
	coordinator_node_tag="${STACK}-cdw"
	cdw_ip=$(aws ec2 describe-instances --region ${REGION} --output text --query 'Reservations[*].Instances[*].{PrivateIpAddress:PrivateIpAddress}' --filters "Name=tag:aws:cloudformation:stack-name,Values=${STACK}" --filters "Name=tag:Name,Values=${coordinator_node_tag}")
	#coordinator node
	echo "${cdw_ip}" > ${INSTALL_DIR}/cdw_ip.txt
	echo "${cdw_ip}" > ${INSTALL_DIR}/all_ips.txt
	chown -R ${ADMIN}:${ADMIN} ${INSTALL_DIR}

	#segment nodes	
	rm -f ${INSTALL_DIR}/segment_ips.txt
	# get all of the nodes in the Stack except for the Coordinator
	# Sorted by ip address
	for i in $(aws ec2 describe-instances --region ${REGION} --output text --query 'Reservations[*].Instances[*].[PrivateIpAddress, Tags[?Key==`Name`].Value | [0] ] ' --filters "Name=tag:aws:cloudformation:stack-name,Values=${STACK}" | grep -v "${STACK}-cdw" | tr '\t' '|' | sort -V); do
		ip=$(echo $i | awk -F '|' '{print $1}')
		tag_name=$(echo $i | awk -F '|' '{print $2}')
		if [ ! "${tag_name}" == "${coordinator_node_tag}" ]; then
			echo "${ip}" >> ${INSTALL_DIR}/segment_ips.txt
			echo "${ip}" >> ${INSTALL_DIR}/all_ips.txt
		fi;
	done

 	if [ -f ${INSTALL_DIR}/segment_ips.txt ]; then
		counter="0"
		for i in $(cat ${INSTALL_DIR}/segment_ips.txt); do
			echo -ne "Checking for ${ADMIN} user on Segment Nodes."
			while [ "${counter}" -lt "${INSTANCE_COUNT}" ]; do
				count=$(sshpass -p ${ADMIN_PASS} ssh -o StrictHostKeyChecking=no ${ADMIN}@${i} "whoami" 2>&1 | grep -i "${ADMIN}" | wc -l)
				counter=$((counter+count))
				if [ "${counter}" -lt "${INSTANCE_COUNT}" ]; then
					sleep 5
					echo -ne "."
				fi
			done
			echo "."
		done
		index="0"
		echo -ne "Setting segment NODE_INDEX variable."
		for i in $(cat ${INSTALL_DIR}/segment_ips.txt); do
			index=$((index+1))
			echo -ne "."
			sshpass -p ${ADMIN_PASS} ssh -o StrictHostKeyChecking=no ${ADMIN}@${i} "sudo chown -R ${ADMIN}:${ADMIN} ${INSTALL_DIR}"
			sshpass -p ${ADMIN_PASS} ssh -o StrictHostKeyChecking=no ${ADMIN}@${i} "sed -i '/NODE_INDEX/ d' ${INSTALL_DIR}/${CONFIG_FILE}"
			sshpass -p ${ADMIN_PASS} ssh -o StrictHostKeyChecking=no ${ADMIN}@${i} "echo 'NODE_INDEX=\"${index}\"' >> ${INSTALL_DIR}/${CONFIG_FILE}"
		done
		echo "."
	fi
}
set_hostname()
{
	sed -i "/preserve_hostname/ d" /etc/cloud/cloud.cfg
	echo "preserve_hostname: true" >> /etc/cloud/cloud.cfg
	echo "Setting hostname ${my_hostname}"
	hostnamectl set-hostname --static ${my_hostname}
	hostname ${my_hostname}
}
set_segment_hostname()
{
	echo -ne "Checking for NODE_INDEX being set by the Coordinator."
	count=$(grep "NODE_INDEX" ${INSTALL_DIR}/${CONFIG_FILE} | wc -l)
	count="0"
	while [ "${count}" -lt "1" ]; do
		count=$(grep "NODE_INDEX" ${INSTALL_DIR}/${CONFIG_FILE} | wc -l)
		echo -ne "."
		if [ "${count}" -lt "1" ]; then
			sleep 10
		fi
	done	
	echo "."
	echo "Ready"
	NODE_INDEX=$(grep NODE_INDEX ${INSTALL_DIR}/${CONFIG_FILE} | awk -F '=' '{print $2}' | tr -d '"')
	my_hostname="sdw${NODE_INDEX}"
	set_hostname
}
set_coordinator_hostname()
{
	#only run on coordinator
	my_hostname="cdw"
	set_hostname
}
create_hosts_file()
{
	#only run on coordinator
	echo "127.0.0.1   localhost localhost.localdomain localhost4 localhost4.localdomain4" > ${INSTALL_DIR}/hosts
	echo "::1         localhost6 localhost6.localdomain6" >> ${INSTALL_DIR}/hosts
	coordinator_ip=$(cat ${INSTALL_DIR}/cdw_ip.txt)
	echo "${coordinator_ip} cdw" >> ${INSTALL_DIR}/hosts

 	if [ -f ${INSTALL_DIR}/segment_ips.txt ]; then
		echo -ne "Creating hosts file."
		index="0"
		for ip in $(cat ${INSTALL_DIR}/segment_ips.txt); do
			index=$((index+1))
			echo -ne "."
			echo "${ip} sdw${index}" >> ${INSTALL_DIR}/hosts
		done
		echo "."	
	fi
	cp /etc/hosts /etc/hosts.bak
	cp ${INSTALL_DIR}/hosts /etc/hosts
	chown root:root /etc/hosts
 	if [ -f ${INSTALL_DIR}/segment_ips.txt ]; then
		echo -ne "Copy new hosts file to segment nodes."
		for ip in $(cat ${INSTALL_DIR}/segment_ips.txt); do
			sshpass -p ${ADMIN_PASS} scp -o StrictHostKeyChecking=no ${INSTALL_DIR}/hosts ${ADMIN}@${ip}:${INSTALL_DIR}
			sshpass -p ${ADMIN_PASS} ssh -o StrictHostKeyChecking=no ${ADMIN}@${ip} "sudo cp -f ${INSTALL_DIR}/hosts /etc/; sudo chown root:root /etc/hosts"
			echo -ne "."
		done
		echo "."
	fi
}
create_nodes_files()
{
	echo "cdw" > ${INSTALL_DIR}/all_nodes.txt
	echo "cdw" > ${INSTALL_DIR}/coordinator_node.txt

	rm -f ${INSTALL_DIR}/segment_nodes.txt
 	if [ -f ${INSTALL_DIR}/segment_ips.txt ]; then
		index="0"
		for i in $(cat ${INSTALL_DIR}/segment_ips.txt); do
			index=$((index+1))
			segment_name="sdw${index}"
			echo "${segment_name}" >> ${INSTALL_DIR}/segment_nodes.txt
			echo "${segment_name}" >> ${INSTALL_DIR}/all_nodes.txt
		done
	else
		echo "cdw" > ${INSTALL_DIR}/segment_nodes.txt
	fi
}
get_edb_binaries()
{

	curl -1sSLf "https://downloads.enterprisedb.com/${EDB_SUBSCRIPTION_TOKEN}/gpsupp/setup.rpm.sh" | sudo -E bash
	dnf install -y warehouse-pg-7 warehouse-pg-clients whpg-backup
}
set_os_params
get_aws_metadata
get_edb_binaries

if [ "${COORDINATOR_HOST_IND}" -eq "1" ]; then
	get_ready_count

	echo -ne "Get ready count"
	while [ "${INSTANCE_COUNT}" -ne "${ready_count}" ]; do
		sleep 10 
		get_ready_count
		echo -ne "."
	done
	echo "."

	# all nodes are ready so get ip addresses for all of the nodes
	assign_nodes
	set_coordinator_hostname
	create_hosts_file
	create_nodes_files
else
	set_segment_hostname
fi
