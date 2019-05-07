#!/bin/bash
utilfqdn=`curl -L http://169.254.169.254/opc/v1/instance/metadata/ambari_server`

LOG_FILE="/var/log/hortonworks-OCI-initialize.log"

## logs everything to the $LOG_FILE
log() {
  echo "$(date) [${EXECNAME}]: $*" >> "${LOG_FILE}"
}

EXECNAME="Ambari Certificate"
mkdir -p /etc/ambari-server/certs
cd /etc/ambari-server/certs
log "->Generate & Deploy"
openssl genrsa -out ${utilfqdn}.key 2048
# This should be customized to your organization
openssl req -new -key ${utilfqdn}.key -out ${utilfqdn}.csr -subj "/C=US/ST=Washington/L=Seattle/O=OCI/OU=Hortonworks/CN=${utilfqdn}"
openssl x509 -req -days 365 -in ${utilfqdn}.csr -signkey ${utilfqdn}.key -out ${utilfqdn}.crt

EXECNAME="Ambari Server & Agent"
log "->Install"
# Ambari Agent Install
ambari_version="2.6.2.0"
wget -nv http://public-repo-1.hortonworks.com/ambari/centos7/2.x/updates/${ambari_version}/ambari.repo -O /etc/yum.repos.d/ambari.repo
yum install ambari-server ambari-agent -y
ambari-server setup -s
ambari-server setup-security --security-option=setup-https --api-ssl=true --api-ssl-port=8443 --import-cert-path=/etc/ambari-server/certs/${utilfqdn}.crt --import-key-path=/etc/ambari-server/certs/${utilfqdn}.key --pem-password=
service ambari-server start
wget -nv http://public-repo-1.hortonworks.com/HDP/centos7/2.x/updates/2.6.4.0/hdp.repo -O /etc/yum.repos.d/hdp.repo
wget -nv http://public-repo-1.hortonworks.com/HDP-UTILS-1.1.0.22/repos/centos7/hdp-utils.repo -O /etc/yum.repos.d/hdp-utils.repo

# Modify /etc/ambari-agent/conf/ambari-agent.ini
sed -i "s/localhost/${utilfqdn}/g" /etc/ambari-agent/conf/ambari-agent.ini
sed -i -e $'s/\[security\]/\[security\]\\nforce_https_protocol=PROTOCOL_TLSv1_2/g' /etc/ambari-agent/conf/ambari-agent.ini
log"->Startup"
service ambari-agent start

EXECNAME="TUNING"
log "->Start"
#
# HOST TUNINGS
# 

# Disable SELinux
sed -i.bak 's/SELINUX=enforcing/SELINUX=disabled/g' /etc/selinux/config
setenforce 0

EXECNAME="JAVA - KERBEROS"
log "->INSTALL"
## Install Java & Kerberos client
yum install java-1.8.0-openjdk.x86_64 krb5-workstation -y

## KERBEROS INSTALL
EXECNAME="KERBEROS"
log "-> INSTALL"

yum -y install krb5-server krb5-libs krb5-workstation
KERBEROS_PASSWORD="SOMEPASSWORD"
SCM_USER_PASSWORD="somepassword"
kdc_server=$(hostname)
kdc_fqdn=`host $kdc_server | gawk '{print $1}'`
realm="hadoop.com"
REALM="HADOOP.COM"
log "-> CONFIG"
rm -f /etc/krb5.conf
cat > /etc/krb5.conf << EOF
# Configuration snippets may be placed in this directory as well
includedir /etc/krb5.conf.d/

[libdefaults]
 default_realm = ${REALM}
 dns_lookup_realm = false
 dns_lookup_kdc = false
 rdns = false
 ticket_lifetime = 24h
 renew_lifetime = 7d  
 forwardable = true
 udp_preference_limit = 1000000
 default_tkt_enctypes = rc4-hmac 
 default_tgs_enctypes = rc4-hmac
 permitted_enctypes = rc4-hmac

[realms]
    ${REALM} = {
        kdc = ${kdc_fqdn}:88
        admin_server = ${kdc_fqdn}:749
        default_domain = ${realm}
    }

[domain_realm]
    .${realm} = ${REALM}
     ${realm} = ${REALM}

[kdc]
    profile = /var/kerberos/krb5kdc/kdc.conf

[logging]
    kdc = FILE:/var/log/krb5kdc.log
    admin_server = FILE:/var/log/kadmin.log
    default = FILE:/var/log/krb5lib.log
EOF


rm -f /var/kerberos/krb5kdc/kdc.conf
cat > /var/kerberos/krb5kdc/kdc.conf << EOF
default_realm = ${REALM}

[kdcdefaults]
    v4_mode = nopreauth
    kdc_ports = 0

[realms]
    ${REALM} = {
        kdc_ports = 88
        admin_keytab = /var/kerberos/krb5kdc/kadm5.keytab
        database_name = /var/kerberos/krb5kdc/principal
        acl_file = /var/kerberos/krb5kdc/kadm5.acl
        key_stash_file = /var/kerberos/krb5kdc/stash
        max_life = 10h 0m 0s
        max_renewable_life = 7d 0h 0m 0s
        master_key_type = des3-hmac-sha1
        supported_enctypes = rc4-hmac:normal 
        default_principal_flags = +preauth
    }
EOF

rm -f /var/kerberos/krb5kdc/kadm5.acl
cat > /var/kerberos/krb5kdc/kadm5.acl << EOF
*/admin@${REALM}    *
cloudera-scm@${REALM}   *
EOF

kdb5_util create -r ${REALM} -s -P ${KERBEROS_PASSWORD}

echo -e "addprinc root/admin\n${KERBEROS_PASSWORD}\n${KERBEROS_PASSWORD}\naddprinc cloudera-scm\n${SCM_USER_PASSWORD}\n${SCM_USER_PASSWORD}\nktadd -k /var/kerberos/krb5kdc/kadm5.keytab kadmin/admin\nktadd -k /var/kerberos/krb5kdc/kadm5.keytab kadmin/changepw\nexit\n" | kadmin.local -r ${REALM}
log "-> START"
systemctl start krb5kdc.service
systemctl start kadmin.service
systemctl enable krb5kdc.service
systemctl enable kadmin.service

EXECNAME="TUNING"
log "->OS"
## Disable Transparent Huge Pages
echo never | tee -a /sys/kernel/mm/transparent_hugepage/enabled
echo "echo never | tee -a /sys/kernel/mm/transparent_hugepage/enabled" | tee -a /etc/rc.local

## Set vm.swappiness to 1
echo vm.swappiness=0 | tee -a /etc/sysctl.conf
echo 0 | tee /proc/sys/vm/swappiness

## Tune system network performance
echo net.ipv4.tcp_timestamps=0 >> /etc/sysctl.conf
echo net.ipv4.tcp_sack=1 >> /etc/sysctl.conf
echo net.core.rmem_max=4194304 >> /etc/sysctl.conf
echo net.core.wmem_max=4194304 >> /etc/sysctl.conf
echo net.core.rmem_default=4194304 >> /etc/sysctl.conf
echo net.core.wmem_default=4194304 >> /etc/sysctl.conf
echo net.core.optmem_max=4194304 >> /etc/sysctl.conf
echo net.ipv4.tcp_rmem="4096 87380 4194304" >> /etc/sysctl.conf
echo net.ipv4.tcp_wmem="4096 65536 4194304" >> /etc/sysctl.conf
echo net.ipv4.tcp_low_latency=1 >> /etc/sysctl.conf

## Tune File System options
sed -i "s/defaults        1 1/defaults,noatime        0 0/" /etc/fstab

log "->SSH"
## Enable root login via SSH key
cp /root/.ssh/authorized_keys /root/.ssh/authorized_keys.bak
cp /home/opc/.ssh/authorized_keys /root/.ssh/authorized_keys

## Set Limits
echo "hdfs  -       nofile  32768
hdfs  -       nproc   2048
hbase -       nofile  32768
hbase -       nproc   2048" >> /etc/security/limits.conf
ulimit -n 262144

log "->FirewallD"
systemctl stop firewalld
systemctl disable firewalld

## Post Tuning Execution Below
EXECNAME="MYSQL Connector"
## MySQL Connector Install
log "->INSTALL"
wget https://dev.mysql.com/get/Downloads/Connector-J/mysql-connector-java-5.1.46.tar.gz
tar zxvf mysql-connector-java-5.1.46.tar.gz
mkdir -p /usr/share/java/
cd mysql-connector-java-5.1.46
cp mysql-connector-java-5.1.46-bin.jar /usr/share/java/mysql-connector-java.jar
ln -s /usr/share/java/mysql-connector-java.jar /var/lib/ambari-server/resources/mysql-connector-java.jar

#
# DISK SETUP
#

vol_match() {
case $i in
	1) disk="oraclevdb";;
	2) disk="oraclevdc";;
	3) disk="oraclevdd";;
	4) disk="oraclevde";;
	5) disk="oraclevdf";;
	6) disk="oraclevdg";;
	7) disk="oraclevdh";;
	8) disk="oraclevdi";;
	9) disk="oraclevdj";;
	10) disk="oraclevdk";;
	11) disk="oraclevdl";;
	12) disk="oraclevdm";;
	13) disk="oraclevdn";;
	14) disk="oraclevdo";;
	15) disk="oraclevdp";;
	16) disk="oraclevdq";;
	17) disk="oraclevdr";;
	18) disk="oraclevds";;
	19) disk="oraclevdt";;
	20) disk="oraclevdu";;
	21) disk="oraclevdv";;
	22) disk="oraclevdw";;
	23) disk="oraclevdx";;
	24) disk="oraclevdy";;
	25) disk="oraclevdz";;
	26) disk="oraclevdab";;
	27) disk="oraclevdac";;
	28) disk="oraclevdad";;
	29) disk="oraclevdae";;
	30) disk="oraclevdaf";;
	31) disk="oraclevdag";;
esac
}

iscsi_setup() {
        log "-> ISCSI Volume Setup - Volume ${i} : IQN ${iqn[$n]}"
        iscsiadm -m node -o new -T ${iqn[$n]} -p 169.254.2.${n}:3260
        log "--> Volume ${iqn[$n]} added"
        iscsiadm -m node -o update -T ${iqn[$n]} -n node.startup -v automatic
        log "--> Volume ${iqn[$n]} startup set"
        iscsiadm -m node -T ${iqn[$n]} -p 169.254.2.${n}:3260 -l
        log "--> Volume ${iqn[$n]} done"
}

iscsi_target_only(){
	log "-->Logging into Volume ${iqn[$n]}"
	su - opc -c "sudo iscsiadm -m node -T ${iqn[$n]} -p 169.254.2.${n}:3260 -l"
}

## Look for all ISCSI devices in sequence, finish on first failure
EXECNAME="ISCSI"
log "- Begin Block Volume Detection Loop -"
detection_flag="0"
while [ "$detection_flag" = "0" ]; do
	detection_done="0"
	log "-- Detecting Block Volumes --"
	for i in `seq 2 33`; do
		if [ $detection_done = "0" ]; then
			iscsiadm -m discoverydb -D -t sendtargets -p 169.254.2.$i:3260 2>&1 2>/dev/null
			iscsi_chk=`echo -e $?`
			if [ $iscsi_chk = "0" ]; then
				# IQN list is important set up this array with discovered IQNs
				iqn[${i}]=`iscsiadm -m discoverydb -D -t sendtargets -p 169.254.2.${i}:3260 | gawk '{print $2}'` 
				log "-> Discovered volume $((i-1)) - IQN: ${iqn[${i}]}"
				continue
			else
				volume_count="${#iqn[@]}"
				log "--> Discovery Complete - ${#iqn[@]} volumes found"
				detection_done="1"
			fi
		fi
	done;
	## Now let's do this again after a 30 second sleep to ensure consistency in case this ran in the middle of volume attachments
	sleep 30
	sanity_detection_done="0"
	sanity_volume_count="0"
	for i in `seq 2 33`; do
                if [ $sanity_detection_done = "0" ]; then
                        iscsiadm -m discoverydb -D -t sendtargets -p 169.254.2.$i:3260 2>&1 2>/dev/null
                        iscsi_chk=`echo -e $?`
                        if [ $iscsi_chk = "0" ]; then
                                # IQN list is important set up this array with discovered IQNs
                                siqn[${i}]=`iscsiadm -m discoverydb -D -t sendtargets -p 169.254.2.${i}:3260 | gawk '{print $2}'`
                                continue
                        else
                                sanity_volume_count="${#siqn[@]}"
                                log "--> Sanity Discovery Complete - ${#siqn[@]} volumes found"
                                sanity_detection_done="1"
                        fi
                fi
        done;
	if [ "$volume_count" = "0" ]; then
                if [ "$volume_count" = "$sanity_volume_count" ]; then
                        log "-- $volume_count Block Volumes found, done."
                        detection_flag="1"
                else
                        log "-- Sanity Check Failed - $sanity_volume_count Volumes found, $volume_count on first run.  Re-running --"
                        sleep 30
                        continue
                fi
	elif [ "$volume_count" != "$sanity_volume_count" ]; then
		log "-- Sanity Check Failed - $sanity_volume_count Volumes found, $volume_count on first run.  Re-running --"
		sleep 15
		continue
	elif [ "$volume_count" = "$sanity_volume_count" ]; then 
		log "-- Setup for ${#iqn[@]} Block Volumes --"
		for i in `seq 1 ${#iqn[@]}`; do
			n=$((i+1))
			iscsi_setup
		done;
		detection_flag="1"
	else
		log "-- Repeating Detection --"
		continue
	fi
done;

EXECNAME="boot.sh - DISK PROVISIONING"
## Primary Disk Mounting Function
data_mount () {
  log "-->Mounting /dev/$disk to /data$dcount"
  mkdir -p /data$dcount
  mount -o noatime,barrier=1 -t ext4 /dev/$disk /data$dcount
  UUID=`lsblk -no UUID /dev/$disk`
  echo "UUID=$UUID   /data$dcount    ext4   defaults,noatime,discard,barrier=0 0 1" | tee -a /etc/fstab
}

block_data_mount () {
  log "-->Mounting /dev/oracleoci/$disk to /data$dcount"
  mkdir -p /data$dcount
  mount -o noatime,barrier=1 -t ext4 /dev/oracleoci/$disk /data$dcount
  UUID=`lsblk -no UUID /dev/oracleoci/$disk`
  echo "UUID=$UUID   /data$dcount    ext4   defaults,_netdev,nofail,noatime,discard,barrier=0 0 2" | tee -a /etc/fstab
}

EXECNAME="DISK SETUP"
## Check for x>0 devices
log "->Checking for disks..."
nvcount="0"
bvcount="0"
## Execute - will format all devices except sda for use as data disks in HDFS
dcount=0
for disk in `ls /dev/ | grep nvme | grep n1`; do
	log "-->Processing /dev/$disk"
  	mke2fs -F -t ext4 -b 4096 -E lazy_itable_init=1 -O sparse_super,dir_index,extent,has_journal,uninit_bg -m1 /dev/$disk
    	data_mount
	dcount=$((dcount+1))
done;

if [ ${#iqn[@]} -gt 0 ]; then 
for i in `seq 1 ${#iqn[@]}`; do
	n=$((i+1))
	dsetup="0"
	while [ $dsetup = "0" ]; do
		vol_match
		log "-->Checking /dev/oracleoci/$disk"
		if [ -h /dev/oracleoci/$disk ]; then
			mke2fs -F -t ext4 -b 4096 -E lazy_itable_init=1 -O sparse_super,dir_index,extent,has_journal,uninit_bg -m1 /dev/oracleoci/$disk
			block_data_mount
                	dcount=$((dcount+1))
			/sbin/tune2fs -i0 -c0 /dev/oracleoci/$disk
			dsetup="1"
		else
			log "--->${disk} not found, running ISCSI again."
			iscsi_target_only
			sleep 5
		fi
	done;
done;
fi
EXECNAME="END"
log "->DONE"