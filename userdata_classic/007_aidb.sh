#!/bin/bash
set -e
INSTALL_DIR="/opt/edb/warehousepg"

CONFIG_FILE="config.sh"
source ${INSTALL_DIR}/${CONFIG_FILE}

dnf install -y edb-whpg7-aidb edb-whpg7-pgfs edb-whpg7-pgvector edb-whpg7-vectorplus

su -l ${ADMIN} -c "psql -d ${DATABASE_NAME} -c \"CREATE EXTENSION IF NOT EXISTS aidb CASCADE;\""
su -l ${ADMIN} -c "psql -d ${DATABASE_NAME} -c \"CREATE EXTENSION IF NOT EXISTS pgfs CASCADE;\""

shared_preload_libraries=$(su -l ${ADMIN} -c "psql -d ${DATABASE_NAME} -t -A -c \"SHOW shared_preload_libraries\"")

if [[ "${shared_preload_libraries}" == *"aidb"* ]]; then
	echo "shared_preload_libraries: ${shared_preload_libraries}"
else
	if [ "${#shared_preload_libraries}" -gt "0" ]; then
		new_shared_preload_libraries="${shared_preload_libraries},aidb"
	else
		new_shared_preload_libraries="aidb"
	fi
	su -l ${ADMIN} -c "gpconfig -c shared_preload_libraries -v \"${new_shared_preload_libraries}\""
	su -l ${ADMIN} -c "gpstop -ra -M immediate"
fi
