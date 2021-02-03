#! /bin/bash

su mongodb -c "/opt/mongodb/bin/mongod --config /etc/mongod.conf --shutdown"
