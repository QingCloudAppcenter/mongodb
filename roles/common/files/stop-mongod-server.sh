#! /bin/bash

PID=$(pidof mongod)
if [ -z "$PID" ]; then
    echo "mongod is not running, skip stop mongod server"
    echo "========== mongod is not running, skip stop mongod server ==========" >> /var/log/mongo-trib.log
    exit 0
fi

MONGO_DIR="mongodb"
if [ "x$1" != "x" ];then
    MONGO_DIR="mongo$1"
fi
su mongodb -c "/opt/${MONGO_DIR}/bin/mongod --config /etc/mongod.conf --shutdown"
