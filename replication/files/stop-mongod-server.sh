#! /bin/bash

PID=$(pidof mongod)
if [ -z "$PID" ]; then
    echo "mongod is not running, skip stop mongod server"
    echo "========== mongod is not running, skip stop mongod server ==========" >> /var/log/mongo-trib.log
    exit 0
fi

su mongodb -c "/opt/mongodb/bin/mongod --config /etc/mongod.conf --shutdown"
