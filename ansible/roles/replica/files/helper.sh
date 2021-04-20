#!/usr/bin/env bash

set -eo pipefail

command=$1
args="${@:2}"

execute() {
  local cmd=$1
  [ "$(type -t $cmd)" = "function" ] || cmd=_$cmd
  $cmd ${@:2}
}

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

getOplogSize() {
  awk '$1=="oplogSizeMB:" {print $2}' /etc/mongod.conf
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

# showFcv
# desc: display feature compatibility version on web console
showFcv() {
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

isReplicasSetStatusOk() {
  local meta=$(curl -s http://metadata/self/hosts)
  local nodecnt=$(echo "$meta" | grep -o '^/replica/[[:alnum:]-]\+' | uniq | wc -l)
  local jsstr=$(cat <<EOF
members=rs.status().members
if (members.filter(m => /(PRIMARY|SECONDARY)/.test(m.stateStr)).length != $nodecnt) {
  quit(1)
} else if (members.filter(m => /(PRIMARY)/.test(m.stateStr)).length != 1) {
  quit(1)
}
EOF
  )

  runMongoCmd "$jsstr"
}

# changeFcv
# desc: change feature compatibility version to $1
changeFcv() {
  if ! isMaster; then return; fi

  local jsstr="db.adminCommand({getParameter:1,featureCompatibilityVersion:1})"
  local res=$(runMongoCmd "$jsstr")
  res=$(echo "$res" | sed -n '/[vV]ersion/p' |  grep -o '[[:digit:].]\{2,\}')

  local input=$(echo "$1" | grep -o '[[:digit:].-]\+')
  if [ "$res" = "$input" ]; then return; fi

  if ! isReplicasSetStatusOk; then return; fi

  jsstr="db.adminCommand({setFeatureCompatibilityVersion:\"$input\"})"
  runMongoCmd "$jsstr"
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

# getOrderIp
# desc: get ordered ip list, master is the last
getOrderIp() {
  local meta=$(curl -s http://metadata/self/hosts)
  local nodes=$(echo "$meta" | grep -o '^/replica/[[:alnum:]-]\+' | uniq | cut -d'/' -f3)
  local tmpstr=''
  local mas=''
  local res=''
  nodes=($(echo $nodes))
  for((i=0;i<${#nodes[@]};i++)); do
    tmpstr="$(echo "$meta" | grep "${nodes[i]}/ip" | cut -f2)"
    if isMaster $tmpstr; then
      mas=$tmpstr
    else
      res="$res$tmpstr "
    fi
  done
  res="$res$mas"
  echo "$res"
}

# checkRuntimeOplogSize
# desc: check oplog size of replicaset member
checkRuntimeOplogSize() {
  local tmp=$(($(getOplogSize)*1024*1024))
  local jsstr=$(cat <<EOF
db=db.getSiblingDB('local')
if(db.oplog.rs.stats().maxSize != $tmp) {
  quit(1)
}
EOF
  )
  runMongoCmd "$jsstr" "$1"
}

# fixOplogSize
# desc: make sure the oplog size is identitical between conf and runtime
fixOplogSize() {
  initNode
  if ! pidof mongod; then log "fixOplogSize: mongod is not running, skipping!"; return; fi
  retry 1200 3 0 isReplicasSetStatusOk
  if ! isMaster; then log "fixOplogSize: not primary, skipping!"; return; fi

  local oplogSize=$(getOplogSize)
  local iplist=($(getOrderIp))
  for((i=0;i<${#iplist[@]};i++)); do
    if ! checkRuntimeOplogSize ${iplist[i]}; then
      runMongoCmd "db.adminCommand({replSetResizeOplog: 1, size: $oplogSize})" "${iplist[i]}"
      log "fixed oplogSize for ${iplist[i]}"
    fi
  done
}

execute $command $args