#!/usr/bin/env bash

set -eo pipefail

readonly appctlLogDir=/data/appctl/logs
readonly appctlLogFile=$appctlLogDir/appctl.log

initNode() {
  mkdir -p $appctlLogDir
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
readonly newMongoVersion=3.4.17

proceed() {
  initNode
  if [ ! -d /opt/mongodb/$oldMongoVersion ]; then
    log "backup old files ..."
    mv /opt/mongodb /opt/$oldMongoVersion
    mkdir /opt/mongodb
    mv /opt/$oldMongoVersion /opt/mongodb/
  fi
  log "copying new files ..."
  rsync -aAX /upgrade/opt/mongodb/ /opt/mongodb/
  log "upgrading to $newMongoVersion ..."
  ln -snf $newMongoVersion/bin /opt/mongodb/bin
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

# getorder
# desc: get upgrade order
# intput: none
# output: like cli-xxx,cli-yyy,cli-zzz
# test cmd: upgrade getorder
getorder() {
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

main() {
  if [ "getorder" = "$1" ]; then log "get upgrade order"; getorder; return; fi

  toggleHealthCheck false

  log "stopping old service"
  /opt/mongodb/bin/stop-mongod-server.sh

  log "replace new app files"
  ${@:-proceed}

  log "starting mongodb ..."
  /opt/mongodb/bin/start-mongod-server.sh

  log "waiting mongodb to be ready ..."
  retry 1200 3 0 checkFullyStarted

  toggleHealthCheck true
}

main $@
