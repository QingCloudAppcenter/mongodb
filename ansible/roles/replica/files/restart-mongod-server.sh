#! /bin/bash

PID=$(pidof mongod)
if [ -z "$PID" ]; then
    echo "mongod is not running"
    exit 0
fi

# Stop mongodb server
/opt/app/bin/stop-mongod-server.sh

# Start mongodb server
if [ $? -eq 0 ]; then
    /opt/app/bin/start-mongod-server.sh
    if [ $? -eq 0 ]; then
        echo "Restart mongod successful"
        exit 0
    else
        echo "Failed to restart mongod" 1>&2
        exit 1
    fi
else
    echo "Failed to kill mongod" 1>&2
    exit 1
fi
