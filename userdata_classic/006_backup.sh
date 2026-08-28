#!/bin/bash
set -e
INSTALL_DIR="/opt/edb/warehousepg"

CONFIG_FILE="config.sh"
source ${INSTALL_DIR}/${CONFIG_FILE}

install_dr()
{
	dnf install -y edb-whpg-dr

	count=$(grep whpg-dr /home/${ADMIN}/.bashrc | wc -l)
	if [ "${count}" -eq "0" ]; then
		echo "Adding whpg-dr to path"
		echo "export PATH=\$PATH:/usr/edb/whpg-dr/bin" >> /home/${ADMIN}/.bashrc
	else
		echo "whpg-dr already in path"
	fi
}
create_example_gpbackup_config()
{
	echo "create example s3 config file for gpbackup"
	s3_plugin="/home/${ADMIN}/gpbackup-s3-config.yaml"

	echo "# Instructions for taking a backup with gpbackup" > ${s3_plugin}
	echo "# 1. Change the <bucket_name> to your S3 bucket which will hold backups." >> ${s3_plugin}
	echo "#" >> ${s3_plugin}
	echo "# 2. Execute the gpbackup command" >> ${s3_plugin}
	echo "#" >> ${s3_plugin}
	echo "# gpbackup --dbname ${DATABASE_NAME} --plugin-config ${s3_plugin}" >> ${s3_plugin}
	echo "#" >> ${s3_plugin}
	echo "executablepath: \$GPHOME/bin/gpbackup_s3_plugin" >> ${s3_plugin}
	echo "options:" >> ${s3_plugin}
	echo "  region: ${REGION}" >> ${s3_plugin}
	echo "  bucket: <bucket_name>" >> ${s3_plugin}
	echo "  folder: ${STACK}" >> ${s3_plugin}
	echo "  encryption: \"on\"" >> ${s3_plugin}
	chown ${ADMIN}:${ADMIN} ${s3_plugin}
}
create_example_dr_config()
{
	echo "create example s3 config file for whpg-dr"
	dr_config="/home/${ADMIN}/whpg-dr-config.yaml"

	echo "# Instructions for configuring Disaster Recovery backup" > ${dr_config}
	echo "# 1. Change the <bucket_name> to your S3 bucket which will hold backups." >> ${dr_config}
	echo "#" >> ${dr_config}
	echo "# 2. Enable WAL archiving" >> ${dr_config}
	echo "#" >> ${dr_config}
	echo "# whpg-dr configure backup ${dr_config}" >> ${dr_config}
	echo "#" >> ${dr_config}
	echo "# 3. Verify the configuration" >> ${dr_config}
	echo "#" >> ${dr_config}
	echo "# whpg-dr check ${STACK}" >> ${dr_config}
	echo "#" >> ${dr_config}
	echo "# 4. Take an initial backup" >> ${dr_config}
	echo "# whpg-dr backup ${STACK}" >> ${dr_config}
	echo "#" >> ${dr_config}
	echo "# 5. View the backup" >> ${dr_config}
	echo "#" >> ${dr_config}
	echo "# whpg-dr list-backup ${STACK}" >> ${dr_config}
	echo "#" >> ${dr_config}
	echo "# You now have a full backup in which you can create a new cluster with." >> ${dr_config}
	echo "# Additionally, WAL archiving is now in place for point in time recovery." >> ${dr_config}
	echo "# A restore point is a tiny metadata marker that enables you to restore the cluster to that time." >> ${dr_config}
	echo "# If your RPO is 15 minutes, execute the create-restore-point command every 15 minutes." >> ${dr_config}
	echo "# A restore will restore from the last backup and then apply the WAL logs up to the recovery point." >> ${dr_config}
	echo "#" >> ${dr_config}
	echo "# whpg-dr create-restore-point ${STACK}" >> ${dr_config}
	echo "#" >> ${dr_config}
	echo "cluster_name: ${STACK}" >> ${dr_config}
	echo "storage:" >> ${dr_config}
	echo "  type: s3" >> ${dr_config}
	echo "  bucket: <bucket_name>" >> ${dr_config}
	echo "  prefix: dr-backups" >> ${dr_config}
	echo "  region: ${REGION}" >> ${dr_config}
	chown ${ADMIN}:${ADMIN} ${dr_config}
}

if [[ "${NODE_INDEX}" -eq "0" || "${NODE_INDEX}" -eq "1" ]]; then
	install_dr
	create_example_gpbackup_config
	create_example_dr_config
fi
