#!/bin/bash
set -e
INSTALL_DIR="/opt/edb/warehousepg"

CONFIG_FILE="config.sh"
source ${INSTALL_DIR}/${CONFIG_FILE}

assign_disks()
{

	#get the root volume that is already mounted
	root_disk=$(lsblk -no pkname $(findmnt -n -o SOURCE /))
	echo "${root_disk}" > ${INSTALL_DIR}/root_disk.txt

	#get the smallest disk that isn't root
	swap_disk=$(lsblk -b -o PATH,SIZE -d | tail -n +2 | grep -v "${root_disk}" | sort -k2,2 -n | awk -F ' ' '{print $1}' | head -n1)
	echo "${swap_disk}" > ${INSTALL_DIR}/swap_disk.txt

	#get the remaining disks for data
	lsblk -o PATH -d | tail -n +2 | grep -v "${swap_disk}" | grep -v "${root_disk}" | sort > ${INSTALL_DIR}/data_disks.txt
}
destroy()
{
	#swap files 
	for i in $(swapon -s | grep -v Filename |  awk -F ' ' '{print $1}'); do
		swapoff -v ${i}
	done

	#umount
	for i in $(cat ${INSTALL_DIR}/data_disks.txt); do
		uuid=$(blkid $i | awk -F '"' '{print $2}')
		if [ ! "${uuid}" == "" ]; then
			sed -i "/${uuid}/ d" /etc/fstab
		fi
	done

	counter="0"
	for i in $(seq 0 16); do
		counter=$((counter+1))
		directory="/data${counter}"

		mounted=$(mount | grep -w ${directory} | wc -l)
		if [ "${mounted}" -eq "1" ]; then
			umount ${directory} || true
		fi

		if [ -d "${directory}" ]; then
			rm -rf ${directory}
		fi
	done

	for i in $(cat $INSTALL_DIR/data_disks.txt); do
		existing_filesystem=$(file -sL $i | grep filesystem | wc -l)
		if [ "${existing_filesystem}" -gt "0" ]; then
			 echo "dd if=/dev/zero of=${i} bs=1M count=1024"
			 dd if=/dev/zero of=${i} bs=1M count=1024
		fi
	done
}
create()
{
	counter="0"
	for i in $(cat ${INSTALL_DIR}/data_disks.txt); do
		counter=$((counter+1))
		new_dir="/data${counter}"
		if [ ! -d "${new_dir}" ]; then
			mkdir ${new_dir}
		fi
	done

	for i in $(cat ${INSTALL_DIR}/data_disks.txt); do
		echo "/sbin/blockdev --setra 16384 ${i}"
		/sbin/blockdev --setra 16384 ${i}
		vol=$(echo $i | awk -F '/' '{print $3}')
		echo "mq-deadline" > /sys/block/${vol}/queue/scheduler
	done

	for i in $(cat ${INSTALL_DIR}/data_disks.txt); do
		mkfs.xfs -f ${i}
	done

	counter="0"
	for i in $(cat ${INSTALL_DIR}/data_disks.txt); do
		counter=$((counter+1))
		directory="/data${counter}"
		uuid=$(blkid $i | awk -F '"' '{print $2}')
		mount -t xfs -o rw,noatime,nodev -U ${uuid} ${directory} || true
		echo "UUID=${uuid} ${directory} xfs rw,noatime,nodev,nofail,x-systemd.device-timeout=30 0 0" >> /etc/fstab
		chown ${ADMIN}:${ADMIN} ${directory}
	done

	disk=$(cat ${INSTALL_DIR}/swap_disk.txt)
	sed -i "/swap/ d" /etc/fstab
	mkswap -f ${disk}
	swapon ${disk}
	uuid=$(blkid ${disk} | awk -F '"' '{print $2}')
	echo "UUID=${uuid} swap  swap  defaults 0 0" >> /etc/fstab
	swapon -s

	df -h
}

assign_disks
destroy
create
