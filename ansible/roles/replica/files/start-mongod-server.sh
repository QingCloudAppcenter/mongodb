#! /bin/bash

echo 0 > /sys/kernel/mm/transparent_hugepage/khugepaged/defrag
echo never > /sys/kernel/mm/transparent_hugepage/defrag
echo never > /sys/kernel/mm/transparent_hugepage/enabled

# change data path owner to mongodb
chown mongodb:mongodb /data/mongodb/

# check conf exists
if [ ! -f /etc/mongod.conf ]; then
    /opt/app/bin/mongo-trib.py gen_conf
fi

su mongodb -c "/opt/mongodb/bin/mongod --config /etc/mongod.conf" && /opt/app/bin/mongo-trib.py detect_host_changed
