#!/usr/bin/env bash

if test $(systemctl is-active caddy) != inactive; then
    systemctl restart caddy
fi