#!/usr/bin/env python
# -*- coding: utf-8 -*-
import commands
from MongoTrib import *


class UpgradeMongo(Mongo):
    MONGO_VERSION = [{"version": "3.2", "dir": "32", "last_dir": None}, {"version": "3.4", "dir": "34", "last_dir": 32},
                     {"version": "3.6", "dir": "36", "last_dir": 34}, {"version": "4.0", "dir": "", "last_dir": 36}]
    data_dir = "/data/mongodb/"

    replicaset_info_file = Mongo.INFO_DIR + "replicaSet.info"  # /data/info 需要创建
    upgrade_define_file = Mongo.INFO_DIR + "self.info"
    fix_file = "/opt/app/bin/Fix.py"
    not_del_files = ["mongo-trib.log", "version.info", "ip.info"]  # 非升级过程中产生的文件

    def __init__(self):
        Mongo.__init__(self)
        self.switcher_role = "SECONDARY"
        self.start_dir = 32
        self.cp = False
        self.switcher = None
        self.mkdir_info()

    def mkdir_info(self):
        if os.path.exists(self.INFO_DIR):
            self.logger.debug("before del{}".format(os.listdir(self.INFO_DIR)))
            # 防止版本回退，或者上次升级后，原有的存储信息会干扰升级
            list(map(lambda file: os.remove(self.INFO_DIR + file),
                     filter(lambda file: not (file in self.not_del_files or self.not_del_files[0] in file),
                            os.listdir(self.INFO_DIR))))
            self.logger.debug("after del {}".format(os.listdir(self.INFO_DIR)))
        else:
            cmd = "mkdir -p {info_dir}".format(
                info_dir=self.INFO_DIR)
            os.system(cmd)

    def gen_mmapv1_conf(self, auth=True, rs=True, key_file=True, port=None):
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
  path: "%(data_path)smongod.log" 
  logAppend: true 
storage:
  dbPath: "%(data_path)s"
  engine: mmapv1
  journal:
    enabled: true
  #wiredTiger:
    #engineConfig:
      #cacheSizeGB: %(cache_size).2f
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
            "data_path": self.DATA_PATH
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

    def start_local_mongod(self, dir):
        if dir == 40:
            self.gen_mmapv1_conf()
            self.change_conf_file_mtow()
        self.START_CMD = "/opt/app/bin/start-mongod-server.sh {}".format("" if dir == 40 else dir)
        ret_code, output = self.exec_cmd(self.START_CMD)
        if ret_code != 0 and ret_code != 48:
            raise MongoError('start mongod failed: [%s]' % output)

    def stop_local_mongod(self, dir):
        self.STOP_CMD = "/opt/app/bin/stop-mongod-server.sh {}".format("" if dir == 40 else dir)
        ret_code, output = self.exec_cmd(self.STOP_CMD)
        if ret_code != 0 and ret_code != 48:
            raise MongoError('start mongod failed: [%s]' % output)

    def del_data_dir(self):
        # 删除 mmap 引擎数据文件
        cmd = "rm -rf {}*".format(self.data_dir)
        code, output = commands.getstatusoutput(cmd)
        if code != 0:
            raise MongoError

    def change_conf_file_mtow(self):
        with self.open_conf() as f:
            content = f.read()
        content = content.replace("mmapv1", "wiredTiger")
        with self.open_conf(mode="w") as f:
            f.write(content)

    def wait_until_ok(self, db, nodes_count):
        """
        保证集群状态为 1个 master 其余全为 secondary
        :param db:
        :param nodes_count:
        :return:
        """
        for x in range(40):
            ret = db.command('replSetGetStatus', 1)
            active_nodes = list(map(lambda member: member["name"].split(":")[0],
                                    filter(lambda member: member["stateStr"].upper() in ["PRIMARY", "SECONDARY"],
                                           ret["members"])))
            primary_nodes = list(map(lambda member: member["name"].split(":")[0],
                                     filter(lambda member: member["stateStr"].upper() in ["PRIMARY"], ret["members"])))
            if len(active_nodes) == nodes_count and len(primary_nodes) == 1: return
            time.sleep(3)
        self.logger.info("replicSet status is not normal, will quit")
        raise MongoError("集群状态不正常，不允许升级")

    def define_switcher(self):
        """
        切换引擎的节点为 secondary 中的 sid 排行第一的节点
        :return:
        """
        members = self.get_members()
        db = self.connect_local().admin
        self.wait_until_ok(db, len(members))
        ret = db.command('replSetGetStatus', 1)
        secondary_mebers = list(map(lambda member: member["name"].split(":")[0],
                                    filter(lambda member: member["stateStr"].upper() == self.switcher_role,
                                           ret["members"])))
        for member in members:
            if member["ip"] in secondary_mebers: return member

    def cp_fix_script(self):
        cmd = "cp {} {}".format(self.fix_file, self.INFO_DIR)
        os.system(cmd)

    def rm_fix_script(self):
        cmd = "rm {}".format(self.INFO_DIR + "Fix.py")
        os.system(cmd)

    def save_switcher(self, ip=None, step=1):
        if step == 2:
            if os.path.exists(self.replicaset_info_file):
                with open(self.replicaset_info_file, "r+") as f:
                    content = f.read().strip()
                    content = content.replace("OK1", "OK2")
                    f.seek(0)
                    f.write(content)
                return
            else:
                raise MongoError("文件不存在")
        with open(self.replicaset_info_file, "w") as f:
            f.write(ip + "OK{}".format(step))

    def wait_until_file_exists(self, step=1):
        while True:
            if os.path.exists(self.replicaset_info_file):
                with open(self.replicaset_info_file, "r") as f:
                    content = f.read().strip()
                    if content[-3:] == "OK{}".format(step): return
            time.sleep(3)

    def sync_switcher(self, ip):
        members = self.get_members()
        for member in members:
            if ip != member["ip"]:

                cmd = "scp -q -o 'StrictHostKeyChecking no' -o 'UserKnownHostsFile /dev/null' \
-o ConnectTimeout=5 -o ConnectionAttempts=3 %s root@%s:%s" % (
                    self.replicaset_info_file, member["ip"], self.replicaset_info_file)
                ret_code, output = self.exec_cmd(cmd)
                if ret_code != 0:
                    raise MongoError('sync [%s] on [%s] failed: [%s]' % (self.replicaset_info_file, ip, output))

    def wait_until_backup_over(self):
        while True:
            try:
                result = self.define_switcher()
                c = self.connect_local()
                ret = c.admin.command('replSetGetStatus', 1)
            except Exception as e:
                self.logger.error("[wait_until_backup_over] occur {}".format(e))
                time.sleep(3)
                continue
            if list(filter(lambda member: member["name"].split(":")[0] == result["ip"], ret["members"]))[0][
                "stateStr"].upper() in ["SECONDARY", "PRIMARY"]: break
            time.sleep(3)

    def change_self_to_primary(self):
        members = self.get_members()  # 列表类型，已按照 sid 做好排序
        self_members = list(filter(lambda member: member['instance_id'] == self.HOSTNAME, members))
        conf = self.get_replica_conf(self_members)
        db = self.connect_local().admin
        is_master = self.exec_is_master(db)
        conf["version"] = is_master["setVersion"] + 1
        conf["protocolVersion"] = 1
        db.command('replSetReconfig', conf, force=True)

    def check_ismaster(self, ip=None):
        if not ip:
            db = self.connect_local().admin
        else:
            db = self.connect(host=ip).admin
        while True:
            if self.exec_is_master(db)["ismaster"]: break
            time.sleep(3)

    # 升级版本
    def change_mogod_instance(self, mongo_dir):
        start_cmd = "/opt/app/bin/start-mongod-server.sh {}".format(mongo_dir)
        ret_code, output = self.exec_cmd(start_cmd)
        if ret_code != 0:
            raise MongoError('stop mongod failed: [%s]' % output)

    def stop_last_mongod(self, mongo_dir):
        stop_cmd = "/opt/app/bin/stop-mongod-server.sh {}".format(mongo_dir)
        ret_code, output = self.exec_cmd(stop_cmd)
        if ret_code != 0:
            raise MongoError('stop mongod failed: [%s]' % output)

    def set_feature_compability_version(self, db, version):
        db.command({'setFeatureCompatibilityVersion': "{}".format(version)})

    def check_feature_compability_version_valid(self, db, version):
        """
        3.2  result = {u'ok': 1.0, u'featureCompatibilityVersion': u'3.2'}
        3.4  result = {u'ok': 1.0, u'featureCompatibilityVersion': {u'version': u'3.4'}}
        3.6  result = {u'$clusterTime': {u'clusterTime': Timestamp(1552643482, 7),
                                    u'signature': {u'keyId': 6668552977537564673L,
                                                   u'hash': Binary("/C,h'N\x91\xca9\xc4ji\x11AD\xce\xa3\xb6\xb5\xd7",
                                                                   0)}}, u'ok': 1.0,
                  u'featureCompatibilityVersion': {u'version': u'3.6'}, u'operationTime': Timestamp(1552643482, 7)}

        4.0  result = {
                            "featureCompatibilityVersion" : {
                                "version" : "4.0"
                            },
                            "ok" : 1,
                            "operationTime" : Timestamp(1552706524, 1),
                            "$clusterTime" : {
                                "clusterTime" : Timestamp(1552706524, 1),
                                "signature" : {
                                    "hash" : BinData(0,"n25Y1GHGvETYrR2fN2ZDXjkV84U="),
                                    "keyId" : NumberLong("6668552977537564673")
                                }
                            }
                        }

        :param db:
        :param version:
        :return:
        """
        result = db.command({'getParameter': 1, 'featureCompatibilityVersion': 1})
        if isinstance(result["featureCompatibilityVersion"], dict):
            return str(result["featureCompatibilityVersion"]["version"]) == version
        else:
            return str(result["featureCompatibilityVersion"]) == version

    def upgrade_MONGODBCR_to_SCRAM(self, db):
        output = db.command('authSchemaUpgrade', 1)
        self.logger.debug("[upgrade_MONGODBCR_to_SCRAM] output: {}".format(output))

    def annotation_cacheSize(self):
        """
        wiredTiger:
    engineConfig:
      cacheSizeGB: %(cache_size).2f
        :return:
        """
        with self.open_conf(mode="r") as f:
            content = f.read()
        content = content.replace("wiredTiger:", "# wiredTiger:")
        content = content.replace("engineConfig", "# engineConfig")
        content = content.replace("cacheSizeGB", "# cacheSizeGB")

        with self.open_conf(mode="w") as f:
            f.write(content)

    def exec_is_master(self, db):
        output = db.command("isMaster", 1)
        return output

    def merge_nodes(self):
        members = self.get_members()  # 列表类型，已按照 sid 做好排序
        db = self.connect_local().admin
        is_master = self.exec_is_master(db)
        if is_master["ismaster"]:
            conf = self.get_replica_conf(members)
            conf["version"] = is_master["setVersion"] + 1
            conf["protocolVersion"] = 1
            db.command('replSetReconfig', conf, force=False)

    def member_to_standalone(self, protocol=False):
        """
        ret = {u'me': u'192.168.0.9:27017', u'ismaster': True, u'maxWriteBatchSize': 1000, u'ok': 1.0,
               u'setName': u'foobar', u'tags': {u'qc_node_id': u'cln-3rh8tzjl', u'qc_sid': u'1'}, u'maxWireVersion': 4,
               u'primary': u'192.168.0.9:27017',
               u'hosts': [u'192.168.0.9:27017', u'192.168.0.6:27017', u'192.168.0.11:27017'],
               u'maxMessageSizeBytes': 48000000, u'localTime': datetime.datetime(2019, 3, 17, 10, 3, 10, 30000),
               u'minWireVersion': 0, u'electionId': ObjectId('7fffffff0000000000000002'),
               u'maxBsonObjectSize': 16777216, u'setVersion': 1, u'secondary': False}
        :return:
        """
        members = self.get_members()  # 列表类型，已按照 sid 做好排序
        self_members = list(filter(lambda member: member['instance_id'] == self.HOSTNAME, members))
        db = self.connect_local().admin
        for x in range(4):
            try:
                is_master = self.exec_is_master(db)
                if is_master["primary"].split(":")[0] == self_members[0]["ip"] and is_master["ismaster"]: break
            except Exception, e:
                pass
                self.logger.error("Get ismaster for {} times,occur erro: {}".format(x, e))
            time.sleep(2)
        if is_master["ismaster"]:
            conf = self.get_replica_conf(self_members)
            conf["version"] = is_master["setVersion"] + 1
            if protocol:
                conf["protocolVersion"] = 1
            db.command('replSetReconfig', conf, force=False)
            if not protocol:
                map(lambda x: self.upgrade(last_dir=x["last_dir"], mongo_version=x["version"], mongo_dir=x["dir"]),
                    self.MONGO_VERSION)

    def upgrade(self, last_dir, mongo_version, mongo_dir):
        self.logger.info(mongo_version)
        if mongo_version != "3.2":
            self.stop_last_mongod(last_dir)

        self.change_mogod_instance(mongo_dir)
        db = self.connect_primary().admin

        if mongo_version == "3.6":
            self.upgrade_MONGODBCR_to_SCRAM(db)
        if mongo_version != "3.2":
            if not self.check_feature_compability_version_valid(db, version=mongo_version):
                self.set_feature_compability_version(db, version=mongo_version)

    def save_to_switcher(self, step):
        members = self.get_members()
        self_members = list(filter(lambda member: member['instance_id'] == self.HOSTNAME, members))
        with open(self.upgrade_define_file, "w") as f:
            f.write("STEP{}OK".format(step))
        try:
            with open(self.replicaset_info_file, "r") as f:
                ip = f.read().strip()[:-3]
        except Exception, e:
            ip = self.define_switcher()["ip"]
        self.logger.info("Switcher ip is {}".format(ip))
        cmd = "scp -q -o 'StrictHostKeyChecking no' -o 'UserKnownHostsFile /dev/null' \
-o ConnectTimeout=5 -o ConnectionAttempts=3 %s root@%s:%s%s" % (
            self.upgrade_define_file, ip, self.INFO_DIR, self_members[0]["ip"])
        self.logger.debug("scp cmd: {}".format(cmd))
        retcode, output = self.exec_cmd(cmd)
        if retcode != 0:
            raise MongoError

    def wait_until_to_ok(self, step):
        members = self.get_members()  # 列表类型，已按照 sid 做好排序
        other_members = list(filter(lambda member: member['instance_id'] != self.HOSTNAME, members))
        result = {}
        while True:
            for member in other_members:
                if os.path.exists(self.INFO_DIR + member["ip"]):
                    self.logger.info(self.INFO_DIR + member["ip"] + "exists")
                    with open(self.INFO_DIR + member["ip"], "r") as f:
                        content = f.read().strip()
                        self.logger.info(content)
                        result[member["ip"]] = content == "STEP{}OK".format(step)
            if False not in result.values() and len(result) == len(members) - 1: break
            time.sleep(3)

    def get_mongo_version(self):
        # 数据格式 {"version":4.0,"engine":"WiredTiger"}
        if os.path.exists(self.MONGO_VERSION_FILE):
            with open(self.MONGO_VERSION_FILE, "r") as f:
                content = json.loads(f.read().strip())
                return content
        if os.path.exists(self.MONGOD_COPY_LOG_DIR):
            return {"version": "4.0", "engine": "WiredTiger"}

        return {"version": "3.4", "engine": "wiredTiger"} if "WiredTiger" in os.listdir(self.data_dir) else {
            "version": "3.0", "engine": "mmapv1"}

    def get_nodes_nums(self):
        return len(self.get_members())

    def upgrade_engine_or_backup(self):

        self.switcher = self.define_switcher()
        if self.switcher["instance_id"] == self.HOSTNAME:
            self.wait_until_to_ok(1)
            self.logger.info("All nodes have completed define switcher")
            self.save_switcher(self.switcher["ip"])
            self.stop_local_mongod(dir=self.start_dir)
            if self.start_dir == 32:
                self.change_conf_file_mtow()
                self.del_data_dir()
            self.start_local_mongod(dir=self.start_dir)
            self.wait_until_backup_over()
            self.logger.info("Data have been backup")
            self.sync_switcher(self.switcher["ip"])
            self.logger.info("Have sync switcher info to other nodes")
            self.change_self_to_primary()
            self.logger.info("My status is PRIMARY now")
        else:
            self.save_to_switcher(1)
            self.wait_until_file_exists()
            self.logger.info("Get message：Switcher backup end")
            self.stop_local_mongod(dir=32)
            self.logger.debug("Stop mongod Service")
            self.wait_until_file_exists(step=2)
            self.logger.info("Get message: Switcher upgrade to 4.0.3，confirm it")
            self.check_ismaster(ip=self.switcher["ip"])
            self.logger.info("Confirm Nice")
            self.gen_conf()
            self.logger.info("Change mmapv1 to wiredTiger End")
            self.del_data_dir()
            self.logger.info("Del data completed End")
            self.start_local_mongod(dir=40)
            self.logger.info("Upgrade myself to 4.0 End")
            self.save_to_switcher(step=2)
            self.logger.info("Sync result to Switcher")
            self.save_version()
            self.rm_fix_script()
            self.logger.info("Fix script have remove from /data")
            sys.exit(0)

    def upgrade_version(self, is_one_node=False):
        self.member_to_standalone()
        self.member_to_standalone(protocol=True)
        self.logger.info("Upgrade myself to 4.0, Will merge nodes")
        if not is_one_node:
            self.stop_local_mongod(dir=40)
            self.gen_conf()
            self.start_local_mongod(dir=40)
            self.logger.info("Restart End")
            self.save_switcher(step=2)
            self.sync_switcher(self.switcher["ip"])
            self.wait_until_to_ok(2)
        self.merge_nodes()

    def main(self):
        self.cp_fix_script()
        self.logger.info("Fix script have copy to /data")
        nodes_nums = self.get_nodes_nums()
        is_one_node = nodes_nums == 1
        mongo_version = self.get_mongo_version()
        self.annotation_cacheSize()
        self.logger.info(json.dumps(mongo_version))
        if mongo_version.get("version") != "4.0":
            if mongo_version["version"] == "3.0":
                if is_one_node:
                    sys.exit(250)
                self.gen_mmapv1_conf()
                self.logger.info("Start with mongo32")
                self.start_local_mongod(dir=32)
            else:
                self.switcher_role = "PRIMARY"
                self.MONGO_VERSION = [{"version": "3.6", "dir": "36", "last_dir": 34},
                                      {"version": "4.0", "dir": "", "last_dir": 36}]
                self.logger.info("Start with mongo34")
                self.start_local_mongod(dir=34)
                self.start_dir = 34
                self.switcher_role = "PRIMARY"
            self.logger.info("Will define switcher")
            self.upgrade_engine_or_backup()
            self.upgrade_version(is_one_node=is_one_node)
        self.save_version()
        self.rm_fix_script()
        self.logger.info("Fix script have remove from /data")


if __name__ == '__main__':
    cmd = None
    try:
        cmd = sys.argv[1]
    except Exception:
        pass
    upgrader = UpgradeMongo()
    if cmd == "gen_m_conf":
        upgrader.gen_mmapv1_conf()
    elif cmd == "gen_w_conf":
        upgrader.gen_mmapv1_conf()
        upgrader.change_conf_file_mtow()
    else:
        upgrader.main()
