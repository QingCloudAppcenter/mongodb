#!/usr/bin/env bash

caddy_stat=$(systemctl is-active caddy)
if [ $caddy_stat == active ]
then
    systemctl restart caddy
fi