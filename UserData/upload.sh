#!/bin/bash

set -e

for i in $(ls 0*.sh); do
	echo "aws s3 cp $i s3://fcto-s3-01/warehousepg/aws/"
	aws s3 cp $i s3://fcto-s3-01/warehousepg/aws/
done
