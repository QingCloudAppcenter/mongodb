#!/usr/bin/env bash

set -eo pipefail

command=$1
args="${@:2}"

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
  if [ "$res" = "$1" ]; then return; fi

  if ! isReplicasSetStatusOk; then return; fi

  jsstr="db.adminCommand({setFeatureCompatibilityVersion:\"$1\"})"
  runMongoCmd "$jsstr"
}

execute $command $args