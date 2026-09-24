#!/bin/bash
set -e

if [ "${USER}" == "root" ]; then
	echo "ERROR: Do not execute this script as root. it is recommended to use gpadmin."
	exit 1
fi

#kill jupyter notebook if it is already running
pkill -f "jupyter-notebook" || true
sleep 1

#install python3 and gcc
sudo dnf install -y python3 python3-pip python3-devel gcc

#setup python environment
if [ -d ~/jupyter_env ]; then
	echo "INFO: ~/jupyter_env already exists, skipping venv creation."
else
	python3 -m venv ~/jupyter_env
fi
source ~/jupyter_env/bin/activate

#install python packages
pip install --upgrade pip
pip install notebook pandas psycopg2-binary matplotlib pypmml geopandas sqlalchemy pandas seaborn jupysql

#start background process
nohup jupyter notebook --ip=0.0.0.0 --port=8888 --no-browser --NotebookApp.token='' --NotebookApp.password='' > ~/jupyter.log 2>&1 &
clear
echo "***********************************************************************************"
echo "Jupyter Notebook started (PID $!)."
echo "***********************************************************************************"
echo "Logs: ~/jupyter.log"
echo "***********************************************************************************"
if [ -f /opt/edb/warehousepg/config.sh ]; then
	# running on AWS and deployed with Cloudformation
	source /opt/edb/warehousepg/config.sh
	public_ip=$(aws ec2 describe-instances --filters "Name=instance-id,Values=${INSTANCE_ID}" "Name=instance-state-name,Values=running" --query 'Reservations[].Instances[].[PublicIpAddress]' --output text)
	if [ ! "${public_ip}" == "" ]; then
		#make sure port 8888 is allowed in the public security group
		#If not configured, the value will be "None".
		count=$(aws ec2 describe-security-groups --filters "Name=tag:aws:cloudformation:stack-name,Values=${STACK}" "Name=description,Values=PublicSecurityGroup" --query 'SecurityGroups[*].{GroupId: GroupId, CidrIp: IpPermissions[].IpRanges[?Description==`Notebook access`].CidrIp | [0][0]}' --output text | tr '\t' '|' | grep "None" | wc -l)
		if [ "${count}" -eq "1" ]; then
			#get the CIDR range set by the CFT and the Security Group ID
			for i in $(aws ec2 describe-security-groups --filters "Name=tag:aws:cloudformation:stack-name,Values=${STACK}" "Name=description,Values=PublicSecurityGroup" --query 'SecurityGroups[*].{GroupId: GroupId, CidrIp: IpPermissions[].IpRanges[?Description==`SSH access`].CidrIp | [0][0]}' --output text | tr '\t' '|'); do
				cidr=$(echo ${i} | awk -F '|' '{print $1}')
				group_id=$(echo ${i} | awk -F '|' '{print $2}')
			done

			aws ec2 authorize-security-group-ingress --group-id "${group_id}" --ip-permissions "[ { \"IpProtocol\": \"tcp\", \"FromPort\": 8888, \"ToPort\": 8888, \"IpRanges\": [ { \"CidrIp\": \"${cidr}\", \"Description\": \"Notebook access\" } ] } ]" >> ~/authorize_security_group.log 2>&1 
		else
			echo "Notebook SecurityGroup already configured" >> ~/authorize_security_group.log
		fi
		echo "Open a web browser and go to http://${public_ip}:8888"
	else
		echo "***********************************************************************************"
		echo "WARNING: Unable to determine public IP address for your coordinator node."
		echo "Access Jupyter Notebook with http://<your coordinator node>:8888"
		echo "***********************************************************************************"
	fi
fi

echo "***********************************************************************************"
echo "- Jupyter Notebook is intended for demonstration purposes only."
echo "- No authentication required."
echo "- All traffic from your browser to Jupyter Notebook is sent in plain text (no SSL)."
echo "***********************************************************************************"
echo "- To stop: kill $!  (or: pkill -f jupyter-notebook)"
echo "***********************************************************************************"
echo ""
