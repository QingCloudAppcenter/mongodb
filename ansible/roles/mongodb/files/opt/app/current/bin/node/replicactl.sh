# sourced by /opt/app/current/bin/ctl.sh
# ERRORCODE
SYS_BADPARAMS=50
MS_CONNECT=51
MS_SHELLEVAL=52
MS_UNKNOWN=99

# common functions

# doMongoShell
# desc: call mongo shell and get the result
# $1: script string
# $2: connection string(option: default 127.0.0.1)
# output: 
#  errorcode
#  json string
doMongoShell() {
  local tmp
  local para=''
  if [ $# -eq 1 ]; then
    para="--eval JSON.stringify($1)";
  elif [ $# -eq 2 ]; then
    para="--eval JSON.stringify($1) --host $2";
  else
    echo $SYS_BADPARAMS
    return
  fi
  
  if tmp=`$MONGOSHELL $para`; then
    echo 0
    echo `echo "$tmp" | sed -n '4,$p'`
  else
    if [ "`echo "$tmp" | grep '^@(connect)' -o`" = '@(connect)' ]; then
      echo $MS_CONNECT
    elif [ "`echo "$tmp" | grep '^@(shell eval)' -o`" = '@(shell eval)' ]; then
      echo $MS_SHELLEVAL
    else
      echo $MS_UNKNOWN
    fi
  fi
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
# $1: connection string(option: default 127.0.0.1)
# $?: 0-need, 1-needn't
rsNeedInit() {
  local tmp=`doMongoShell "rs.status()" "$@"`
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
# $1: connection string(option: default 127.0.0.1)
# output:
#  mongo shell: $?, if $? != 0 or
#  mongo shell return code, if ok != 1 or
#  0
rsDoInit() {
  local memberstr=''
  if [ "${#NODE_LIST[@]}" -eq 1 ]; then
      memberstr="{_id:0,host:\"$(getIp ${NODE_LIST[0]})\"}"
  else
      for ((i=0; i<${#NODE_LIST[@]}; i++)); do
          if [ "$i" -eq 0 ]; then
              memberstr="{_id:$i,host:\"$(getIp ${NODE_LIST[i]})\"}"
          else
              memberstr="$memberstr,{_id:$i,host:\"$(getIp ${NODE_LIST[i]})\"}"
          fi
      done
  fi

  local initjs=$(cat <<EOF
rs.initiate({
  _id:"$RSNAME",
  members:[$memberstr]
})
EOF
)
  local tmp=`doMongoShell "$initjs" "$@"`
  local retcode=`echo "$tmp" | head -n1`
  if [ "$retcode" -ne 0 ]; then echo $retcode; return; fi

  local okstatus=`echo "$tmp" | sed -n "2,$p" | jq ".ok"`
  if [ "$okstatus" -eq 1 ]; then echo 0; return; fi

  local code=`echo "$tmp" | sed -n "2,$p" | jq ".code"`
  echo $code
}

# hook functions
init() {
  if [ ! -d /data/db ];then
    mkdir /data/db
    chown mongod:svc /data/db
  fi
  _init
}

start() {
  _start
  if [ "$ADDING_HOSTS" = "true" ]; then return; fi
  sleep 1

  # first node do init
  local sid=`getSid ${NODE_LIST[0]}`
  if [ "$sid" != "$MY_SID" ]; then log "replica set init: skipping $MY_SID $MY_IP"; return; fi

  local res=0
  if rsNeedInit; then
    res=`rsDoInit`
  else
    log "replica set init: no need, skipping"
  fi

  return $res
}

scaleOut() {
  :
}