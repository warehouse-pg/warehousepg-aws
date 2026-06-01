#!/bin/bash

set -e

bucket="fcto-s3-02"

count=$(aws s3 ls s3://${bucket} 2>/dev/null  | wc -l)

if [ "${count}" -eq "0" ]; then
	echo "aws s3 mb s3://${bucket}"
	aws s3 mb s3://${bucket}
fi

for i in $(ls *.sh | grep -v upload.sh); do
	echo "aws s3 cp ${i} s3://${bucket}/warehousepg/aws/"
	aws s3 cp $i s3://${bucket}/warehousepg/aws/
done


for i in $(ls *.rpm); do
	echo "aws s3 cp ${i} s3://${bucket}/warehousepg/aws/"
	aws s3 cp $i s3://${bucket}/warehousepg/aws/
done
