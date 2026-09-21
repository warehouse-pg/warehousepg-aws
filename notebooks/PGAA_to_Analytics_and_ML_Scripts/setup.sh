#!/bin/bash

set -e

bucket=$(psql -tAc "SELECT url FROM pgfs.list_storage_locations() WHERE name = 'pgaa-demo';")

echo "aws s3 rm ${bucket}/ --recursive"
aws s3 rm ${bucket}/ --recursive

for i in $(ls 0*.sql); do
	echo $i
	echo "psql -e -f ${i}"
	psql -e -f ${i}
	sleep 5
done

python3 -m ensurepip --upgrade --user 2> /dev/null
python3 -m pip install --user psycopg2-binary 2> /dev/null

echo "Setup complete."
echo "Now execute:"
echo "python3 claims.py"
