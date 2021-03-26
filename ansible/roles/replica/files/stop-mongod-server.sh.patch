#!/usr/bin/env bash

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

getMongoPort() {
  awk '$1=="port:" {print $2}' /etc/mongod.conf
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

# isMaster
# desc: judge if the node is a primary node
# $1: node's ip (option)
isMaster() {
  runMongoCmd "db.isMaster().ismaster == true || quit(1)" "$1" > /dev/null
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

isVerticalScaling() {
  local res=$(curl -s http://metadata/self | grep vertical-scaling-roles | wc -l)
  test $res -gt 0
}

initNode
if isVerticalScaling; then
  if isMaster; then
    log "primary node steps down"
    doStepDown 180
    log "waiting for a new primary elected"
    retry 1200 3 0 isNewPrimaryOk
    log "new primary is ok"
  fi
fi

su mongodb -c "/opt/mongodb/bin/mongod --config /etc/mongod.conf --shutdown"
