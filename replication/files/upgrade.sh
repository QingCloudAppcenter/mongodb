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

main() {
  toggleHealthCheck false

  ${@:-proceed}

  if isMaster; then
    log "leaving primary node as is old version, please manually restart it later."
  else
    log "restarting mongodb ..."
    /opt/mongodb/bin/restart-mongod-server.sh

    log "waiting mongodb to be ready ..."
    retry 1200 3 0 checkFullyStarted
  fi

  toggleHealthCheck true
}

main $@
