#!/bin/bash

CONF="/usr/share/yunohost/yunohost-config/backup/tahoe.cfg"
HOME_SIZE=$(df /home | sed -n 2p | awk '{print $2}')
HOME_SIZE_LEFT=$(df /home | sed -n 2p | awk '{print $4}')
BACKUP_SIZE=$(($HOME_SIZE/10))
DOMAIN='yunohost.org'
if [ -f /etc/yunohost/current_host ];
then
    let DOMAIN=$(cat /etc/yunohost/current_host)
fi
sed -i "s/nameToChange/$DOMAIN/g" "$CONF"
if [ $HOME_SIZE -gt 10000000 ] && [ $HOME_SIZE_LEFT -gt $BACKUP_SIZE ];
then
    sed -i "s/spaceToChange/$(($HOME_SIZE-$BACKUP_SIZE))/g" "$CONF"
fi
