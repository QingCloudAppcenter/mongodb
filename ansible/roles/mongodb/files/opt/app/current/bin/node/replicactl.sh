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
  if [ "$ADDING_HOSTS"="true" ];then
    log "adding new node: $MY_SID $MY_IP"
    log "${ADDING_LIST[@]}"
  else
    log "init rs or normal start"
    log "$MY_SID $MY_IP"
    log "${NODE_LIST[@]}"
  fi
}

mytest() {
  echo 'my test goes here!'
}