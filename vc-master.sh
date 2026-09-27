#!/bin/bash
# Start master-process in the chroot (virtualised), with a session bus + key creator.
# Meant to run detached:  sudo setsid bash /opt/virtualtools/vc-master.sh </dev/null >/tmp/vc-master.log 2>&1 &
ROOT=/opt/rfconnector
exec chroot "$ROOT" /usr/bin/env -i \
  PATH=/usr/sbin:/usr/bin:/sbin:/bin \
  RAUMFELD_VIRTUALISED_HARDWARE_ID=9 \
  G_FILENAME_ENCODING=UTF-8,ISO-8859-1 \
  RAUMFELD_LOG_TARGET=stderr \
  HOME=/root \
  /bin/sh -lc '
    eval $(dbus-launch --sh-syntax)
    echo "[vc] SESSION=$DBUS_SESSION_BUS_ADDRESS"
    /raumfeld/hardwared/hw-cli set-indication initializing 2>/dev/null
    echo "[vc] raumfeld-key-creator:"; /usr/bin/raumfeld-key-creator 2>&1 | tail -3
    cd /raumfeld/master-process
    echo "[vc] exec master-process"
    exec ./master-process
  '
