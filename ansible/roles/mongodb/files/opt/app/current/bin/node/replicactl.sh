# sourced by /opt/app/current/bin/ctl.sh

# ERRORCODE
SYS_BADPARAMS=50
MS_CANNOTREACH=51
MS_BADSCRIPTS=52

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
  if [ $# -eq 1 ]; then
    tmp=`$MONGOSHELL --eval "JSON.stringify($1)"`
  elif [ $# -eq 2 ]; then
    tmp=`$MONGOSHELL $2 --eval "JSON.stringify($1)"`
  else
    tmp=''
  fi
  if [ "`echo "$tmp" | sed -n '3p' | grep ^Error -o`" = 'Error' ]; then
    echo $MS_CANNOTREACH
    return
  fi
  if [ "`echo "$tmp" | sed -n '5p' | grep ^uncaught -o`" = 'uncaught' ]; then
    echo $MS_BADSCRIPTS
    return 
  fi
  if [ -z "$tmp" ]; then
    echo $SYS_BADPARAMS
    return
  fi
  echo 0
  echo `echo "$tmp" | sed -n '5,$p'`
}

# getSid
# desc: get sid from nodelist string
# $1: a nodelist item (5|192.168.1.2)
# output: sid
getSid() {
  echo `echo $1 | cut -d'|' -f1`
}

# getIp
# desc: get ip from nodelist string
# $1: a nodelist item (5|192.168.1.2)
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

  local okstatus=`echo "$tmp" | sed -n "2,$p" | jq ".ok"`
  if [ "$okstatus" -eq 1 ]; then return 1; fi

  local code=`echo "$tmp" | sed -n "2,$p" | jq ".code"`
  # code 94:
  # codename: NotYetInitialized
  if [ "$code" -ne 94 ]; then reutrn 1; fi
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

  rsNeedInit
  if [ "$?" -ne 0 ]; then log "replica set init: already inited"; return; fi

  log "pretend to init replica set"
}

scaleOut() {
  :
}