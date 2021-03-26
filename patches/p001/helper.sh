#!/usr/bin/env bash

set -eo pipefail

command=$1
args="${@:2}"

initNode() {
  if [ ! -d $appctlLogDir ]; then mkdir -p $appctlLogDir; fi
}

readonly appctlLogDir=/data/appctl/logs
readonly appctlLogFile=$appctlLogDir/appctl.log
log() {
  echo "$@" >> $appctlLogFile
}

execute() {
  local cmd=$1
  [ "$(type -t $cmd)" = "function" ] || cmd=_$cmd
  $cmd ${@:2}
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

getIp() {
  echo $(echo $1 | cut -d'|' -f2)
}

getNodeId() {
  echo $(echo $1 | cut -d'|' -f1)
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

doPatch() {
  log "patch begin ..."
  log "backup files"
  mv /opt/mongodb/bin/stop-mongod-server.sh /opt/mongodb/bin/stop-mongod-server.sh.back
  log "copy files"
  cp /patch/helper.sh /opt/mongodb/bin/
  cp /patch/stop-mongod-server.sh /opt/mongodb/bin/
  chmod +x /opt/mongodb/bin/helper.sh /opt/mongodb/bin/stop-mongod-server.sh
  log "patch done!"
}

doRollback() {
  log "rollback begin ..."
  log "recover files"
  mv /opt/mongodb/bin/stop-mongod-server.sh /opt/mongodb/bin/stop-mongod-server.sh.patch
  mv /opt/mongodb/bin/stop-mongod-server.sh.back /opt/mongodb/bin/stop-mongod-server.sh
  log "rollback done!"
}

initNode
execute $command $args