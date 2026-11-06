#!/bin/bash
set -e
INSTALL_DIR="/opt/edb/warehousepg"

CONFIG_FILE="config.sh"
source ${INSTALL_DIR}/${CONFIG_FILE}

copy_files()
{
	mkdir -p /home/${ADMIN}/notebooks
	cp -r /opt/edb/warehousepg/notebooks/. /home/${ADMIN}/notebooks/
	chown -R ${ADMIN}:${ADMIN} /home/${ADMIN}/notebooks
}
setup_python_env()
{
	dnf install -y python3.12 python3.12-pip python3.12-devel gcc
	su -l ${ADMIN} -c "python3.12 -m venv /home/${ADMIN}/jupyter_env"
	su -l ${ADMIN} -c "/home/${ADMIN}/jupyter_env/bin/pip install --upgrade pip"
	su -l ${ADMIN} -c "/home/${ADMIN}/jupyter_env/bin/pip install notebook pandas psycopg2-binary matplotlib pypmml geopandas sqlalchemy seaborn jupysql psycopg streamlit datasets ipywidgets"
}
create_service()
{
	echo "[Unit]" > /etc/systemd/system/jupyter.service
	echo "Description=Jupyter Notebook" >> /etc/systemd/system/jupyter.service
	echo "After=network-online.target" >> /etc/systemd/system/jupyter.service
	echo "Wants=network-online.target" >> /etc/systemd/system/jupyter.service
	echo "" >> /etc/systemd/system/jupyter.service
	echo "[Service]" >> /etc/systemd/system/jupyter.service
	echo "Type=simple" >> /etc/systemd/system/jupyter.service
	echo "User=${ADMIN}" >> /etc/systemd/system/jupyter.service
	echo "WorkingDirectory=/home/${ADMIN}" >> /etc/systemd/system/jupyter.service
	echo "ExecStart=/home/${ADMIN}/jupyter_env/bin/jupyter notebook --ip=0.0.0.0 --port=8888 --no-browser --IdentityProvider.token=" >> /etc/systemd/system/jupyter.service
	echo "Restart=on-failure" >> /etc/systemd/system/jupyter.service
	echo "" >> /etc/systemd/system/jupyter.service
	echo "[Install]" >> /etc/systemd/system/jupyter.service
	echo "WantedBy=multi-user.target" >> /etc/systemd/system/jupyter.service
	systemctl daemon-reload
	systemctl enable --now jupyter
}
if [ "$INSTALL_DEMOS" == "True" ]; then
	copy_files
	setup_python_env
	create_service
else
	echo "Demo environment creation skipped"
fi
