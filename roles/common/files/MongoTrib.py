#!/usr/bin/env python
# -*- coding: utf-8 -*-
import base64
import httplib
import json
import logging.handlers
import os
import socket
import subprocess
import sys
import time

import bson
import re
import yaml
from pymongo import MongoClient
from pymongo.errors import OperationFailure
import ZabbixEnv


def json_dumps(_dict):
    return json.dumps(_dict, sort_keys=False, default=str)


def exec_cmd(cmd):
    """
    :param cmd: the command you want to call
    :return: ret_code, output
    """
    try:
        ret = subprocess.check_output(cmd, shell=True)
        return 0, ret
    except subprocess.CalledProcessError as e:
        return e.returncode, e.output


class MongoError(Exception):
    pass


def help():
    print 'Guide: ./MongoTrib.py [gen_conf,init,init_replication,health_check,info,help,monitor,reconfig]'


DEFAULT_PORT = 27017
RECONFIG_PORT = 37017
DEFAULT_REPL_SET_NAME = 'foobar'
DEFAULT_MAX_CONNS = 2048
DEFAULT_OPLOG_SIZE = 1024
# DEFAULT_CACHE_SIZE = "256 MB"
REPL_CONF_INVALID = 'Our replica set config is invalid or we are not a member of it'
# NO_CONFIG = "no replset config has been received"

NOT_REACHABLE = "(not reachable/healthy)"
NOT_REACHABLE_INFO = "Error connecting to {}:27017 :: caused by :: No route to host"


class Mongo(object):
    conf = {}
    _port = None
    _auth = None

    ROLE_NAME_PRIORITY0 = 'priority0'
    ROLE_NAME_REPLICA = 'replica'
    ROLE_NAME_SECONDARY = 'secondary'

    MONGO_USER_PITRIX = "qc_master"
    MONGO_USER_ROOT = "root"
    MONGO_ROLE_ROOT = "root"
    MONGO_ROLE_RW_ANY_DB = "readWriteAnyDatabase"
    MONGO_DEFAULT_SERVER_STATUS_KEYS = (
        'connections', 'opcounters', 'opcountersRepl', 'metrics', 'repl',
        'storageEngine', 'network', 'locks', 'globalLock', 'extra_info', 'dur',
        'cursors', 'backgroundFlushing', 'asserts', 'opLatencies')

    DATA_PATH = "/data/mongodb/"
    INFO_DIR = "/data/info/"
    MONGOD_COPY_LOG_DIR = "/data/logs/"
    CONF_PATH = '/etc/mongod.conf'
    LOGGER_PATH = INFO_DIR + 'mongo-trib.log'
    MONGOD_LOG_PATH = DATA_PATH + 'mongod.log'
    PASSWD_PATH = '/data/pitrix.pwd'
    KEY_FILE_PATH = '/etc/mongodb.key'
    IGNORE_AGENT_PATH = '/usr/local/etc/ignore_agent'
    RECONFIG_PATH = '/usr/local/etc/reconfig'

    START_CMD = '/opt/app/bin/start-mongod-server.sh'
    STOP_CMD = '/opt/app/bin/stop-mongod-server.sh'
    HOSTNAME = socket.gethostname()
    LOGGER_LEVEL = logging.INFO
    # LOGGER_LEVEL = logging.DEBUG

    IP_FILE = INFO_DIR + "ip.info"

    START_CADDY_CMD = "systemctl start caddy"
    STOP_CADDY_CMD = "systemctl stop caddy"

    ZABBIX_CMD = "/opt/app/bin/zabbix.sh revive"
    MONGO_VERSION_FILE = INFO_DIR + "version.info"
    CADDY_DIR = "/data/caddy"

    MONITOR_INFO = {'opcounters': {'insert': None, 'delete': None, 'update': None, 'query': None},
                    'network': {'physicalBytesOut': None, 'bytesOut': None, 'physicalBytesIn': None, 'bytesIn': None},
                    'opcountersRepl': {'insert': None, 'delete': None, 'update': None, 'query': None},
                    'wiredTiger': {
                        'concurrentTransactions': {'write': {'available': None, 'out': None},
                                                   'read': {'available': None, 'out': None}},
                        'cache': {'tracked dirty pages in the cache': None, 'maximum bytes configured': None,
                                  'bytes written from cache': None, 'bytes currently in the cache': None,
                                  'bytes read into cache': None}},
                    'connections': {'available': None, 'current': None, 'totalCreated': None},
                    'globalLock': {'currentQueue': {'total': None, 'writers': None, 'readers': None},
                                   'activeClients': {'total': None, 'writers': None, 'readers': None}}}

    def __init__(self):
        self.logger = self.init_logger()

    def init_logger(self):
        cmd = "mkdir -p " + self.INFO_DIR
        os.system(cmd)
        rthandler = logging.handlers.RotatingFileHandler(self.LOGGER_PATH, maxBytes=20 * 1024 * 1024, backupCount=5)
        formatter = logging.Formatter('%(asctime)s -%(thread)d- [%(levelname)s] %(message)s (%(filename)s:%(lineno)d)')
        rthandler.setFormatter(formatter)

        logger = logging.getLogger('mongo-trib')
        logger.addHandler(rthandler)
        logger.setLevel(self.LOGGER_LEVEL)
        return logger

    @property
    def port(self):
        if self._port is None:
            self.load_conf()
        return self._port

    @property
    def auth(self):
        if self._auth is None:
            self.load_conf()
        return self._auth

    @property
    def first_node(self):
        meta_data = self.get_meta_data()
        if meta_data['host']['role'] == self.ROLE_NAME_PRIORITY0:
            self.logger.info('Current instance is not the first node')
            return False
        cur_sid = int(meta_data['host']['sid'])
        members = self.get_members()
        for member in members:
            if int(member['sid']) < cur_sid:
                self.logger.info('Current instance is not the first node')
                return False
        return True

    def has_ignore_agent(self):
        return os.path.isfile(self.IGNORE_AGENT_PATH)

    def open_conf(self, mode='r'):
        return open(self.CONF_PATH, mode)

    def load_conf(self):
        with self.open_conf() as f:
            conf_content = f.read()
        self.conf = yaml.load(conf_content)
        self._port = self.conf.get('net', {}).get('port', DEFAULT_PORT)
        self._auth = self.conf.get('security', {}).get('authorization', 'enabled') == 'enabled'

    def get_cache_size(self, meta_data, version=None):
        node_memory = int(meta_data.get("host", {}).get("memory", {}))  # 单位 mb
        env = meta_data.get('env', {})
        cache_size = max(round(int(env.get("cacheSizeUsage")) * node_memory / 100, 2) / 1024,
                         1.0) if version == "3.2" else max(
            round(int(env.get("cacheSizeUsage")) * node_memory / 100, 2) / 1024,
            0.25)  # 见 https://docs.mongodb.com/v3.2/faq/storage/
        cache_size = min(round(node_memory - 256, 2) / 1024, cache_size)
        return cache_size

    def gen_conf(self, auth=True, rs=True, key_file=True, port=None):
        self.logger.info('call func gen_conf with arguments [%s]', locals())
        meta_data = self.get_meta_data()
        env = meta_data.get('env', {})
        max_conns = env.get('maxConns', DEFAULT_MAX_CONNS)
        oplog_size = env.get('oplogSize', DEFAULT_OPLOG_SIZE)
        new_port = env.get('port', DEFAULT_PORT)
        cache_size = self.get_cache_size(meta_data)
        if port:
            new_port = port
        conf_content = """
systemLog:
  destination: file
  path: "%(log_path)s" 
  logAppend: true 
storage:
  dbPath: "%(data_path)s"
  engine: wiredTiger
  journal:
    enabled: true
  wiredTiger:
    engineConfig:
      cacheSizeGB: %(cache_size).2f
processManagement:
   fork: true
   pidFilePath: /data/mongodb/mongod.pid
net:
  bindIp: 0.0.0.0
  port: %(port)s
  maxIncomingConnections: %(max_conns)s
replication:
  oplogSizeMB: %(oplog_size)s 
  replSetName: %(set_name)s
security:
  authorization: %(authorization)s
  keyFile: %(key_file_path)s
""" % {
            "max_conns": max_conns,
            "oplog_size": oplog_size,
            "authorization": "enabled" if auth else "disabled",
            "key_file_path": self.KEY_FILE_PATH,
            "set_name": DEFAULT_REPL_SET_NAME,
            "port": new_port,
            "cache_size": cache_size,
            "data_path": self.DATA_PATH,
            "log_path": self.MONGOD_LOG_PATH
        }
        if not rs:
            conf_content = conf_content.replace('replSetName', '# replSetName')
        if not key_file:
            conf_content = conf_content.replace('keyFile', '# keyFile')
        with self.open_conf('w+') as f:
            f.write(conf_content)
            f.flush()
            os.fsync(f.fileno())
        self.load_conf()

    def connect(self, host, primary=False):
        mongo_uri = 'mongodb://%s:%s/admin' % (host, self.port)
        if self.auth:
            mongo_uri = 'mongodb://%s:%s@%s:%s/admin' % \
                        (self.MONGO_USER_PITRIX, self.get_pitirx_passwd(), host, self.port)

        if primary:
            client = MongoClient(mongo_uri, replicaset=DEFAULT_REPL_SET_NAME)
        else:
            client = MongoClient(mongo_uri)
        return client

    def connect_local(self):
        return self.connect('127.0.0.1')

    def connect_primary(self):
        return self.connect('127.0.0.1', primary=True)

    def get_meta_data_from_metad(self, host):
        conn = httplib.HTTPConnection(host)
        conn.request('GET', '', headers={'Accept': 'application/json'})
        res = conn.getresponse()
        if res.status != 200:
            return {}
        data = res.read()
        meta_data = json.loads(data)
        return meta_data['self']

    def get_meta_data(self):
        meta_data = self.get_meta_data_from_metad('metadata')
        return meta_data

    def get_member_id(self, member):
        return int(member['sid']) - 1

    def get_member_priority(self, member):
        return 2 if int(member['sid']) == 1 else 1

    def get_member_host(self, member, port=None):
        if not port:
            port = self.port
        return '%s:%s' % (member['ip'], port)

    def get_member_config(self, member):
        return {
            '_id': self.get_member_id(member),
            'host': self.get_member_host(member),
            'priority': self.get_member_priority(member),
            'tags': {
                'qc_sid': member['sid'],
                'qc_node_id': member['node_id'],
            },
        }

    def get_replica_conf(self, members):
        cmd = {
            '_id': DEFAULT_REPL_SET_NAME,
            'members': [self.get_member_config(member) for member in members]
        }
        return cmd

    def get_server_status_params(self, **keys):
        all_keys = {k: 0 for k in self.MONGO_DEFAULT_SERVER_STATUS_KEYS}
        all_keys.update({k: int(bool(k)) for k in keys})
        return all_keys

    def parse_server_status(self, _server_status):
        monitor_fields = {"monitor_info": self.MONITOR_INFO, "monitor_key": "", "monitor_value": None,
                          "server_status": {}}

        def get_monitor_result(monitor_info, key, _server_status, server_status):
            """
            :param monitor_info: 监控的信息，dict
            :param key: 监控的 key
            :param _server_status: 从服务器获取到的信息
            :param server_status: 用于存储最终结果
            :return: server_status
            """
            # server_status 为 dict
            for monitor_info_key, monitor_info_value in monitor_info.items():
                monitor_fields["monitor_value"] = _server_status.get(monitor_info_key)
                key = key[1:] if "-" in key and key[0] == "-" else key
                monitor_fields["monitor_key"] = key + (
                    "-" + "-".join(monitor_info_key.split(" ")) if monitor_fields["monitor_key"] else "-".join(
                        monitor_info_key.split(" ")))
                if monitor_info_value:
                    get_monitor_result(monitor_info_value, monitor_fields["monitor_key"],
                                       monitor_fields["monitor_value"],
                                       server_status)
                else:
                    server_status[monitor_fields["monitor_key"]] = monitor_fields["monitor_value"]
                    monitor_fields["monitor_value"] = None
            return server_status

        def integrate_monitor_result(monitor_result):
            bytes_in_cache = monitor_result.pop("wiredTiger-cache-bytes-currently-in-the-cache")
            max_cache_configured = monitor_result.pop("wiredTiger-cache-maximum-bytes-configured")
            monitor_result["cache-usage"] = round(bytes_in_cache / float(max_cache_configured), 4) * 10000
            for monitor_result_key, monitor_result_value in monitor_result.items():
                if isinstance(monitor_result_value, bson.int64.Int64):
                    monitor_result[monitor_result_key] = int(monitor_result_value)
                if re.search("bytes", monitor_result_key, re.I):
                    monitor_result[monitor_result_key] = int(monitor_result_value / (1024 * 1024))
            return monitor_result

        server_status = get_monitor_result(monitor_fields["monitor_info"], monitor_fields["monitor_key"],
                                           _server_status, monitor_fields["server_status"])
        final_monitor_result = integrate_monitor_result(server_status)
        return final_monitor_result

    def get_monitor(self):
        c = self.connect_local()
        server_status_params = self.get_server_status_params(**dict(map(lambda x: ("x", 1), self.MONITOR_INFO.keys())))
        ret = c.admin.command('serverStatus', 1, server_status_params)
        return self.parse_server_status(ret)

    def is_master(self):
        c = self.connect_local()
        ret = c.admin.command('isMaster')
        return ret

    def exist_replicaset_member_not_in_metadata(self, replica_members):
        replica_members_ips = map(lambda member: member["name"].split(":")[0], replica_members)
        metadata_members = self.get_members()
        metadata_members_ips = map(lambda member: member["ip"], metadata_members)
        for ip in replica_members_ips:
            if ip not in metadata_members_ips:
                return True
        return False

    def detect_host_changed(self):
        if self.check_local_mongod():
            self.logger.info("mongod 存活")
        if os.path.isfile(self.RECONFIG_PATH):
            self.logger.info('[detect_host_changed] reconfig file exists')
            return
        members = self.get_members()
        members = [{member["node_id"]: member["ip"]} for member in members]
        try:
            c = self.connect_local()
            c.admin.command('replSetGetStatus', 1)

        except Exception as e:
            if isinstance(e, OperationFailure) and REPL_CONF_INVALID in e.message:
                open(self.RECONFIG_PATH, 'a').close()
                try:
                    self.logger.debug("We will reconfig_host")
                    self.reconfig_host()
                    with open(self.IP_FILE, "w") as f:
                        f.write(json.dumps(members))
                    return
                except Exception as e:
                    raise e
                finally:
                    os.remove(self.RECONFIG_PATH)

            self.logger.info('[detect_host_changed] catch error: [%s]', e)
        # 版本问题，mongo 4.0 无法准确检测到 ip 的变化
        if not os.path.exists(self.IP_FILE):
            with open(self.IP_FILE, "w") as f:
                f.write(json.dumps(members))
            return
        with open(self.IP_FILE, "r") as f:
            file_members = json.loads(f.read().strip())
        for member in members:
            if member not in file_members:
                open(self.RECONFIG_PATH, 'a').close()
                try:
                    self.logger.debug("We will reconfig_host")
                    self.reconfig_host()
                    with open(self.IP_FILE, "w") as f:
                        f.write(json.dumps(members))
                    return
                except Exception as e:
                    raise e
                finally:
                    os.remove(self.RECONFIG_PATH)

    def get_env_port(self):
        meta_data = self.get_meta_data()
        env = meta_data.get('env', {})
        return env.get('port', DEFAULT_PORT)

    def update_oplogsize(self):
        """
        {
            "ok": 1,
            "operationTime": Timestamp(1555421134, 1),
            "$clusterTime": {
                "clusterTime": Timestamp(1555421134, 1),
                "signature": {
                    "hash": BinData(0, "CTHfWzPHW3tbVxfGJmV8Ij5DUrk="),
                    "keyId": NumberLong("6680481111035871234")
                }
            }
        }
        """
        env = self.get_env()
        oplog_size = env.get('oplogSize', DEFAULT_OPLOG_SIZE)
        c = self.connect_local()
        ret = c.admin.command({"replSetResizeOplog": 1, "size": int(oplog_size)})
        if ret["ok"] != 1.0:
            self.logger.error("Resize oplogsize fail")
            sys.exit(1)

    def reconfig_host(self):
        self.stop_local_mongod()
        self.gen_conf(auth=False, rs=False, key_file=False, port=RECONFIG_PORT)
        self.start_local_mongod()

        members = self.get_members()
        port = self.get_env_port()
        c = self.connect_local()
        db = c.local
        cfg = db.system.replset.find_one({'_id': DEFAULT_REPL_SET_NAME})
        for member_in_db in cfg['members']:
            member_id = member_in_db['_id']
            for member in members:
                if member_id == self.get_member_id(member):
                    member_in_db['host'] = self.get_member_host(member, port)

        ret = db.system.replset.update({'_id': DEFAULT_REPL_SET_NAME}, cfg)
        self.logger.info('cfg=%s, ret=%s', json_dumps(cfg), json_dumps(ret))

        self.stop_local_mongod()
        self.gen_conf(auth=True, rs=True, key_file=True)
        self.start_local_mongod()

    def get_nodes_names(self):
        c = self.connect_local()
        ret = c.admin.command('replSetGetStatus', 1)
        members = ret['members']
        ip_roles = {}
        for member in members:
            ip = member['name'].split(':')[0]
            role = member['stateStr'].lower()
            ip_roles[ip] = role
        metadata_members = self.get_members()
        nodes_names = {}
        for member in metadata_members:
            cluster_node_id = member['node_id']
            ip = member['ip']
            role = ip_roles[ip]
            if role == self.ROLE_NAME_SECONDARY and self.get_member_priority(member) == 0:
                role = self.ROLE_NAME_PRIORITY0
            nodes_names[cluster_node_id] = role
        print(json_dumps(nodes_names))

    def get_node_details(self):
        c = self.connect_local()
        ret = c.admin.command('replSetGetStatus', 1)
        members = ret['members']
        ip_roles = {}
        for member in members:
            ip = member['name'].split(':')[0]
            role = member['stateStr'].lower()
            ip_roles[ip] = role
        metadata_members = self.get_members()
        node_details = {
            'labels': ['Node', 'IP', 'Role'],
            'data': [],
        }
        for member in metadata_members:
            cluster_node_id = member['node_id']
            ip = member['ip']
            role = ip_roles[ip]
            if role == self.ROLE_NAME_SECONDARY and self.get_member_priority(member) == 0:
                role = self.ROLE_NAME_PRIORITY0
            node_details['data'].append([cluster_node_id, ip, role])
        print(json_dumps(node_details))

    def get_members(self):
        meta_data = self.get_meta_data()
        hosts = meta_data['hosts']
        deleting_hosts = meta_data.get('deleting-hosts', {})
        members = []
        deleting_members = []
        for role, nodes in deleting_hosts.iteritems():
            for instance_id, node in nodes.iteritems():
                deleting_members.append(instance_id)
        for role, nodes in hosts.iteritems():
            for instance_id, node in nodes.iteritems():
                # if node is not deleting
                if instance_id not in deleting_members:
                    members.append(node)
        members = sorted(members, key=lambda member: int(member['sid']))
        return members

    def get_deleting_members(self):
        meta_data = self.get_meta_data()
        deleting_hosts = meta_data.get('deleting-hosts', {})
        deleting_members = []
        for role, nodes in deleting_hosts.iteritems():
            for instance_id, node in nodes.iteritems():
                deleting_members.append(node)
        return deleting_members

    def exec_cmd(self, cmd):
        ret = exec_cmd(cmd)
        self.logger.info('exec cmd: [%s], got ret: [%s]', cmd, ret)
        return ret

    def init_replication(self):
        members = self.get_members()
        # members = filter(lambda member: member['instance_id'] == self.HOSTNAME, members)
        conf = self.get_replica_conf(members)
        conf['version'] = 1
        c = self.connect_local()
        # print 'Current replication status %s' % c.admin.command('replSetGetStatus', 1)
        print 'Initialize replication %s' % json_dumps(conf)
        retry = 5
        while retry > 0:
            try:
                c.admin.command('replSetInitiate', conf)
                return
            except Exception as e:
                retry -= 1
                if retry == 0:
                    raise e
            time.sleep(5)
            print 'Retry [%s] times initialize replication %s' % (retry, json_dumps(conf))

    def get_pitirx_passwd(self):
        if not os.path.isfile(self.PASSWD_PATH):
            self.gen_pitrix_passwd()
        with open(self.PASSWD_PATH, "r") as f:
            pwd = f.read()
        return pwd.strip()

    def gen_pitrix_passwd(self):
        # generate pitrix user password
        meta_data = self.get_meta_data()
        pitrix_passwd = base64.encodestring(meta_data['cluster']['app_id'])
        with open(self.PASSWD_PATH, "w+") as f:
            f.write(pitrix_passwd)
            f.flush()
            os.fsync(f.fileno())
        return pitrix_passwd.strip()

    def get_env(self):
        meta_data = self.get_meta_data()
        return meta_data['env']

    def init_users(self):
        env = self.get_env()
        pitrix_user_passwd = self.gen_pitrix_passwd()
        users = [{
            'name': self.MONGO_USER_PITRIX,
            'pwd': pitrix_user_passwd,
            'roles': [{
                'role': self.MONGO_ROLE_ROOT,
                'db': 'admin',
            }]
        }, {
            'name': env['user'],
            'pwd': env['passwd'],
            'roles': [{
                'role': self.MONGO_ROLE_RW_ANY_DB,
                'db': 'admin',
            }]
        }, {
            'name': self.MONGO_USER_ROOT,
            'pwd': env['passwd'],
            'roles': [{
                'role': self.MONGO_ROLE_ROOT,
                'db': 'admin',
            }]
        }]
        c = self.connect_primary()
        # c = self.connect_local()
        for user in users:
            name = user.pop('name')
            ret = c.admin.command('createUser', name, **user)
            print('Add user with cmd [%s], ret [%s]' % (json_dumps(dict(
                user,
                createUser=name,
            )), ret))
            if not ret['ok']:
                raise MongoError('create user [%s] failed' % name)
        return

    def save_version(self):
        with open(self.MONGO_VERSION_FILE, "w") as f:
            f.write('{"version":"4.0","engine":"WiredTiger"}')

    def init(self):
        self.save_version()
        if not self.first_node:
            print('Current instance is not the first node')
            return
        self.stop_all_mongod()
        self.gen_conf(auth=False, rs=True, key_file=False)
        self.start_all_mongod(sync_conf=True)
        self.init_replication()
        self.init_users()
        self.stop_all_mongod()
        self.gen_conf(auth=True, rs=True, key_file=True)
        self.start_all_mongod(sync_conf=True)

    def reconfig(self):
        members = self.get_members()
        conf = self.get_replica_conf(members)
        c = self.connect_primary()
        ret = c.admin.command('isMaster')
        conf['version'] = ret['setVersion'] + 1
        conf["protocolVersion"] = 1
        primary_host = ret['primary'].split(':')[0]

        deleting_members = self.get_deleting_members()
        for member in deleting_members:
            if member['ip'] == primary_host:
                raise MongoError('cannot delete primary node')
            if member['sid'] == '1':
                raise MongoError('cannot delete first node')

        print 'Reconfig replication with [%s]' % json_dumps(conf)
        ret = c.admin.command('replSetReconfig', conf, force=False)
        print ret

    def get_ssh_cmd(self, ip, cmd):
        return "ssh -q -o 'StrictHostKeyChecking no' -o 'UserKnownHostsFile /dev/null' \
-o ConnectTimeout=5 -o ConnectionAttempts=3 root@%s \"%s\"" % (ip, cmd)

    def check_local_mongod(self):
        cmd = 'nc -z -v -w10 127.0.0.1 %s' % self.port
        ret_code, _ = self.exec_cmd(cmd)
        if ret_code != 0:
            self.logger.error('no process listen at %s', self.port)
            return False
        cmd = 'pidof mongod'
        ret_code, output = self.exec_cmd(cmd)
        if ret_code != 0 or len(output) == 0:
            self.logger.error('cannot find mongod process')
            return False
        return True

    def sync_conf(self, ip):
        conf_files = [self.CONF_PATH]
        for conf_file in conf_files:
            cmd = "scp -q -o 'StrictHostKeyChecking no' -o 'UserKnownHostsFile /dev/null' \
-o ConnectTimeout=5 -o ConnectionAttempts=3 %s root@%s:%s" % (conf_file, ip, conf_file)
            ret_code, output = self.exec_cmd(cmd)
            if ret_code != 0:
                raise MongoError('sync [%s] on [%s] failed: [%s]' % (conf_file, ip, output))

    def exec_on_all_nodes(self, cmd):
        members = self.get_members()
        self.logger.debug('get members: [%s]', members)
        for member in members:
            ip = member['ip']
            instance_id = member['instance_id']
            # copy str
            _cmd = '%s' % cmd
            if instance_id != self.HOSTNAME:
                _cmd = self.get_ssh_cmd(ip, _cmd)

            ret_code, output = self.exec_cmd(_cmd)
            if ret_code != 0:
                raise MongoError('exec [%s] on [%s] failed: [%s]' % (_cmd, ip, output))

    def start_local_mongod(self):
        ret_code, output = self.exec_cmd(self.START_CMD)
        if ret_code != 0 and ret_code != 48:
            raise MongoError('start mongod failed: [%s]' % output)

    def print_connection_string(self):
        metadata = self.get_meta_data()
        mongo_port = metadata["env"]["port"]
        ip_list = list(map(lambda ele: ele["ip"] + ":{}".format(mongo_port), metadata["hosts"]["replica"].values()))
        connection_string = "mongodb://{user}:[password]@{ips}/[database]?replicaSet=foobar&authSource=admin".format(
            user=metadata["env"]["user"], ips=",".join(ip_list))
        connection_string_details = {
            'labels': ['connection_string'],
            'data': [[connection_string]]
        }
        print json.dumps(connection_string_details)

    def stop_local_mongod(self):
        ret_code, output = self.exec_cmd(self.STOP_CMD)
        if ret_code != 0:
            raise MongoError('stop mongod failed: [%s]' % output)

    def start_all_mongod(self, sync_conf=False):
        members = self.get_members()
        for member in members:
            ip = member['ip']
            instance_id = member['instance_id']
            cmd = self.START_CMD
            if instance_id != self.HOSTNAME:
                cmd = self.get_ssh_cmd(ip, cmd)
                if sync_conf:
                    self.sync_conf(ip)

            ret_code, output = self.exec_cmd(cmd)
            if ret_code != 0 and ret_code != 48:
                raise MongoError('start mongod on [%s] failed: [%s]' % (ip, output))

    def drop_all_users(self):
        c = self.connect_local()
        print 'dropAllUsersFromDatabase %s' % c.admin.command('dropAllUsersFromDatabase', 1)

    def cleanup_all_mongod(self):
        self.exec_on_all_nodes('rm -rf /data/mongodb/*')

    def stop_all_mongod(self):
        members = self.get_members()
        for member in members:
            ip = member['ip']
            instance_id = member['instance_id']
            cmd = self.STOP_CMD
            if instance_id != self.HOSTNAME:
                cmd = self.get_ssh_cmd(ip, cmd)

            ret_code, output = self.exec_cmd(cmd)
            if ret_code != 0:
                raise MongoError('stop mongod on [%s] failed: [%s]' % (ip, output))

    def monitor(self):
        # self.logger.info('get monitor info')
        ret = json_dumps(self.get_monitor())
        print ret
        # self.logger.info(ret)

    def health_check(self):
        if self.has_ignore_agent():
            self.logger.info('skip health check, ignore agent file exists')
            return True
        if not self.check_local_mongod():
            raise MongoError('check mongod process failed')
        # get mongo resp via is_master
        self.is_master()

        if not self.check_zabbix_agent():
            raise MongoError("check zabbix-agent fail")

    def check_zabbix_agent(self):
        if ZabbixEnv.is_start_zabbix == "yes":
            cmd = "systemctl is-active zabbix-agent"
            retcode, output = self.exec_cmd(cmd)
            return retcode == 0 and output.strip() == "active"

        if ZabbixEnv.is_start_zabbix == "no":
            cmd = "systemctl is-active zabbix-agent"
            retcode, output = self.exec_cmd(cmd)
            # systemctl is-active zabbix-agent 结果为 inactive 的话，$? 为非0
            return output.strip() == "inactive"

    def revive_zabbix(self):
        retcode, output = self.exec_cmd(self.ZABBIX_CMD)
        if retcode != 0:
            raise MongoError("exec zabbix.sh fail")

    def tackle(self):
        self.logger.info("Start tackle")
        if self.has_ignore_agent():
            self.logger.info('skip tackle, ignore agent file exists')
            return
        if not os.path.isfile(self.CONF_PATH):
            self.logger.info('skip tackle, [%s] file not exists', self.CONF_PATH)
            return
        if not self.check_local_mongod():
            self.logger.info("mongod is fail,will revive mongod")
            self.start_local_mongod()
        if not self.check_zabbix_agent():
            self.logger.info("zabbix-agent is fail,will revive zabbix-agent")
            self.revive_zabbix()
        self.logger.info("Tackle End")

    def copy_log(self):
        files = filter(lambda file: "mongod.log" in file, os.listdir(self.DATA_PATH))
        self.logger.info("copy_log [%s]......", files)
        for log_file in files:
            dest_path = os.path.join(self.MONGOD_COPY_LOG_DIR, log_file)
            cmd = "cp %s %s && chmod 644 %s" % (self.DATA_PATH + log_file, dest_path, dest_path)
            exec_cmd(cmd)
        exec_cmd(self.START_CADDY_CMD)
        return 0

    def clean_log(self):
        files = filter(lambda file: "mongod.log" in file, os.listdir(self.DATA_PATH))
        self.logger.info("clean_log [%s]......", files)
        map(lambda file: exec_cmd(
            "echo > {}".format(self.DATA_PATH + file)) if self.DATA_PATH + file == self.MONGOD_LOG_PATH else os.remove(
            self.DATA_PATH + file), files)
        exec_cmd("rm -rf {}*".format(self.MONGOD_COPY_LOG_DIR))

        return 0

    def __getattribute__(self, func_name):
        if func_name in ('tackle', 'health_check', 'monitor'):
            self.logger.info('call func: [%s]...', func_name)
        return object.__getattribute__(self, func_name)


def main():
    if len(sys.argv) == 1:
        return help()

    cmd = sys.argv[1]
    mongo = Mongo()

    if cmd == 'init':
        return mongo.init()
    elif cmd == 'init_replication':
        return mongo.init_replication()
    elif cmd == 'gen_conf':
        return mongo.gen_conf()
    elif cmd == 'monitor':
        return mongo.monitor()
    elif cmd == 'health_check':
        return mongo.health_check()
    elif cmd == 'reconfig':
        return mongo.reconfig()
    elif cmd == 'tackle':
        return mongo.tackle()
    elif cmd == 'start_all':
        return mongo.start_all_mongod()
    elif cmd == 'stop_all':
        return mongo.stop_all_mongod()
    elif cmd == 'drop_all':
        return mongo.drop_all_users()
    elif cmd == 'cleanup_all':
        return mongo.cleanup_all_mongod()
    elif cmd == 'get_nodes_names':
        return mongo.get_nodes_names()
    elif cmd == 'get_node_details':
        return mongo.get_node_details()
    elif cmd == 'detect_host_changed':
        return mongo.detect_host_changed()
    elif cmd == "copy_log":
        return mongo.copy_log()
    elif cmd == 'clean_log':
        return mongo.clean_log()
    elif cmd == 'update_oplogsize':
        return mongo.update_oplogsize()
    elif cmd == 'print_connection_string':
        return mongo.print_connection_string()
    else:
        return help()


if __name__ == "__main__":
    main()
