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
    tmp=`$MONGOSHELL --eval "$1"`
  elif [ $# -eq 2 ]; then
    tmp=`$MONGOSHELL $2 --eval "$1"`
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
  if [ "$ADDING_HOSTS" = "true" ];then return; fi
  sleep 1
  # to-do: init replica set
  # follow shoud be changed
  local tmp=`doMongoShell "rs.status()"`
  local status=`echo "$tmp" | head -n1`
  if [ "$status" -ne 0 ]; then return $status; fi
  local ok=`echo "$tmp" | sed -n "2,$p" | jq ".ok"`
}

scaleOut() {
  
}