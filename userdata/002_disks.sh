#!/bin/bash
set -e
INSTALL_DIR="/opt/edb/warehousepg"

CONFIG_FILE="config.sh"
source ${INSTALL_DIR}/${CONFIG_FILE}

#storage for base directories which is where the data resides in WarehousePG
#this uses S3 Files 
s3_data_dir="/s3data"
#storage for segment directories except for the base. 
#high performance EFS and multi-AZ
data_dir="/data"

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
	#swap files 
	for i in $(swapon -s | grep -v Filename |  awk -F ' ' '{print $1}'); do
		swapoff -v ${i}
	done

	echo "destroy cache"
	systemctl stop cachefilesd || true

	for i in $(seq 1 4); do
		directory="/cache${i}"

		mounted=$(mount | grep -w ${directory} | wc -l)
		if [ "${mounted}" -eq "1" ]; then
			umount ${directory} || true
		fi

		if [ -d "${directory}" ]; then
			rm -rf ${directory}
		fi
	done

	for i in $(cat ${INSTALL_DIR}/cache_disks.txt); do
		existing_filesystem=$(file -sL ${i} | grep filesystem | wc -l)
		if [ "${existing_filesystem}" -gt "0" ]; then
			 echo "dd if=/dev/zero of=${i} bs=1M count=1024"
			 dd if=/dev/zero of=${i} bs=1M count=1024
		fi
	done

	#s3 data directory
	mounted=$(mount | grep -w ${s3_data_dir} | wc -l)
	if [ "${mounted}" -eq "1" ]; then
		umount ${s3_data_dir} || true
	fi
	if [ -d "${s3_data_dir}" ]; then
		rm -rf ${s3_data_dir}
	fi

	sed -i '/ s3files /d' /etc/fstab

	#efs data directory
	mounted=$(mount | grep -w ${data_dir} | wc -l)
	if [ "${mounted}" -eq "1" ]; then
		umount ${data_dir} || true
	fi
	if [ -d "${data_dir}" ]; then
		rm -rf ${data_dir}
	fi

	sed -i '/ efs /d' /etc/fstab
}
create()
{
	echo "create cache"
	counter="0"
	for i in $(cat ${INSTALL_DIR}/cache_disks.txt); do
		counter=$((counter+1))
		new_dir="/cache${counter}"
		if [ ! -d "${new_dir}" ]; then
			echo "mkdir ${new_dir}"
			mkdir ${new_dir}
		fi
	done

	for i in $(cat ${INSTALL_DIR}/cache_disks.txt); do
		echo "/sbin/blockdev --setra 4096 ${i}"
		/sbin/blockdev --setra 4096 ${i}
		vol=$(echo $i | awk -F '/' '{print $3}')
		echo "none" > /sys/block/${vol}/queue/scheduler
	done

	for i in $(cat ${INSTALL_DIR}/cache_disks.txt); do
		echo "mkfs.xfs -f ${i}"
		mkfs.xfs -f ${i}
	done

	counter="0"
	for i in $(cat ${INSTALL_DIR}/cache_disks.txt); do
		counter=$((counter+1))
		directory="/cache${counter}"
		mount -t xfs -o rw,noatime,nodev ${i} ${directory} || true
		mkdir -p ${directory}/fscache
		mkdir -p ${directory}/gptemp
		chown ${ADMIN}:${ADMIN} ${directory}/gptemp
	done

	echo "enable cache"
	sed -i 's/^dir /#dir /g' /etc/cachefilesd.conf
	sed -i 's/^brun /#brun /g' /etc/cachefilesd.conf
	sed -i 's/^bcull /#bcull /g' /etc/cachefilesd.conf
	sed -i 's/^bstop /#bstop /g' /etc/cachefilesd.conf
	sed -i 's/^frun /#frun /g' /etc/cachefilesd.conf
	sed -i 's/^fcull /#fcull /g' /etc/cachefilesd.conf
	sed -i 's/^fstop /#fstop /g' /etc/cachefilesd.conf

	echo "brun 30%" >> /etc/cachefilesd.conf
	echo "bcull 25%" >> /etc/cachefilesd.conf
	echo "bstop 20%" >> /etc/cachefilesd.conf
	echo "frun 30%" >> /etc/cachefilesd.conf
	echo "fcull 25%" >> /etc/cachefilesd.conf
	echo "fstop 20%" >> /etc/cachefilesd.conf
	echo "dir /cache1/fscache" >> /etc/cachefilesd.conf

	echo "systemctl enable cachefilesd"
	systemctl enable cachefilesd
	echo "systemctl start cachefilesd"
	systemctl start cachefilesd
	echo "systemctl status cachefilesd"
	systemctl status cachefilesd

	echo "enable swap"
	disk=$(cat ${INSTALL_DIR}/swap_disk.txt)
	sed -i "/swap/ d" /etc/fstab
	mkswap -f ${disk}
	swapon ${disk}
	uuid=$(blkid ${disk} | awk -F '"' '{print $2}')
	echo "UUID=${uuid} swap  swap  defaults 0 0" >> /etc/fstab
	swapon -s

	#s3 data directory
	echo "mkdir ${s3_data_dir}"
	mkdir ${s3_data_dir}
	s3_file_system_id=$(aws s3files list-file-systems --region ${REGION} --query "fileSystems[?bucket=='${DATA_BUCKET}'].{fileSystemId:fileSystemId}" --output text)
	echo "${s3_file_system_id} ${s3_data_dir} s3files _netdev,noauto,fsc,noatime,nodev 0 0" >> /etc/fstab

	#fsc tells the mount to use the filesystem cache
	#noatime tells the mount to not update the timestamp when a file is updated. helps with disk performance
	#nodev good for security hardening
	echo "mount -t s3files -o _netdev,fsc,noatime,nodev ${s3_file_system_id} ${s3_data_dir}"
	mount -t s3files -o _netdev,fsc,noatime,nodev ${s3_file_system_id} ${s3_data_dir}

	#efs data directory
	efs_filesystem_id=$(aws efs describe-file-systems --region ${REGION} --query "FileSystems[?Tags[?Key=='Name' && Value=='${STACK}-EFSFileSystem']].FileSystemId" --output text)
	#make the mount persistent after reboot
	echo "${efs_filesystem_id}:/ ${data_dir} efs _netdev,tls,iam,noatime 0 0" >> /etc/fstab
	echo "mkdir ${data_dir}"
	mkdir ${data_dir}
	#tls indicates to use encryption in transit. s3 mount has this on by default
	#iam indicates to authenticate with the iam role on the instance. s3 files does this by default
	#noatime tells the mount to not update the timestamp when a file is updated. helps with disk performance
	#nodev good for security hardening
	echo "mount -t efs -o tls,iam,noatime ${efs_filesystem_id} ${data_dir}"
	mount -t efs -o tls,iam,noatime ${efs_filesystem_id} ${data_dir}

	echo "systemctl daemon-reload"
	systemctl daemon-reload

	df -h
}
create_startup_service()
{
	startup_script="cache-startup.sh"
	startup_service="cache-startup.service"
	if [ -f ${INSTALL_DIR}/${startup_script} ]; then
		cp ${INSTALL_DIR}/${startup_script} /usr/local/bin/

		echo "[Unit]" > ${INSTALL_DIR}/${startup_service}
		echo "Description=Initialize and mount NVMe instance store for fscache" >> ${INSTALL_DIR}/${startup_service}
		echo "DefaultDependencies=no" >> ${INSTALL_DIR}/${startup_service}
		echo "After=local-fs.target" >> ${INSTALL_DIR}/${startup_service}
		echo "After=network-online.target" >> ${INSTALL_DIR}/${startup_service}
		echo "Wants=network-online.target" >> ${INSTALL_DIR}/${startup_service}
		echo "" >> ${INSTALL_DIR}/${startup_service}
		echo "[Service]" >> ${INSTALL_DIR}/${startup_service}
		echo "Type=oneshot" >> ${INSTALL_DIR}/${startup_service}
		echo "RemainAfterExit=yes" >> ${INSTALL_DIR}/${startup_service}
		echo "ExecStart=/usr/local/bin/${startup_script}" >> ${INSTALL_DIR}/${startup_service}
		echo "" >> ${INSTALL_DIR}/${startup_service}
		echo "[Install]" >> ${INSTALL_DIR}/${startup_service}
		echo "WantedBy=multi-user.target" >> ${INSTALL_DIR}/${startup_service}

		chmod 755 ${INSTALL_DIR}/${startup_service}
		cat ${INSTALL_DIR}/${startup_service}

		cp ${INSTALL_DIR}/${startup_service} /etc/systemd/system/${startup_service}
		systemctl daemon-reload
		systemctl enable ${startup_service}
	fi
}

assign_disks
destroy
create
create_startup_service
