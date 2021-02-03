#!/usr/bin/env python
# -*- coding: utf-8 -*-

import sys
sys.path.append("/opt/app/bin/")
from MongoTrib import *

class Fix(Mongo):
    def __init__(self):
        Mongo.__init__(self)
        self.replicaset_info = "/data/info/replicaSet.info"
        self.self_info = "/data/info/self.info"

    def get_node_info(self):
        self.self = os.path.exists(self.self_info)
        self.replica = os.path.exists(self.replicaset_info)
        if not self.self and not self.replica:
            print("Do not choice Switcher，Do not need to Fix")
            sys.exit(0)
        if not self.self and self.replica:
            print("The node is Switcher，Can not Fix")
            sys.exit(0)
        if self.self and not self.replica:
            print("The node is not Switcher, Switcher may occur err during the backup,Need to Fix")

        if self.self and self.replica:
            print("The node is not Switcher, Need to Fix")
        for x in range(5):
            answer = raw_input("Fix Y/N: ")
            if answer == "Y": return
            if answer == "N": sys.exit(0)
        print("Timeout!")

    def exec_is_master(self, db):
        output = db.command("isMaster", 1)
        print output
        return output
    
    def change_self_to_primary(self):
        members = self.get_members()  # 列表类型，已按照 sid 做好排序
        self_members = list(filter(lambda member: member['instance_id'] == self.HOSTNAME, members))
        conf = self.get_replica_conf(self_members)
        db = self.connect_local().admin
        is_master = self.exec_is_master(db)
        print(is_master)
        try:
            conf["version"] = is_master["setVersion"] + 1
        except Exception:
            conf["version"] = is_master["maxWireVersion"] + 1
        db.command('replSetReconfig', conf, force=True)
        
    def check_ismaster(self,ip=None):
        if not ip:
            db = self.connect_local().admin
        else:
            db = self.connect(host=ip).admin
        for x in range(5):
            if self.exec_is_master(db)["ismaster"]: break
            time.sleep(3)
    
    def fix_not_switcher_node(self):
        self.start_local_mongod()
        self.get_node_info()
        self.change_self_to_primary()
        self.check_ismaster()
        self.reconfig()
        print("Fix End, Flushall data in other node which is not healthy or engine is not same with primary")
        
if __name__ == '__main__':
    fix = Fix()
    fix.fix_not_switcher_node()