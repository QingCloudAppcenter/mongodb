#! /bin/bash

PID=$(pidof mongod)
if [ ! -z "$PID" ]; then
    echo "========== mongod is running, skip start mongod server ==========" >> /var/log/mongo-trib.log
    echo "mongod is running, skip start mongod server"
    exit 0
fi

echo 0 > /sys/kernel/mm/transparent_hugepage/khugepaged/defrag
echo never > /sys/kernel/mm/transparent_hugepage/defrag
echo never > /sys/kernel/mm/transparent_hugepage/enabled

# change data path owner to mongodb
chown mongodb:mongodb /data/mongodb/

# check conf exists
if [ ! -f /etc/mongod.conf ]; then
    /opt/mongodb/bin/mongo-trib.py gen_conf
    if [ $? -eq 0 ]; then
        echo "Generate mongod conf successful"
        exit 0
    else
        echo "Failed to generate mongod conf" 1>&2
        exit 1
    fi
fi

su mongodb -c "/opt/mongodb/bin/mongod --config /etc/mongod.conf" && /opt/mongodb/bin/mongo-trib.py detect_host_changed
