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
echo "To access, first update the SecurityGroup to allow your ip address on port 8888."
if [ -f /opt/edb/warehousepg/config.sh ]; then
	# running on AWS and deployed with Cloudformation
	source /opt/edb/warehousepg/config.sh
	public_ip=$(aws ec2 describe-instances --filters "Name=instance-id,Values=${INSTANCE_ID}" "Name=instance-state-name,Values=running" --query 'Reservations[].Instances[].[PublicIpAddress]' --output text)
	if [ ! "${public_ip}" == "" ]; then
		echo "Next, open a web browser and go to http://${public_ip}:8888"
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
