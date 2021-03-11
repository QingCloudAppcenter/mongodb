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

runMongoCmd() {
  local passwd="$(cat /data/pitrix.pwd)"
  local port=$(getMongoPort)
  local uri=mongodb://qc_master:$passwd@127.0.0.1:$port/admin
  if [ "$1" = "--local" ]; then
    shift
  else
    uri=$uri?replicaSet=foobar
  fi
  timeout --preserve-status 3 /opt/mongodb/bin/mongo --quiet $uri --eval "$@"
}

readonly EC_NOT_READY=128

checkFullyStarted() {
  local myIp=$(hostname -I | xargs)
  local port=$(getMongoPort)
  runMongoCmd "rs.status().members.filter(m => m.name == '$myIp:$port' && /(PRIMARY|SECONDARY)/.test(m.stateStr)).length == 1 || quit($EC_NOT_READY)"
}

isMaster() {
  runMongoCmd --local "db.isMaster().ismaster == true || quit(1)"
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

# runMongoCmdEx
# desc run mongo shell
# $1: script string
# $2/$3: username/passwd (option)
# $4: ip (option)
runMongoCmdEx() {
  if [ $# -ne 1 ] && [ $# -ne 3 ] && [ $# -ne 4 ]; then return 1; fi

  local cmd="/opt/mongodb/bin/mongo --quiet --port $(getMongoPort)"
  local jsstr="$1"

  shift
  if [ $# -gt 0 ]; then
    cmd="$cmd --authenticationDatabase admin --username $1 --password $2"
    shift 2
    if [ $# -ne 0 ]; then
      cmd="$cmd --host $1"
    fi
  fi

  timeout --preserve-status 5 echo "$jsstr" | $cmd
}

getIp() {
  echo $(echo $1 | cut -d'|' -f2)
}

getNodeId() {
  echo $(echo $1 | cut -d'|' -f1)
}

isMasterEx() {
  runMongoCmdEx "db.isMaster().ismaster == true || quit(1)" "qc_master" "$(cat /data/pitrix.pwd)" "$1"
}

# getOrder
# desc: get upgrade order
# intput: none
# output: like cli-xxx,cli-yyy,cli-zzz
# test cmd: upgrade getorder
getOrder() {
  local meta=$(curl http://metadata/self/hosts)
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
    if isMasterEx $(getIp ${tmpstr[i]}); then
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
# input: $1 desire version number, etc 3.6(not 3.6.8)
isDbVersionOk() {
  local jsstr=$(cat <<EOF
ver=db.version()
if (ver.indexOf("$1") !=0 ) { quit(1) }
EOF
)
  runMongoCmdEx "$jsstr" "qc_master" "$(cat /data/pitrix.pwd)"
}

# isFCVOk
# desc: judge if the feature compability version is ok
# input: $1 desire version number, etc 3.6(not 3.6.8)
isFCVOk() {
  local jsstr="db.adminCommand({getParameter:1,featureCompatibilityVersion:1})"
  local res=$(runMongoCmdEx "$jsstr" "qc_master" "$(cat /data/pitrix.pwd)")
  res=$(echo "$res" | sed -n '/version/p' | grep -o '[[:digit:].]\+')
  test "$1" = "$res"
}

isReplicasSetStatusOk() {
  local meta=$(curl http://metadata/self/hosts)
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

  runMongoCmdEx "$jsstr" "qc_master" "$(cat /data/pitrix.pwd)"
}

readonly ERROR_UPGRADE_BADVERSION=33
readonly ERROR_UPGRADE_BADFCV=34
readonly ERROR_UPGRADE_BADRSSTATUS=35
precheck() {
  if ! isDbVersionOk "3.4"; then log "precheck: db version 3.4, error!"; return $ERROR_UPGRADE_BADVERSION; fi
  if ! isFCVOk "3.4"; then log "precheck: FCV 3.4, error!"; return $ERROR_UPGRADE_BADFCV; fi
  if ! isReplicasSetStatusOk; then log "precheck: replia set status, error!"; return $ERROR_UPGRADE_BADRSSTATUS; fi
}

main() {
  initNode
  if [ "precheck" = "$1" ]; then
    log "doing precheck ..."
    if ! precheck; then log "precheck error! stop upgrade!"; return 1; fi
    log "precheck done!"
  fi

  if [ "getOrder" = "$1" ]; then getOrder; return; fi

  toggleHealthCheck false

  log "stopping old service"
  /opt/mongodb/bin/stop-mongod-server.sh

  log "replace new app files"
  proceed

  log "starting mongodb ..."
  /opt/app/bin/start-mongod-server.sh

  log "waiting mongodb to be ready ..."
  retry 1200 3 0 checkFullyStarted

  toggleHealthCheck true
}

main $@
