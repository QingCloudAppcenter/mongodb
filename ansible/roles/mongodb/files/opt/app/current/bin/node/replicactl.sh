# sourced by /opt/app/current/bin/ctl.sh
init() {
  if [ ! -d /data/db ];then
    mkdir /data/db
    chown mongod:svc /data/db
  fi
  _init
}

start() {
  _start
}