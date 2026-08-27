#!/bin/bash
set -e

INSTALL_DIR="/opt/edb/warehousepg"

CONFIG_FILE="config.sh"
source ${INSTALL_DIR}/${CONFIG_FILE}

signal_complete()
{
	/usr/local/bin/cfn-signal --region ${REGION} --stack ${STACK} "${SIGNAL_COMPLETE_URL}"
} 

signal_complete
