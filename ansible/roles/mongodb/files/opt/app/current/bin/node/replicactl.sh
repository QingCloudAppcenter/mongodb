# sourced by /opt/app/current/bin/ctl.sh
# ERRORCODE
SYS_BADPARAMS=50
MS_CONNECT=51
MS_SHELLEVAL=52
MS_SYNTAXERR=53
MS_UNKNOWN=99
MS_REPLNOTREADY=97

# common functions

# runMongoCmd
# desc run mongo shell
# $1: script string
# $2/$3: username/passwd (option)
# $4: ip (option)
runMongoCmd() {
  if [ $# -ne 1 ] && [ $# -ne 3 ] && [ $# -ne 4 ]; then return 1; fi

  local cmd="/opt/mongodb/current/bin/mongo --quiet --port $MY_PORT"
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

# getSid
# desc: get sid from NODE_LIST string
# $1: a NODE_LIST item (5|192.168.1.2)
# output: sid
getSid() {
  echo `echo $1 | cut -d'|' -f1`
}

# getIp
# desc: get ip from NODE_LIST string
# $1: a NODE_LIST item (5|192.168.1.2)
# output: ip
getIp() {
  echo `echo $1 | cut -d'|' -f2`
}

# rsIsMaster
# desc: judge wether the node is master/primary
# $1: node's ip (option)
# $?: 0-yes, 1-no
rsIsMaster() {
  local tmp=''
  if [ $# -eq 0 ]; then
    tmp=$(runMongoCmd "JSON.stringify(rs.isMaster())")
  else
    tmp=$(runMongoCmd "JSON.stringify(rs.isMaster())" "$MONGODB_USER_SYS" "$(getSysUserPasswd)" $1)
  fi
  
  local ismaster=$(echo "$tmp" | jq ".ismaster")
  
  if [ "$ismaster" = "false" ]; then return 1; fi
}

# getCurrentMaster
getCurrentMaster() {
  for((i=0; i<${#NODE_LIST[@]}; i++)); do
    if rsIsMaster $(getIp ${NODE_LIST[i]}); then
      echo ${NODE_LIST[i]}
      return
    fi
  done
}

# rsDoInit
# desc: init a replica set, the node runs this function gets proirity 2, other nodes' proirity is 1
rsDoInit() {
  local memberstr=''
  local curmem=''
  for ((i=0; i<${#NODE_LIST[@]}; i++)); do
    if [ "$(getIp ${NODE_LIST[i]})" = "$MY_IP" ]; then
      curmem="{_id:$i,host:\"$MY_IP:$MY_PORT\",priority:2}"
    else
      curmem="{_id:$i,host:\"$(getIp ${NODE_LIST[i]}):$MY_PORT\"}"
    fi

    if [ "$i" -eq 0 ]; then
      memberstr=$curmem
    else
      memberstr="$memberstr,$curmem"
    fi
  done

  local initjs=$(cat <<EOF
rs.initiate({
  _id:"$RSNAME",
  members:[$memberstr]
})
EOF
)
  runMongoCmd "$initjs"
}

rsAddNodes() {
  local jsstr=';'
  for ((i=0; i<${#ADDING_LIST[@]}; i++)); do
    jsstr=$jsstr'rs.add({host:"'$(getIp ${ADDING_LIST[i]})\:$MY_PORT'"});'
  done
  runMongoCmd "$jsstr" $MONGODB_USER_SYS $(getSysUserPasswd)
}

# sortHostList
# $1-n: hosts array
# output
#  same as $1, if there's no primary member in the hosts array
#  or primary is the last item
sortHostList() {
  local res=''
  local mas=''
  until [ $# -eq 0 ]; do
    if rsIsMaster $(getIp $1); then
      mas=$1
    else
      res=$res" $1"
    fi
    shift
  done
  res=$res" $mas"
  echo $res
}

# rsDummyNodes
# $1: primary ip
# $2-x: node list, sid1|ip1 sid2|ip2
rsDummyNodes() {
  local master=$1
  shift
  local list=($@)
  local cmpstr=''
  for ((i=0; i<${#list[@]}; i++)); do
    cmpstr=$cmpstr$(getIp ${list[i]})\:$MY_PORT" "
  done
  local jsstr=$(cat <<EOF
tmpstr="$cmpstr"
cfg=rs.conf()
for(i=0;i<cfg.members.length;i++) {
  if (tmpstr.indexOf(cfg.members[i].host) != -1) {
    cfg.members[i].priority = 0
    cfg.members[i].votes = 0
  }
}
rs.reconfig(cfg)
EOF
)
  runMongoCmd "$jsstr" "$MONGODB_USER_SYS" $(getSysUserPasswd) "$(getIp $master)"
}

rsNodeStepDown() {
  if runMongoCmd "rs.stepDown()" "$MONGODB_USER_SYS" $(getSysUserPasswd) "$(getIp $1)"; then
    :
  fi
}

rsDoRmNodes() {
  local master=$1
  shift
  local list=($@)
  local cmpstr=''
  for ((i=0; i<${#list[@]}; i++)); do
    cmpstr=$cmpstr$(getIp ${list[i]})\:$MY_PORT" "
  done
  local jsstr=$(cat <<EOF
tmpstr="$cmpstr"
members=[]
cfg=rs.conf()
for(i=0;i<cfg.members.length;i++) {
  if (tmpstr.indexOf(cfg.members[i].host) != -1) {
    continue
  }
  members.push(cfg.members[i])
}
cfg.members = members
rs.reconfig(cfg)
EOF
)
  runMongoCmd "$jsstr" "$MONGODB_USER_SYS" $(getSysUserPasswd) "$(getIp $master)"
}

rsRmNodes() {
  local slist=''
  local jsstr=''
  local master=$(getCurrentMaster)

  #only for test
  #local DELETING_LIST=('2|172.23.4.12'  )

  # prevent deleting nodes from being primary again
  # reconfig deleting nodes' priority = 0, votes = 0
  slist=($(sortHostList ${DELETING_LIST[@]}))
  if [ "${slist[-1]}" != "$master" ]; then
    log "dummy normal nodes ... $(echo ${slist[@]})"
    rsDummyNodes "$master" $(echo ${slist[@]})
  else
    log "dummy nodes including primary node ..."
    if [ ${#slist[@]} -gt 1 ]; then
      log "dummy normal nodes ... $(echo ${slist[@]} | cut -d' ' -f1-$((${#slist[@]}-1)))"
      rsDummyNodes "$master" $(echo ${slist[@]} | cut -d' ' -f1-$((${#slist[@]}-1)))
    fi
    log "primary node step down ..."
    rsNodeStepDown "$master"

    # wait for replicaSet's status to be ok
    log "waiting for replicaSet's status to be ok"
    retry 1200 3 0 rsIsStatusOK y
    sleep 5s

    # dummy old primary node
    log "dummy old primary node: ${slist[-1]}"
    master=$(getCurrentMaster)
    rsDummyNodes "$master" $(echo ${slist[-1]})
  fi

  # wait for repliatSet's status to be ok
  log "waiting for replicaSet's status to be ok"
  retry 1200 3 0 rsIsStatusOK y
  sleep 5s

  # change of priority may leads to re-election
  # find the primary node to do rm action
  log "Do Remove Action! $(echo ${slist[@]})"
  master=$(getCurrentMaster)
  rsDoRmNodes "$master" $(echo ${slist[@]})
}

createReplKey() {
  echo "$GLOBAL_UUID" | base64 > "$MONGODB_CONF_PATH/repl.key"
}

getSysUserPasswd() {
  echo "111111" # just for testing
}

# rsIsStatusOK
# all nodes' status: one: primary; others: secondary
# $?: 0-ok,1-not ok
rsIsStatusOK() {
  local jsstr=$(cat <<EOF
members=rs.status().members
if (members.filter(m => /(1|2)/.test(m.state)).length != ${#NODE_LIST[@]}) {
  quit(${MS_REPLNOTREADY})
} else if (members.filter(m => /(1)/.test(m.state)).length != 1) {
  quit(${MS_REPLNOTREADY})
}
EOF
)

  if [ $# -lt 1 ]; then
    runMongoCmd "$jsstr"
  else
    runMongoCmd "$jsstr" "$MONGODB_USER_SYS" $(getSysUserPasswd)
  fi
  return $?
}

mongodbAddFirstUser() {
  local jsstr=$(cat <<EOF
admin = db.getSiblingDB("admin")
admin.createUser(
  {
    user: "$MONGODB_USER_SYS",
    pwd: "$(getSysUserPasswd)",
    roles: [ { role: "root", db: "admin" } ]
  }
)
EOF
)
  runMongoCmd "$jsstr"
}

mongodbAddCustomUser() {
  local jsstr=$(cat <<EOF
admin = db.getSiblingDB("admin")
admin.createUser(
  {
    user: "$MONGODB_USER_ROOT",
    pwd: "$MONGODB_USER_PASSWD",
    roles: [ { role: "root", db: "admin" } ]
  }
)
admin.createUser(
  {
    user: "$MONGODB_USER_CUSTOM",
    pwd: "$MONGODB_USER_PASSWD",
    roles: [ { role: "readWriteAnyDatabase", db: "admin" } ]
  }
)
EOF
)
  runMongoCmd "$jsstr" "$MONGODB_USER_SYS" "$(getSysUserPasswd)"
}

rsResetPriority() {
  local jsstr=$(cat <<EOF
cfg = rs.conf()
me = rs.isMaster().me
for (i=0; i<cfg.members.length; i++) {
  if (cfg.members[i].host == me) {
    break
  }
}
cfg.members[i].priority = 1
rs.reconfig(cfg)
EOF
)
  runMongoCmd "$jsstr" $MONGODB_USER_SYS $(getSysUserPasswd)
}

# hook functions
initNode() {
  _initNode
  log "create /data/db"
  if [ ! -d /data/db ]; then
    mkdir /data/db
    chown mongod:svc /data/db
  fi
  log "create repl.key"
  if [ ! -f $MONGODB_CONF_PATH/repl.key ]; then
    createReplKey
    chown mongod:svc $MONGODB_CONF_PATH/repl.key
    chmod 400 $MONGODB_CONF_PATH/repl.key
  fi
}

initCluster() {
  isClusterInitialized && return

  if [ "$ADDING_HOSTS" = "true" ]; then _initCluster; log "adding node $MY_SID $MY_IP, skipping"; return; fi

  local res=0

  log "replica set init: DO INIT, $MY_SID $MY_IP"
  rsDoInit
  
  log "waiting for replica set initalization ..."
  retry 1200 3 0 rsIsStatusOK
  sleep 5s

  log "replica set init: Add First User, $MY_SID $MY_IP"
  mongodbAddFirstUser

  log "replica set init: Add Custom User, $MY_SID $MY_IP"
  mongodbAddCustomUser

  log "replica set init: Reset Primary Node's priority, $MY_SID $MY_IP"
  rsResetPriority

  log "replica set init: All done!"
  _initCluster
}

scaleOut() {
  if ! rsIsMaster; then log "scale out: not the master, skipping $MY_SID $MY_IP"; return; fi
  
  log "primary DO scaleOut $(echo ${ADDING_LIST[@]})"
  rsAddNodes
  log "primary DO scaleOut: done"
}

scaleIn() {
  log "primary DO scaleIn: $(echo ${DELETING_LIST[@]})"
  rsRmNodes
  log "primary DO scaleIn: done"
}

mytest() {
  local tmp=('1|172.23.4.21' '2|172.23.4.17' '3|172.23.4.18' )
  #a=($(sortHostList ${tmp[*]}))
  echo ${a[*]}
}