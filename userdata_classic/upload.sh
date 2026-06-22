#!/bin/bash

set -e

#outpost
#bucket="whpg-deploy"

bucket="warehousepg-userdata-classic"

count=$(aws s3 ls | awk -F ' ' '{print $3}' | grep -w "${bucket}" | wc -l)

if [ "${count}" -eq "0" ]; then
	echo "aws s3 mb s3://${bucket}"
	aws s3 mb s3://${bucket}
fi

for i in $(ls 0*.sh); do
	echo "aws s3 cp ${i} s3://${bucket}/warehousepg/aws/"
	aws s3 cp $i s3://${bucket}/warehousepg/aws/
done
