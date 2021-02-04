#!/usr/bin/env bash

set -eo pipefail

log() {
  echo "$@"
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

checkFullyStarted() {
  local passwd="$(cat /data/pitrix.pwd)"
  local myIp=$(hostname -I | xargs)
  local port=$(awk '$1=="port:" {print $2}' /etc/mongod.conf)
  local cmd="rs.status().members.filter(m => m.name == '$myIp:$port' && /(PRIMARY|SECONDARY)/.test(m.stateStr)).length == 1 || quit(128)"
  local uri=mongodb://qc_master:$passwd@localhost:$port/admin?replicaSet=foobar
  timeout --preserve-status 3 /opt/mongodb/bin/mongo --quiet $uri --eval "$cmd"
}

readonly oldMongoVersion=3.4.5
readonly newMongoVersion=3.4.17

proceed() {
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

  log "restarting mongodb ..."
  /opt/mongodb/bin/restart-mongod-server.sh

  log "waiting mongodb to be ready ..."
  retry 1200 3 0 checkFullyStarted

  toggleHealthCheck true
}

main $@
