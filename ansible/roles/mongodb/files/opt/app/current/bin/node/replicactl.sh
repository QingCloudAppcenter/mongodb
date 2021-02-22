# sourced by /opt/app/current/bin/ctl.sh
# ERRORCODE
SYS_BADPARAMS=50
MS_CONNECT=51
MS_SHELLEVAL=52
MS_SYNTAXERR=53
MS_UNKNOWN=99

# common functions

# doMongoShell
# desc: call mongo shell and get the result
# $1: script string
# output: 
#  errorcode
#  json string
doMongoShell() {
  local tmp
  if [ "$#" -ne 1 ]; then echo $SYS_BADPARAMS; return; fi

  if tmp=`echo "$1" | $MONGOSHELL`; then
    echo 0
    echo `echo "$tmp" | sed '1,3d;$d'`
  else
    if [ "`echo "$tmp" | grep '^@(connect)' -o`" = '@(connect)' ]; then
      echo $MS_CONNECT
    elif [ "`echo "$tmp" | grep '^@(shell eval)' -o`" = '@(shell eval)' ]; then
      echo $MS_SHELLEVAL
    elif [ "`echo "$tmp" | grep 'SyntaxError' -o`" = 'SyntaxError' ]; then
      echo $MS_SYNTAXERR
    else
      echo $MS_UNKNOWN
    fi
  fi
}

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
    cmd="$cmd --username $1 --password $2 --authenticationDatabase admin"
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

# rsNeedInit
# desc: judge wether the replica set need init
# $?: 0-need, 1-needn't
rsNeedInit() {
  local tmp=`doMongoShell "JSON.stringify(rs.status())"`
  local retcode=`echo "$tmp" | head -n1`
  if [ "$retcode" -ne 0 ]; then return 1; fi

  local okstatus=`echo "$tmp" | sed -n '2,$p' | jq ".ok"`
  if [ "$okstatus" -eq 1 ]; then return 1; fi

  local code=`echo "$tmp" | sed -n '2,$p' | jq ".code"`
  # code 94:
  # codename: NotYetInitialized
  if [ "$code" -ne 94 ]; then reutrn 1; fi
}

# rsDoInit
# desc: init a replica set
# output:
#  mongo shell: $?, if $? != 0 or
#  mongo shell return code, if ok != 1 or
#  0
rsDoInit() {
  local memberstr=''
  local curmem=''
  for ((i=0; i<${#NODE_LIST[@]}; i++)); do
    if [ "$(getIp ${NODE_LIST[i]})" = "$MY_IP" ]; then
      curmem="{_id:$i,host:\"$MY_IP\",priority:2}"
    else
      curmem="{_id:$i,host:\"$(getIp ${NODE_LIST[i]})\"}"
    fi

    if [ "$i" -eq 0 ]; then
      memberstr=$curmem
    else
      memberstr="$memberstr,$curmem"
    fi
  done

  local initjs=$(cat <<EOF
JSON.stringify(rs.initiate({
  _id:"$RSNAME",
  members:[$memberstr]
}))
EOF
)
  local tmp=`doMongoShell "$initjs"`
  local retcode=`echo "$tmp" | head -n1`
  if [ "$retcode" -ne 0 ]; then echo $retcode; return; fi
  
  local okstatus=`echo "$tmp" | sed -n '2,$p' | jq ".ok"`
  if [ "$okstatus" -eq 1 ]; then echo 0; return; fi

  local code=`echo "$tmp" | sed -n '2,$p' | jq ".code"`
  echo $code
}

# rsIsMaster
# desc: judge wether the node is master/primary
# $?: 0-yes, 1-no
rsIsMaster() {
  local tmp=`doMongoShell "JSON.stringify(rs.isMaster())"`
  local retcode=`echo "$tmp" | head -n1`
  if [ "$retcode" -ne 0 ]; then return 1; fi

  local okstatus=`echo "$tmp" | sed -n '2,$p' | jq ".ok"`
  if [ "$okstatus" -ne 1 ]; then return 1; fi

  local ismaster=`echo "$tmp" | sed -n '2,$p' | jq ".ismaster"`
  # ismaster: true/false

  if [ "$ismaster" = "false" ]; then reutrn 1; fi
}

rsAddNodes() {
  local tmp=''
  for ((i=0; i<${#ADDING_LIST[@]}; i++)); do
  # tmp=`doMongoShell "rs.add({host:\"$(getIp ${ADDING_LIST[i]})\",priority:0,votes:0})"`
    tmp=`doMongoShell "rs.add({host:\"$(getIp ${ADDING_LIST[i]})\"})"`
  done
}

rsRmNodes() {
  local tmp=''
  for ((i=0; i<${#DELETING_LIST[@]}; i++)); do
    tmp=`doMongoShell "rs.remove(\"$(getIp ${DELETING_LIST[i]}):$MY_PORT\")"`
  done
}

createReplKey() {
  echo "$GLOBAL_UUID" | base64 > "$MONGODB_CONF_PATH/repl.key"
}

getFirstUserPasswd() {
  echo "111111" # just for testing
}

rsIsMyStateOK() {
  local tmp=$(runMongoCmd "JSON.stringify(rs.status())")
  local state=$(echo "$tmp" | jq ".myState")
  log "$tmp"
  if [ "$state" -ne 1 ]; then return 1; fi
}

mongodbAddFirstUser() {
  local jsstr=$(cat <<EOF
admin = db.getSiblingDB("admin")
admin.createUser(
  {
    user: "$MONGODB_USER_SYS",
    pwd: "$(getFirstUserPasswd)",
    roles: [ { role: "root", db: "admin" } ]
  }
)
EOF
)
  runMongoCmd "$jsstr"
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

log "checking need init"
  rsNeedInit || return
log "must init"

  local res=0

  log "replica set init: DO INIT, $MY_SID $MY_IP"
  res=`rsDoInit`
  if [ "$res" -ne 0 ]; then log "replica set init: FAILED!"; return $res; fi
  
  # wait for replica set initalization
  retry 1200 3 0 rsIsMyStateOK

  log "replica set init: Add First User, $MY_SID $MY_IP"
  mongodbAddFirstUser

  _initCluster
}

scaleOut() {
  if ! rsIsMaster; then log "replica set scale out: not the master, skipping $MY_SID $MY_IP"; return; fi
  log "primary DO scaleOut: begin"
  rsAddNodes
  log "primary DO scaleOut: done"
}

stop() {
  log "do stop $MY_SID $MY_IP"
  _stop
}

scaleIn() {
  # to-do: judge if primary node is to be deleted
  # to-do: primary node step down first!
  if ! rsIsMaster; then log "replica set scale in: not the master, skipping $MY_SID $MY_IP"; return; fi
  log "primary DO scaleIn: begin"
  rsRmNodes
  log "primary DO scaleIn: done"
}

destroy() {
  log "do destroy $MY_SID $MY_IP"
  _destroy
}

mytest() {
  local jsstr=$(cat <<EOF
admin = db.getSiblingDB("admin")
admin.createUser(
  {
    user: "user1",
    pwd: "111111",
    roles: [ { role: "root", db: "admin" } ]
  }
)
EOF
)
  runMongoCmd "$jsstr" qc_master 111111
}