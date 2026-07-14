#!/bin/bash

set -e

bucket="${1}"

if [ "${bucket}" == "" ]; then
	echo "ERROR: Please include the bucket name you wish to upload the files to."
	exit 1
fi

count=$(aws s3 ls | awk -F ' ' '{print $3}' | grep -w "${bucket}" | wc -l)

if [ "${count}" -eq "0" ]; then
	echo "aws s3 mb s3://${bucket}"
	aws s3 mb s3://${bucket}
fi

for i in $(ls 0*.sh | grep -v upload.sh); do
	echo "aws s3 cp ${i} s3://${bucket}/warehousepg/aws/"
	aws s3 cp $i s3://${bucket}/warehousepg/aws/
done
