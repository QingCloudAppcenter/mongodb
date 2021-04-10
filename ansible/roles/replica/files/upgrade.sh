#!/usr/bin/env bash

set -eo pipefail

readonly appctlLogDir=/data/appctl/logs
readonly appctlLogFile=$appctlLogDir/appctl.log

initNode() {
  if [ ! -d $appctlLogDir ]; then mkdir -p $appctlLogDir; fi
}

log() {
  echo "$@" >> $appctlLogFile
}

retry() {
  local tried=0
  local maxAttempts=$1
  local interval=$2
  local stopCodes=$3
  local cmd="${@:4}"
  local retCode=0
  while [ $tried -lt $maxAttempts ]; do
    $cmd && return 0 || {
      retCode=$?
      if [[ ",$stopCodes," == *",$retCode,"* ]]; then
        log "'$cmd' returned with stop code '$retCode'. Stopping ..."
        return $retCode
      fi
    }
    sleep $interval
    tried=$((tried+1))
  done

  log "'$cmd' still returned errors after $tried attempts. Stopping ..."
  return $retCode
}

toggleHealthCheck() {
  local readonly path=/usr/local/etc/ignore_agent
  if [ "$1" == "true" ]; then
    rm -rf $path
  else
    touch $path
  fi
}

getMongoPort() {
  awk '$1=="port:" {print $2}' /etc/mongod.conf
}

oldMongoVersion=''
readonly newMongoVersion=4.0.3

proceed() {
  initNode

  log "backup app folder"
  mv /opt/app /opt/app-$oldMongoVersion

  log "backup confd folder"
  mkdir -p /data/confd-$oldMongoVersion
  find /etc/confd/conf.d -name "*.toml" ! -name "cmd.info.toml" -exec mv {} /data/confd-$oldMongoVersion \;
  find /etc/confd/templates -name "*.tmpl" ! -name "cmd.info.tmpl" -exec mv {} /data/confd-$oldMongoVersion \;

  log "replace new confd files ..."
  find /upgrade/confd -name "*.tmpl" -exec cp {} /etc/confd/templates \;
  find /upgrade/confd -name "*.toml" -exec cp {} /etc/confd/conf.d \;

  log "copy /upgrade/opt ..."
  rsync -aAX /upgrade/opt/ /opt/

  log "creating symlink to $newMongoVersion ..."
  ln -snf /opt/mongodb/$newMongoVersion/bin /opt/mongodb/bin
}

rollback() {
  oldMongoVersion=$(cat $VERSIONFILE)
  log "downgrade begin ..."
  local pid=$(pidof mongod)
  if [ -n "$pid" ]; then
    if isDbVersionOk "$oldMongoVersion"; then log "already running the old version mongod, skipping"; return; fi

    if isMaster; then
      log "primary node steps down"
      doStepDown 180
      
      log "waiting for a new primary elected"
      retry 1200 3 0 isNewPrimaryOk
      log "new primary is ok"
    fi

    log "stop higher version mongod"
    /opt/app/bin/stop-mongod-server.sh
  fi

  toggleHealthCheck false

  log "recover the app folder"
  mv /opt/app /opt/app-$newMongoVersion
  mv /opt/app-$oldMongoVersion /opt/app

  log "correct the symlink to old folder:/opt/mongodb/$oldMongoVersion/bin"
  ln -snf /opt/mongodb/$oldMongoVersion/bin /opt/mongodb/bin
  
  log "start the old version mongod"
  /opt/app/bin/start-mongod-server.sh
  
  log "waiting for mongodb to be ready ..."
  retry 1200 3 0 isReplicasSetStatusOk

  toggleHealthCheck true
  log "current node's downgrade: done!"
}

# runMongoCmd
# desc run mongo shell
# $1: script string
# $2: ip (option)
runMongoCmd() {
  local passwd="$(cat /data/pitrix.pwd)"
  local port=$(getMongoPort)

  local cmd="/opt/mongodb/bin/mongo --quiet --port $port --authenticationDatabase admin --username qc_master --password $passwd"
  local jsstr="$1"

  shift
  if [ $# -gt 0 ] && [ -n "$1" ]; then
    cmd="$cmd --host $1"
  fi

  timeout --preserve-status 5 echo "$jsstr" | $cmd
}

getIp() {
  echo $(echo $1 | cut -d'|' -f2)
}

getNodeId() {
  echo $(echo $1 | cut -d'|' -f1)
}

# isMaster
# desc: judge if the node is a primary node
# $1: node's ip (option)
isMaster() {
  runMongoCmd "db.isMaster().ismaster == true || quit(1)" "$1" > /dev/null
}

# getOrder
# desc: get upgrade order
# intput: none
# output: like cli-xxx,cli-yyy,cli-zzz
# test cmd: upgrade getorder
getOrder() {
  local meta=$(curl -s http://metadata/self/hosts)
  local nodes=$(echo "$meta" | grep -o '^/replica/[[:alnum:]-]\+' | uniq | cut -d'/' -f3 | sort)
  local tmpstr=''
  nodes=($(echo $nodes))
  for((i=0;i<${#nodes[@]};i++)); do
    tmpstr="$tmpstr $(echo "$meta" | grep "${nodes[i]}/node_id" | cut -f2)"
    tmpstr="$tmpstr|$(echo "$meta" | grep "${nodes[i]}/ip" | cut -f2) "
  done
  tmpstr=($(echo $tmpstr))
  local res=''
  local mas=''
  for((i=0;i<${#tmpstr[@]};i++)); do
    if isMaster $(getIp ${tmpstr[i]}); then
      mas=$(getNodeId ${tmpstr[i]})
    else
      res="$res$(getNodeId ${tmpstr[i]}),"
    fi
  done
  res="$res$mas"
  echo "$res"
}

isFirstInOrder() {
  local tmp=$(echo $(getOrder) | cut -d',' -f1)
  local me=$(curl -s http://metadata/self/host/node_id)
  test "$tmp" = "$me"
}

getMasterIp() {
  local meta=$(curl -s http://metadata/self/hosts)
  local nodes=$(echo "$meta" | grep -o '^/replica/[[:alnum:]-]\+' | uniq | cut -d'/' -f3 | sort)
  local tmpstr=''
  nodes=($(echo $nodes))
  for((i=0;i<${#nodes[@]};i++)); do
    tmpstr="$tmpstr $(echo "$meta" | grep "${nodes[i]}/node_id" | cut -f2)"
    tmpstr="$tmpstr|$(echo "$meta" | grep "${nodes[i]}/ip" | cut -f2) "
  done
  tmpstr=($(echo $tmpstr))
  local mas=''
  for((i=0;i<${#tmpstr[@]};i++)); do
    if isMaster $(getIp ${tmpstr[i]}); then
      mas=$(getIp ${tmpstr[i]})
      break
    fi
  done
  echo "$mas"
}

# getDbVersion
# desc: get current mongod version
getDbVersion() {
  runMongoCmd "db.version()"
}

# isDbVersionOk
# desc: judge if the db version is ok
# input: $1 desire version number, etc 3.6 or 3.6.8
isDbVersionOk() {
  local jsstr=$(cat <<EOF
ver=db.version()
if (ver.indexOf("$1") !=0 ) { quit(1) }
EOF
)
  runMongoCmd "$jsstr"
}

# isFcvOk
# desc: judge if the feature compability version is ok
# input: $1 desire version number, etc 3.6(not 3.6.8)
isFcvOk() {
  local jsstr="db.adminCommand({getParameter:1,featureCompatibilityVersion:1})"
  local res=$(runMongoCmd "$jsstr")
  res=$(echo "$res" | sed -n '/[vV]ersion/p' |  grep -o '[[:digit:].]\{2,\}')
  test "$1" = "$res"
}

readonly EC_NOT_READY=128
isReplicasSetStatusOk() {
  local meta=$(curl -s http://metadata/self/hosts)
  local nodecnt=$(echo "$meta" | grep -o '^/replica/[[:alnum:]-]\+' | uniq | wc -l)
  local jsstr=$(cat <<EOF
members=rs.status().members
if (members.filter(m => /(PRIMARY|SECONDARY)/.test(m.stateStr)).length != $nodecnt) {
  quit($EC_NOT_READY)
} else if (members.filter(m => /(PRIMARY)/.test(m.stateStr)).length != 1) {
  quit($EC_NOT_READY)
}
EOF
)

  runMongoCmd "$jsstr"
}

# checkReplicaSetProtocolVersion
# desc: check if replica set protocol version is 1, otherwise try to set it to a desire value
# $1: primary node's ip
checkReplicaSetProtocolVersion() {
  local jsstr=$(cat <<EOF
cfg=rs.conf()
if (cfg.protocolVersion == 1) {
  quit(0)
}
cfg.protocolVersion=1
rs.reconfig(cfg)
EOF
  )

  runMongoCmd "$jsstr" $1
}

# removeMONGODB_CR
# desc: remove support for MONGODB-CR
# $1: primary node's ip
removeMONGODB_CR() {
  runMongoCmd "db.adminCommand({authSchemaUpgrade: 1})" $1
}

readonly VERSIONFILE="/data/versionfile"
readonly ERROR_UPGRADE_BADVERSION=33
readonly ERROR_UPGRADE_BADFCV=34
readonly ERROR_UPGRADE_BADRSSTATUS=35
preCheck() {
  if ! isDbVersionOk "3.6"; then log "precheck: db version 3.6, error!"; return $ERROR_UPGRADE_BADVERSION; fi
  if ! isFcvOk "3.6"; then log "precheck: FCV 3.6, error!"; return $ERROR_UPGRADE_BADFCV; fi
  if ! isReplicasSetStatusOk; then log "precheck: replia set status, error!"; return $ERROR_UPGRADE_BADRSSTATUS; fi
}

# doStepDown
# desc: primary node does step down first
# input: $1-seconds during which the node can't be primary again
doStepDown() {
  if runMongoCmd "rs.stepDown($1)"; then
    # need check error status
    log "need check error status"
    retrun 1
  else
    # it's ok to proceed
    :
  fi
}

# isNewPrimaryOk
# desc: judge if new primary is elected
isNewPrimaryOk() {
  local res=$(runMongoCmd "rs.isMaster()")
  local primary=$(echo "$res" | sed -n '/"primary"/p' | grep -o '[[:digit:]][[:digit:].:]\+')
  local me=$(echo "$res" | sed -n '/"me"/p' | grep -o '[[:digit:]][[:digit:].:]\+')
  test "$primary" != "$me"
}

# doRollback
# desc: rollback when upgrade failed
doRollback() {
  oldMongoVersion=$(cat $VERSIONFILE)
  log "downgrade begin ..."
  local pid=$(pidof mongod)
  if [ -n "$pid" ]; then
    if isDbVersionOk "$oldMongoVersion"; then log "already running the old version mongod, skipping"; return; fi

    if isMaster; then
      log "primary node steps down"
      doStepDown 180
      
      log "waiting for a new primary elected"
      retry 1200 3 0 isNewPrimaryOk
      log "new primary is ok"
    fi

    log "stop higher version mongod"
    local tmp=$(systemctl is-active zabbix-agent)
    if [ "active" = "$tmp" ]; then systemctl stop zabbix-agent; fi
    /opt/app/bin/stop-mongod-server.sh
  fi

  toggleHealthCheck false

  log "restore old app file"
  if [ -d /opt/app-$oldMongoVersion ]; then
    rm -rf /opt/app
    mv /opt/app-$oldMongoVersion /opt/app
  fi

  log "restore confd files"
  if [ -d /data/confd-$oldMongoVersion ]; then
    find /etc/confd/conf.d -name "*.toml" ! -name "cmd.info.toml" -exec rm -rf {} \;
    find /etc/confd/templates -name "*.tmpl" ! -name "cmd.info.tmpl" -exec rm -rf {} \;
    find /data/confd-$oldMongoVersion -name "*.toml" -exec cp {} /etc/confd/conf.d \;
    find /data/confd-$oldMongoVersion -name "*.tmpl" -exec cp {} /etc/confd/templates \;
  fi

  log "correct the symlink to old folder:/opt/mongodb/$oldMongoVersion/bin"
  ln -snf /opt/mongodb/$oldMongoVersion/bin /opt/mongodb/bin

  log "refresh old cluster's config"
  /opt/qingcloud/app-agent/bin/confd -onetime
  rm -rf /data/confd-$oldMongoVersion
  
  log "start the old version mongod"
  /opt/app/bin/start-mongod-server.sh
  
  log "waiting for mongodb to be ready ..."
  retry 1200 3 0 isReplicasSetStatusOk

  toggleHealthCheck true
  log "current node's downgrade: done!"
}

# the files needed are resident in /tmp
installRuntimes() {
  # runtime needed
  dpkg -i /upgrade/debs/libcurl3_7.47.0-1ubuntu2.19_amd64.deb \
    /upgrade/debs/zabbix-agent_1%3a3.4.15-1+xenial_amd64.deb \
    /upgrade/debs/zabbix-get_1%3a3.4.15-1+xenial_amd64.deb \
    /upgrade/debs/zabbix-sender_1%3a3.4.15-1+xenial_amd64.deb
  # system settings
  cp -nf /upgrade/tmp/limits.conf /etc/security/limits.conf
  cp -nf /upgrade/tmp/sysctl.conf /etc/sysctl.conf
  sysctl -p /etc/sysctl.conf
  # logrotate
  cp -nf /upgrade/tmp/logrotate-mongod.conf /etc/logrotate.d/logrotate-mongod.conf
  # caddy
  groupadd -f svc
  useradd caddy -d /opt/caddy/current -c "Service User" -G svc -M -s /sbin/nologin
  cp -nf /upgrade/tmp/caddy.service /etc/systemd/system/ && systemctl daemon-reload
  # zabbix
  mkdir -p /etc/zabbix/zabbix_agentd.d
  cp -nf /upgrade/tmp/zabbix_mongodb.conf /etc/zabbix/zabbix_agentd.d/
  # create additional folders in /data
  mkdir -p /data/info /data/logs /data/caddy/logs /data/zabbix-agent/logs;chown caddy:svc /data/caddy/logs
}

main() {
  initNode

  if [ "getOrder" = "$1" ]; then getOrder; return; fi

  if [ "doRollback" = "$1" ]; then doRollback; return; fi

  log "doing precheck ..."
  if ! preCheck; then log "precheck error! stop upgrade!"; return 1; fi
  log "precheck done!"

  if isFirstInOrder; then
    log "first node do something"
    local tmp=$(getMasterIp)
    log "remove MONGODB-CR"
    removeMONGODB_CR "$tmp"
    log "check replica set protocol version"
    checkReplicaSetProtocolVersion "$tmp"
    log "first node's work done!"
  fi
  
  # reserve the old version
  getDbVersion > $VERSIONFILE
  oldMongoVersion=$(cat $VERSIONFILE)

  toggleHealthCheck false
  
  log "upgrading current node ..."

  if isMaster; then
    log "primary node steps down"
    doStepDown 180
    log "waiting for a new primary elected"
    retry 1200 3 0 isNewPrimaryOk
    log "new primary is ok"
  fi

  log "stopping old service"
  /opt/app/bin/stop-mongod-server.sh

  log "replace new app files"
  proceed

  log "install addition runtimes"
  installRuntimes

  log "refresh new cluster's config"
  /opt/qingcloud/app-agent/bin/confd -onetime

  log "starting mongodb ..."
  /opt/app/bin/start-mongod-server.sh && /opt/app/bin/zabbix.sh start

  log "waiting for mongodb to be ready ..."
  retry 1200 3 0 isReplicasSetStatusOk

  toggleHealthCheck true
  log "current node's upgrade: done!"
}

main $@
