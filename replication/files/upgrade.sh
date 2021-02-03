#!/usr/bin/env bash

set -eo pipefail

main() {
  local readonly oldMongoVersion=3.4.5
  local readonly newMongoVersion=3.4.17

  if [ ! -d /opt/mongodb/$oldMongoVersion ]; then
    echo "backup old files ..."
    mv /opt/mongodb /opt/$oldMongoVersion
    mkdir /opt/mongodb
    mv /opt/$oldMongoVersion /opt/mongodb/
  fi
  echo "copying new files ..."
  rsync -aAX /upgrade/opt/mongodb/ /opt/mongodb/
  ln -snf $newMongoVersion/bin /opt/mongodb/bin
  echo "restarting mongodb ..."
  /opt/mongodb/bin/restart-mongod-server.sh
}

main
