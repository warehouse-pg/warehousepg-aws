#!/bin/bash
set -e
INSTALL_DIR="/opt/edb/warehousepg"

CONFIG_FILE="config.sh"
source ${INSTALL_DIR}/${CONFIG_FILE}

disk_count=$(cat ${INSTALL_DIR}/cache_disks.txt | wc -l)
disks_file="cache_disks.txt"

assign_disks()
{
	#get the root volume that is already mounted
	root_disk="/dev/"$(lsblk -no pkname $(findmnt -n -o SOURCE /))
	echo "${root_disk}" > ${INSTALL_DIR}/root_disk.txt

	#get the smallest disk that isn't root
	swap_disk=$(lsblk -b -o PATH,SIZE -d | tail -n +2 | grep -v "${root_disk}" | sort -k2,2 -n | awk -F ' ' '{print $1}' | head -n1)
	echo "${swap_disk}" > ${INSTALL_DIR}/swap_disk.txt

	#get the remaining disks for cache
	lsblk -o PATH -d | tail -n +2 | grep -v "${swap_disk}" | grep -v "${root_disk}" | sort > ${INSTALL_DIR}/cache_disks.txt
}
destroy()
{
	echo "destroy cache"
	echo "systemctl stop cachefilesd"
	systemctl stop cachefilesd || true

	for i in $(seq 1 ${disk_count}); do
		directory="/cache${i}"

		mounted=$(mount | grep -w ${directory} | wc -l)
		if [ "${mounted}" -eq "1" ]; then
			echo "umount ${directory}"
			umount ${directory} || true
		fi

		if [ -d "${directory}" ]; then
			echo "rm -rf ${directory}"
			rm -rf ${directory}
		fi
	done

	for i in $(cat ${INSTALL_DIR}/${disks_file}); do
		existing_filesystem=$(file -sL ${i} | grep filesystem | wc -l)
		if [ "${existing_filesystem}" -gt "0" ]; then
			 echo "dd if=/dev/zero of=${i} bs=1M count=1024"
			 dd if=/dev/zero of=${i} bs=1M count=1024
		fi
	done
}
create()
{
	for i in $(seq 1 ${disk_count}); do
		directory="/cache${i}"
		echo "mkdir ${directory}"
		mkdir ${directory}
	done

	for i in $(cat ${INSTALL_DIR}/${disks_file}); do
		echo "/sbin/blockdev --setra 4096 ${i}"
		/sbin/blockdev --setra 4096 ${i}
		vol=$(echo $i | awk -F '/' '{print $3}')
		echo "none" > /sys/block/${vol}/queue/scheduler
	done

	for i in $(cat ${INSTALL_DIR}/${disks_file}); do
		echo "mkfs.xfs -f ${i}"
		mkfs.xfs -f ${i}
	done

	counter="0"
	for i in $(cat ${INSTALL_DIR}/${disks_file}); do
		counter=$((counter+1))
		directory="/cache${counter}"
		echo "mount -t xfs -o rw,noatime,nodev ${i} ${directory}"
		mount -t xfs -o rw,noatime,nodev ${i} ${directory} 
		echo "mkdir -p ${directory}/fscache"
		mkdir -p ${directory}/fscache
		echo "mkdir -p ${directory}/gptemp"
		mkdir -p ${directory}/gptemp
		echo "chown ${ADMIN}:${ADMIN} ${directory}/gptemp"
		chown ${ADMIN}:${ADMIN} ${directory}/gptemp
	done

	echo "systemctl start cachefilesd"
	systemctl start cachefilesd

	for i in $(seq 1 12); do
		status=$(systemctl is-active cachefilesd)
		if [ "${status}" == "active" ]; then
			break
		else
			sleep 5
		fi
	done
	status=$(systemctl is-active cachefilesd)
	if [ ! "${status}" == "active" ]; then
		echo "ERROR: cachefilesd failed to start!"
		exit 1
	fi

	echo "mount /s3data"
	mount /s3data
}

assign_disks
destroy
create
