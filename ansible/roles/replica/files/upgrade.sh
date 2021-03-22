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

readonly EC_NOT_READY=128

# checkFullyStarted
# desc: check if this node's stateStr is primary or secondary
checkFullyStarted() {
  local myIp=$(hostname -I | cut -d' ' -f1)
  local port=$(getMongoPort)
  runMongoCmd "rs.status().members.filter(m => m.name == '$myIp:$port' && /(PRIMARY|SECONDARY)/.test(m.stateStr)).length == 1 || quit($EC_NOT_READY)"
}

readonly oldMongoVersion=3.4.5
readonly newMongoVersion=3.6.8

proceed() {
  initNode
  if [ ! -d /opt/mongodb/$oldMongoVersion ]; then
    log "backup old files ..."
    mv /opt/mongodb /opt/$oldMongoVersion
    mkdir /opt/mongodb
    mv /opt/$oldMongoVersion /opt/mongodb/
  fi
  log "copying new files ..."
  rsync -aAX /upgrade/opt/ /opt/
  log "upgrading to $newMongoVersion ..."
  ln -snf /opt/mongodb/$newMongoVersion/bin /opt/mongodb/bin
}

rollback() {
  log "rolling back to $oldMongoVersion ..."
  ln -snf $oldMongoVersion/bin /opt/mongodb/bin
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
  local nodes=$(echo "$meta" | grep -o '^/replica/[[:alnum:]-]\+' | uniq | cut -d'/' -f3)
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

# isFCVOk
# desc: judge if the feature compability version is ok
# input: $1 desire version number, etc 3.6(not 3.6.8)
isFCVOk() {
  local jsstr="db.adminCommand({getParameter:1,featureCompatibilityVersion:1})"
  local res=$(runMongoCmd "$jsstr")
  res=$(echo "$res" | sed -n '/[vV]ersion/p' |  grep -o '[[:digit:].]\{2,\}')
  test "$1" = "$res"
}

isReplicasSetStatusOk() {
  local meta=$(curl -s http://metadata/self/hosts)
  local nodecnt=$(echo "$meta" | grep -o '^/replica/[[:alnum:]-]\+' | uniq | wc -l)
  local jsstr=$(cat <<EOF
members=rs.status().members
if (members.filter(m => /(1|2)/.test(m.state)).length != $nodecnt) {
  quit(1)
} else if (members.filter(m => /(1)/.test(m.state)).length != 1) {
  quit(1)
}
EOF
)

  runMongoCmd "$jsstr"
}

readonly ERROR_UPGRADE_BADVERSION=33
readonly ERROR_UPGRADE_BADFCV=34
readonly ERROR_UPGRADE_BADRSSTATUS=35
precheck() {
  if ! isDbVersionOk "3.4"; then log "precheck: db version 3.4, error!"; return $ERROR_UPGRADE_BADVERSION; fi
  if ! isFCVOk "3.4"; then log "precheck: FCV 3.4, error!"; return $ERROR_UPGRADE_BADFCV; fi
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
  log "downgrade begin ..."
  local pid=$(pidof mongod)
  if [ -n "$pid" ]; then
    if isDbVersionOk "3.4.5"; then log "already running the old version mongod, skipping"; return; fi

    if isMaster; then
      log "primary node steps down"
      doStepDown 180
      sleep 5s
      log "waiting for a new primary elected"
      retry 1200 3 0 isNewPrimaryOk
      log "new primary is ok"
    fi

    log "stop higher version mongod"
    /opt/app/bin/stop-mongod-server.sh
  fi

  toggleHealthCheck false

  log "correct the symlink to old folder:/opt/mongodb/$oldMongoVersion/bin"
  ln -snf /opt/mongodb/$oldMongoVersion/bin /opt/mongodb/bin
  
  log "start the old version mongod"
  /opt/mongodb/bin/start-mongod-server.sh
  sleep 5s

  log "waiting for mongodb to be ready ..."
  retry 1200 3 0 checkFullyStarted

  toggleHealthCheck true
  log "current node's downgrade: done!"
}

# showFCV
# desc: display feature compatibility version on web console
showFCV() {
  local jsstr="db.adminCommand({getParameter:1,featureCompatibilityVersion:1})"
  local res=$(runMongoCmd "$jsstr")
  res=$(echo "$res" | sed -n '/[vV]ersion/p' |  grep -o '[[:digit:].]\{2,\}')
  local tmpstr=$(cat <<EOF
{
  "labels": ["Feature compatibility version"],
  "data": [
    ["$res"]
  ]
}
EOF
)
  echo "$tmpstr"
}

# changeFCV
# desc: change feature compatibility version to $1
changeFCV() {
  if ! isMaster; then return; fi

  local jsstr="db.adminCommand({getParameter:1,featureCompatibilityVersion:1})"
  local res=$(runMongoCmd "$jsstr")
  res=$(echo "$res" | sed -n '/[vV]ersion/p' |  grep -o '[[:digit:].]\{2,\}')
  if [ "$res" = "$1" ]; then return; fi

  if ! isReplicasSetStatusOk; then return; fi

  jsstr="db.adminCommand({setFeatureCompatibilityVersion:\"$1\"})"
  runMongoCmd "$jsstr"
}

main() {
  initNode

  if [ "getOrder" = "$1" ]; then getOrder; return; fi

  if [ "doRollback" = "$1" ]; then doRollback; return; fi

  if [ "showFCV" = "$1" ]; then showFCV; return; fi

  if [ "changeFCV" = "$1" ]; then changeFCV "$2"; return; fi

  log "doing precheck ..."
  if ! precheck; then log "precheck error! stop upgrade!"; return 1; fi
  log "precheck done!"

  toggleHealthCheck false
  
  log "upgrading current node ..."

  if isMaster; then
    log "primary node steps down"
    doStepDown 180
    sleep 5s
    log "waiting for a new primary elected"
    retry 1200 3 0 isNewPrimaryOk
    log "new primary is ok"
  fi

  log "stopping old service"
  /opt/mongodb/bin/stop-mongod-server.sh

  log "replace new app files"
  proceed

  log "starting mongodb ..."
  /opt/app/bin/start-mongod-server.sh
  sleep 5s

  log "waiting for mongodb to be ready ..."
  retry 1200 3 0 checkFullyStarted

  toggleHealthCheck true
  log "current node's upgrade: done!"
}

main $@
