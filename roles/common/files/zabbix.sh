#!/usr/bin/env bash

is_start_zabbix=$(curl -s http://metadata/self/env/zabbix.agent.enabled)
zabbix_agent_status=$(systemctl is-active zabbix-agent)

chown zabbix:zabbix /data/zabbix-agent/logs
if test ${is_start_zabbix} == yes;then
# zabbix.server.addr 为空的情况下也可以启动，但是server 端无法连接
    if test ${zabbix_agent_status} == inactive;then
        systemctl start zabbix-agent
    else
        # 处理 zabbix 的 revive 问题
        if test "$1" == "revive";then
            if test ${zabbix_agent_status} == active;then
                echo "zabbix-agent is active"
                exit 0
            fi
        fi
        systemctl restart zabbix-agent
    fi
elif test ${is_start_zabbix} == no;then
    if test ${zabbix_agent_status} != inactive;then
        systemctl stop zabbix-agent
    fi
fi

# 防止启动时调用该脚本 return_code != 0，导致 mongo 服务异常
if test "$1" == "start";then
    exit 0
fi