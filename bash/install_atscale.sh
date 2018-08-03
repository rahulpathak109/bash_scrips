#!/usr/bin/env bash
usage() {
    cat << END
A sample bash script for setting up and installing atscale
Tested on CentOS6|CentOS7 against hadoop clusters (HDP)

Download: curl -o /var/tmp/share/atscale/install_atscale.sh https://raw.githubusercontent.com/hajimeo/samples/master/bash/install_atscale.sh

To see help message of a function:
   $0 -h <function_name>

END
    # My NOTE:
    # Restore dir when install failed in the middle of installation:
    #   rmdir /usr/local/atscale && mv /usr/local/atscale_${_ATSCALE_VER}.*_$(date +"%Y%m%d")* /usr/local/atscale
}


### Global variables #################
[ -z "${_HDFS_USER}" ] && _HDFS_USER="hdfs"
[ -z "${_KADMIN_USR}" ] && _KADMIN_USR="admin/admin"
[ -z "${_KADMIN_PWD}" ] && _KADMIN_PWD="hadoop"
[ -z "${_ATSCALE_DIR}" ] && _ATSCALE_DIR="/usr/local/atscale"
[ -z "${_TMP_DIR}" ] && _TMP_DIR="/var/tmp/share/atscale"
[ -z "${_OS_ARCH}" ] && _OS_ARCH="el6.x86_64"
[ -z "${_SCHEMA_AND_HDFSDIR}" ] && _SCHEMA_AND_HDFSDIR="atscale"

### Arguments ########################
_ATSCALE_USER="${1:-atscale}"
_ATSCALE_LICENSE="${2:-${_TMP_DIR}/dev-vm-license-atscale.json}"
_ATSCALE_VER="${5:-7.0.0}"
_ATSCALE_CUSTOMYAML="${4}"
_UPGRADING="${5}"


### Functions ########################
function f_setup() {
    local __doc__="Setup OS and hadoop to install AtScale (eg: create a user)"
    # f_setup atscale /usr/local/atscale /var/tmp/share/atscale atscale$$
    local _atscale_user="${1:-${_ATSCALE_USER}}"
    local _atscale_dir="${2:-${_ATSCALE_DIR}}"
    local _tmp_dir="${3:-${_TMP_DIR}}"
    local _schema="${4:-${_SCHEMA_AND_HDFSDIR}}"
    local _kadmin_usr="${5:-${_KADMIN_USR}}"
    local _kadmin_pwd="${6:-${_KADMIN_PWD}}"

    local _hdfs_user="${_HDFS_USER:-hdfs}"

    if [ ! -d "${_tmp_dir}" ]; then
        echo "WARN: ${_tmp_dir} does not exist. Try creating it..."; sleep 5
        mkdir -m 777 -p ${_tmp_dir} || return $?
    fi
    chmod 777 ${_tmp_dir}

    echo "TODO: Please run 'adduser ${_atscale_user}' on other hadoop nodes" >&2; sleep 3
    adduser ${_atscale_user}
    usermod -a -G hadoop ${_atscale_user}
    su - ${_atscale_user} -c 'grep -q '${_atscale_dir%/}' $HOME/.bash_profile || echo "export PATH=${PATH%:}:'${_atscale_dir%/}'/bin" >> $HOME/.bash_profile'

    if [ ! -d "${_atscale_dir}" ]; then
        mkdir -p "${_atscale_dir}" || return $?
        chown ${_atscale_user}: "${_atscale_dir}" || return $?
    fi

    yum install -e 0 -y bzip2 bzip2-libs curl rsync unzip || return $?

    # If looks like Kerberos is enabled
    grep -A 1 'hadoop.security.authentication' /etc/hadoop/conf/core-site.xml | grep -qw "kerberos"
    if [ "$?" -eq "0" ]; then
        echo "INFO: Creating principals and keytabs (TODO: only for MIT KDC)..." >&2; sleep 1
        if [ ! -s /etc/security/keytabs/${_atscale_user}.service.keytab ]; then
            if [ -z "${_kadmin_usr}" ]; then
                echo "WARN: _kadmin_usr is not set, so that not creating ${_atscale_user} principal." >&2 sleep 7
            else
                if which ipa &>/dev/null; then
                    echo "INFO: (TODO) if FreeIPA is used, please create SPN: ${_atscale_user}/`hostname -f` from your FreeIPA GUI and export keytab." >&2; sleep 5
                    #echo -n "${_kadmin_pwd}" | kinit ${_kadmin_usr}
                    #ipa service-add ${_atscale_user}/`hostname -f`
                    #ipa-getkeytab -s freeipa.server.com -p ${_atscale_user}/`hostname -f` -k /etc/security/keytabs/${_atscale_user}.service.keytab
                else
                    kadmin -p ${_kadmin_usr} -w ${_kadmin_pwd} -q "add_principal -randkey ${_atscale_user}/`hostname -f`" && \
                    kadmin -p ${_kadmin_usr} -w ${_kadmin_pwd} -q "xst -k /etc/security/keytabs/${_atscale_user}.service.keytab ${_atscale_user}/`hostname -f`"
                fi
                chown ${_atscale_user}: /etc/security/keytabs/${_atscale_user}.service.keytab
                chmod 640 /etc/security/keytabs/${_atscale_user}.service.keytab
            fi
        fi

        local _hdfs_principal="`klist -k /etc/security/keytabs/hdfs.headless.keytab | grep -oE -m1 'hdfs-.+$'`"
        sudo -u ${_hdfs_user} kinit -kt /etc/security/keytabs/hdfs.headless.keytab ${_hdfs_principal}
    fi

    sudo -u ${_hdfs_user} hdfs dfs -mkdir /user/${_atscale_user}
    sudo -u ${_hdfs_user} hdfs dfs -chown ${_atscale_user}: /user/${_atscale_user}

    if which hive &>/dev/null; then
        if [ -s /etc/security/keytabs/${_atscale_user}.service.keytab ]; then
            local _atscale_principal="`klist -k /etc/security/keytabs/${_atscale_user}.service.keytab | grep -oE -m1 "${_atscale_user}/$(hostname -f)@.+$"`"
            sudo -u ${_atscale_user} kinit -kt /etc/security/keytabs/${_atscale_user}.service.keytab ${_atscale_principal}
        fi
        # TODO: should use beeline and tez, also if new installation, should drop database
        sudo -u ${_atscale_user} hive -hiveconf hive.execution.engine='mr' -e "CREATE DATABASE IF NOT EXISTS ${_schema}" &
    fi

    # Optionals. Not important
    if [ -d /var/www/html ] && [ ! -e /var/www/html/atscale ]; then
        ln -s ${_TMP_DIR%/} /var/www/html/atscale
    fi
    if [ ! -e /var/log/atscale ]; then
        ln -s ${_atscale_dir%/}/log /var/log/atscale
    fi
}

function f_generate_custom_yaml() {
    local __doc__="Generate custom yaml"
    local _license_file="${1:-${_ATSCALE_LICENSE}}"
    local _usr="${2:-${_ATSCALE_USER}}"
    local _schema_and_hdfsdir="${3:-${_SCHEMA_AND_HDFSDIR}}"

    # TODO: currently only for HDP
    local _tmp_yaml=/tmp/custom_hdp.yaml
    curl -s -o ${_tmp_yaml} "https://raw.githubusercontent.com/hajimeo/samples/master/misc/custom_hdp.yaml" || return $?

    # expected variables
    local _atscale_host="`hostname -f`" || return $?
    [ -s "${_license_file}" ] || return 11
    local _default_schema="${_schema_and_hdfsdir}"
    local _hdfs_root_dir="/user/${_usr}/${_schema_and_hdfsdir}"
    local _hdp_version="`hdp-select versions | tail -n 1`" || return $?
    local _hdp_major_version="`echo ${_hdp_version} | grep -oP '^\d\.\d+'`" || return $?
    #/usr/hdp/%hdp_version%/hadoop/conf:/usr/hdp/%hdp_version%/hadoop/lib/*:/usr/hdp/%hdp_version%/hadoop/.//*:/usr/hdp/%hdp_version%/hadoop-hdfs/./:/usr/hdp/%hdp_version%/hadoop-hdfs/lib/*:/usr/hdp/%hdp_version%/hadoop-hdfs/.//*:/usr/hdp/%hdp_version%/hadoop-yarn/lib/*:/usr/hdp/%hdp_version%/hadoop-yarn/.//*:/usr/hdp/%hdp_version%/hadoop-mapreduce/lib/*:/usr/hdp/%hdp_version%/hadoop-mapreduce/.//*::mysql-connector-java.jar:/usr/hdp/%hdp_version%/tez/*:/usr/hdp/%hdp_version%/tez/lib/*:/usr/hdp/%hdp_version%/tez/conf
    local _hadoop_classpath="`hadoop classpath`" || return $?

    # Kerberos related: TODO: at this moment, deciding by below atscale keytab file
    local _is_kerberized="false"
    local _delegated_auth_enabled="false"
    local _realm="EXAMPLE.COM"
    local _hdfs_principal="hdfs"
    local _hive_metastore_database="false"
    if [ -s /etc/security/keytabs/atscale.service.keytab ]; then
        _is_kerberized="true"
        _delegated_auth_enabled="true"
        _as_hive_metastore_database="true"  # Using remote metastore causes Kerberos issues
        _realm=`sudo -u ${_usr} klist -kt /etc/security/keytabs/atscale.service.keytab | grep -m1 -oP '@.+' | sed 's/@//'` || return $?
        # TODO: expecting this node has hdfs headless keytab (it should though)
        _hdfs_principal=`klist -kt /etc/security/keytabs/hdfs.headless.keytab | grep -m1 -oP 'hdfs-.+@' | sed 's/@//'` || return $?
    fi

    for _v in atscale_host license_file default_schema hdfs_root_dir hdp_version hdp_major_version hadoop_classpath is_kerberized delegated_auth_enabled hive_metastore_database realm hdfs_principal; do
        local _v2="_"${_v}
        # TODO: some variable contains "/" so at this moment using "@" but not perfect
        sed -i "s@%${_v}%@${!_v2}@g" $_tmp_yaml || return $?
    done

    if [ -n "${_usr}" ]; then
        if [ -f /home/${_usr%/}/custom.yaml ] && [ ! -s /home/${_usr%/}/custom_$$.yaml ]; then
            mv /home/${_usr%/}/custom.yaml /home/${_usr%/}/custom_$$.yaml || return $?
        fi
        # CentOS seems to have an alias "cp -i"
        /usr/bin/cp -f ${_tmp_yaml} /home/${_usr%/}/custom.yaml && chown ${_usr}: /home/${_usr%/}/custom.yaml
    fi
}

function f_backup_atscale() {
    local __doc__="Backup (or move if new installation) atscale directory, and execute pg_dump for DB backup"
    local _dir="${1:-${_ATSCALE_DIR}}"
    local _usr="${2:-${_ATSCALE_USER}}"
    local _is_upgrading="${3-${_UPGRADING}}"

    [ -d ${_dir%/} ] || return    # No dir, no backup

    local _installed_ver="$(sed -n -e 's/^as_version: \([0-9.]\+\).*/\1/p' "`ls -t ${_dir%/}/conf/versions/versions.*.yml | head -n1`")"
    [ -z "${_installed_ver}" ] && _installed_ver="unknown"
    local _suffix=${_installed_ver}_$(date +"%Y%m%d")_$$
    if [ ! -s "${_TMP_DIR%/}/atscale_${_suffix}.sql.gz" ]; then
        sudo -u ${_usr} "${_dir%/}/bin/atscale_service_control start postgres"; sleep 5
        f_pg_dump "${_dir%/}/share/postgresql-9.*/" "${_TMP_DIR%/}/atscale_${_suffix}.sql.gz"
        if [ ! -s "${_TMP_DIR%/}/atscale_${_suffix}.sql.gz" ]; then
            echo "WARN: Failed to take DB dump into ${_TMP_DIR%/}/atscale_${_suffix}.sql.gz. Maybe PostgreSQL is stopped?" >&2; sleep 3
        fi
    fi

    echo "INFO: Stopping AtScale before backing up..." >&2; sleep 3
    sudo -u ${_usr} ${_dir%/}/bin/atscale_service_control stop all
    if [[ "${_is_upgrading}" =~ (^y|^Y) ]]; then
        tar -czf ${_TMP_DIR%/}/atscale_${_suffix}.tar.gz ${_dir%/} || return $? # Not using -h or -v for now
    else
        mv ${_dir%/} ${_dir%/}_${_suffix} || return $?
        mkdir ${_dir%/} || return $?
        chown ${_usr}: ${_dir%/} || return $?
    fi
    ls -ltrd ${_dir%/}* # Just displaying directories to remind to delete later.
}

function f_pg_dump() {
    local __doc__="Execute atscale's pg_dump to backup PostgreSQL 'atscale' database"
    local _pg_dir="${1:-${_ATSCALE_DIR%/}/share/postgresql-9.*/}"
    local _dump_dest_filename="${2:-./atscale_$(date +"%Y%m%d%H%M%S").sql.gz}"
    local _lib_path="$(ls -1dtr ${_pg_dir%/}/lib | head -n1)"

    LD_LIBRARY_PATH=${_lib_path} PGPASSWORD=${PGPASSWORD:-atscale} ${_pg_dir%/}/bin/pg_dump -h localhost -p 10520 -d atscale -U atscale -Z 9 -f ${_dump_dest_filename} &
    trap 'kill %1' SIGINT
    echo "INFO: Executing pg_dump. Ctrl+c to skip 'pg_dump' command"; wait
    trap - SIGINT
}

function f_install_atscale() {
    local __doc__="Install AtScale software"
    local _version="${1:-${_ATSCALE_VER}}"
    local _license="${2:-${_ATSCALE_LICENSE}}"
    local _dir="${3:-${_ATSCALE_DIR}}"
    local _usr="${4:-${_ATSCALE_USER}}"
    local _custom_yaml="${5:-${_ATSCALE_CUSTOMYAML}}"
    local _installer_parent_dir="${6:-/home/${_usr}}"

    # It should be created by f_setup when user is created, so exiting.
    [ -d "${_installer_parent_dir}" ] || return $?

    # If it looks like one installed already, trying to take a backup
    if [ -s "${_dir%/}/bin/atscale_service_control" ]; then
        echo "INFO: Looks like another AtScale is already installed in ${_dir%/}/. Taking backup..." >&2; sleep 3
        if ! f_backup_atscale; then     # backup should stop AtScale
            echo "ERROR: Backup failed!!!" >&2; sleep 5
            return 1
        fi

        if [[ "${_UPGRADING}}" =~ (^y|^Y) ]]; then
            # If upgrading, making sure necessary services are started
            sudo -u ${_usr} "${_dir%/}/bin/atscale_service_control start postgres repmgrd haproxy xinetd"
        fi
    fi

    # NOTE: From here, all commands should be run as atscale user.
    if [ ! -d ${_installer_parent_dir%/}/atscale-${_version}.*-${_OS_ARCH} ]; then
        if [ ! -r "${_TMP_DIR%/}/atscale-${_version}.latest-${_OS_ARCH}.tar.gz" ]; then
            echo "INFO: No ${_TMP_DIR%/}/atscale-${_version}.latest-${_OS_ARCH}.tar.gz. Downloading from internet..." >&2; sleep 3
            sudo -u ${_usr} curl --retry 100 -C - -o ${_TMP_DIR%/}/atscale-${_version}.latest-${_OS_ARCH}.tar.gz "https://s3-us-west-1.amazonaws.com/files.atscale.com/installer/package/atscale-${_version}.latest-${_OS_ARCH}.tar.gz" || return $?
        fi

        sudo -u ${_usr} tar -xf ${_TMP_DIR%/}/atscale-${_version}.latest-${_OS_ARCH}.tar.gz -C ${_installer_parent_dir%/}/ || return $?
    fi

    if [ -s "${_custom_yaml}" ]; then
        echo "INFO: Copying ${_custom_yaml} to ${_installer_parent_dir%/}/custom.yaml..." >&2; sleep 3
        [ -f ${_installer_parent_dir%/}/custom.yaml ] && mv -f ${_installer_parent_dir%/}/custom.yaml ${_installer_parent_dir%/}/custom.yaml.$$.bak
        cp -f "${_custom_yaml}" ${_installer_parent_dir%/}/custom.yaml || return $?
    elif [ ! -s ${_installer_parent_dir%/}/custom.yaml ]; then
        if [[ "${_UPGRADING}}" =~ (^y|^Y) ]]; then
            echo "ERROR: Upgrading is specified but no custom.yaml file!!!" >&2; sleep 5
            return 1
        fi

        echo "INFO: As no custom.yaml given, generating..." >&2; sleep 3
        f_generate_custom_yaml || return $?
    else
        echo "INFO: Using existing ${_installer_parent_dir%/}/custom.yaml. For clean installation, remove this file." >&2; sleep 3
    fi

    # installer needs to be run from this dir
    cd ${_installer_parent_dir%/}/atscale-${_version}.*-${_OS_ARCH}/ || return $?
    echo "INFO: executing 'sudo -u ${_usr} ./bin/install -l ${_license}'" >&2
    sudo -u ${_usr} ./bin/install -l ${_license}
    cd -

    if [ -x "${_dir%/}/bin/atscale_start" ]; then
        grep -q 'atscale_start' /etc/rc.local || echo -e "\nsudo -u ${_usr} ${_dir%/}/bin/atscale_start" >> /etc/rc.local
    fi
}

function f_after_install_hack() {
    local __doc__="Normal installation does not work well with HDP, so need to change a few"
    local _dir="${1:-${_ATSCALE_DIR}}"
    local _db_pwd="${2:-hadoop}"
    local _usr="${3:-${_ATSCALE_USER}}"

    # TODO: I think below is needed if kerberos
    #${_dir%/}/apps/engine/bin/engine_wrapper.sh
    #export AS_ENGINE_EXTRA_CLASSPATH="config.ini:/etc/hadoop/conf/"

    grep -q "javax.jdo.option.ConnectionPassword" ${_dir%/}/share/apache-hive-*/conf/hive-site.xml || sed -i.$$.bak '/<\/configuration>/i \
<property><name>javax.jdo.option.ConnectionPassword</name><value>'${_db_pwd}'</value></property>' ${_dir%/}/share/apache-hive-*/conf/hive-site.xml

    grep -q "javax.jdo.option.ConnectionPassword" ${_dir%/}/share/spark-apache2_*/conf/hive-site.xml || sed -i.$$.bak '/<\/configuration>/i \
<property><name>javax.jdo.option.ConnectionPassword</name><value>'${_db_pwd}'</value></property>' ${_dir%/}/share/spark-apache2_*/conf/hive-site.xml

    # TODO: still doesn't work. probably atscale doesn't use ATS?
    #local _ambari="`sed -nr 's/^hostname ?= ?([^ ]+)/\1/p' /etc/ambari-agent/conf/ambari-agent.ini`"
    #grep -q "tez.tez-ui.history-url.base" ${_dir%/}/share/apache-tez-*/conf/tez-site.xml || sed -i.$$.bak '/<\/configuration>/i \
#<property><name>tez.tez-ui.history-url.base</name><value>http://'${_ambari}':8080/#/main/view/TEZ/tez_cluster_instance</value></property>' ${_dir%/}/share/apache-tez-*/conf/tez-site.xml

    sudo -u ${_usr} ${_dir%/}/bin/atscale_service_control restart atscale-hiveserver2 atscale-spark
}

function f_dataloader() {
    local __doc__="TODO: run dataloader-cli. Need env UUID"
    local _envId="${1:-prod}"
    [ -e ${_ATSCALE_DIR%/}/bin/dataloader ] || return $?
    # Just pincking the smallest (no special reason).
    local _archive="`ls -1Sr ${_ATSCALE_DIR%/}/data/*.zip | head -n1`"
    sudo -u ${_ATSCALE_USER} ${_ATSCALE_DIR%/}/bin/dataloader installarchive -env ${_envId} -archive=${_archive}
}

function f_ldap_cert_setup() {
    local __doc__="If LDAPS is available, import the LDAP/AD certificate into a trust store"
    local _ldap_host="${1:-$(hostname -f)}"
    local _ldap_port="${2:-636}" # or 389
    local _java_home="${3:-$(ls -1d ${_ATSCALE_DIR%/}/share/jdk*)}"
    local _truststore="${4:-${_java_home%/}/jre/lib/security/cacerts}"
    local _storepass="${5:-changeit}"

    echo -n | openssl s_client -connect ${_ldap_host}:${_ldap_port} -showcerts 2>&1 | sed -ne '/-BEGIN CERTIFICATE-/,/-END CERTIFICATE-/p' > ${_TMP_DIR%/}/${_ldap_host}_${_ldap_port}.crt
    if [ ! -s "${_TMP_DIR%/}/${_ldap_host}_${_ldap_port}.crt" ]; then
        echo "WARN: Certificate is NOT available on ${_ldap_host}:${_ldap_port}" >&2; sleep 3
        return 1
    fi
    ${_java_home%/}/bin/keytool -import -trustcacerts -file "${_TMP_DIR%/}/${_ldap_host}_${_ldap_port}.crt" -alias "${_ldap_host}" -keystore "${_truststore}" -noprompt -storepass "${_storepass}" || return $?
    echo "INFO: You need to restart AtScale to use the updated truststore." >&2; sleep 1
}

function f_export_key() {
    local __doc__="Export private key from keystore"
    local _keystore="${1}"
    local _in_pass="${2}"
    local _alias="${3}"

    local _tmp_keystore="`basename "${_keystore}"`.tmp.jks"
    local _certs_dir="`dirname "${_keystore}"`"
    [ -z "${_alias}" ] &&  _alias="`hostname -f`"
    local _private_key="${_certs_dir%/}/${_alias}.key"

    keytool -importkeystore -noprompt -srckeystore ${_keystore} -srcstorepass "${_in_pass}" -srcalias ${_alias} \
     -destkeystore ${_tmp_keystore} -deststoretype PKCS12 -deststorepass ${_in_pass} -destkeypass ${_in_pass} || return $?
    openssl pkcs12 -in ${_tmp_keystore} -passin "pass:${_in_pass}" -nodes -nocerts -out ${_private_key} || return $?
    chmod 640  ${_private_key} && chown root:hadoop ${_private_key}
    rm -f ${_tmp_keystore}

    if [ -s "${_certs_dir%/}/${_alias}.crt" ] && [ -s "${_private_key}" ]; then
        cat "${_certs_dir%/}/${_alias}.crt" ${_private_key} > "${_certs_dir%/}/certificate.pem"
        chmod 640 "${_certs_dir%/}/certificate.pem"
        chown root:hadoop "${_certs_dir%/}/certificate.pem"
    fi
}

function f_ha_with_tls_setup() {
    local __doc__="Setup (outside) HAProxy for Atscale HA"
    local _certificate="${1:-/etc/security/serverKeys/certificate.pem}" # Result of f_export_key and 'cd /etc/security/serverKeys && cat ./server.`hostname -d`.crt ./rootCA.pem ./server.`hostname -d`.key > certificate.pem'
    local _master_node="${2:-node3.`hostname -d`}"
    local _slave_node="${3:-node4.`hostname -d`}"
    local _sample_conf="$4" # Result of "./bin/generate_haproxy_cfg -ah 'node3.support.localdomain,node4.support.localdomain'"

    local _certs_dir="`dirname "${_certificate}"`"
    if [ ! -s "${_certificate}" ] && [ -s "${_certs_dir%/}/server.keystore.jks" ]; then
        # TODO: password 'hadoop' needs to be changed
        f_export_key "${_certs_dir%/}/server.keystore.jks" "hadoop"
    fi
    if [ ! -s "${_certificate}" ]; then
        echo "ERROR: No ${_certificate}" >&2; return 1
    fi

    if [ ! -s "$_sample_conf" ]; then
        if [ ! -e './bin/generate_haproxy_cfg' ]; then
            echo "WARN: No sample HA config and no generate_haproxy_cfg" >&2
            if [ -s /etc/haproxy/haproxy.cfg.orig ] && [ -s /etc/haproxy/haproxy.cfg ]; then
                echo "Assuming the sample is copied to /etc/haproxy/haproxy.cfg"
            elif [ -s /var/tmp/share/atscale/haproxy.cfg.sample ]; then
                _sample_conf=/var/tmp/share/atscale/haproxy.cfg.sample
                echo "Using ${_sample_conf}"
            else
                sleep 3
                return 1
            fi
        else
            ./bin/generate_haproxy_cfg -ah ${_master_node},${_slave_node} || return $?
            _sample_conf=./bin/haproxy.cfg.sample
        fi
    fi

    if [ -s "$_sample_conf" ]; then
        mv /etc/haproxy/haproxy.cfg /etc/haproxy/haproxy.cfg.orig
        cp -f "${_sample_conf}" /etc/haproxy/haproxy.cfg || return $?
    fi

    yum install haproxy -y || return $?

    # append 'ssl-server-verify none' in global
    # comment out 'default-server init-addr last,libc,none'
    echo '--- '${_sample_conf}'   2018-07-16 18:09:09.504071841 +0000
+++ /etc/haproxy/haproxy.cfg    2018-07-14 05:04:50.272775825 +0000
@@ -11,6 +11,7 @@
 ####
 global
   maxconn 256
+  ssl-server-verify none

 defaults
   option forwardfor except 127.0.0.1
@@ -20,44 +21,44 @@
   timeout server 2d
   # timeout tunnel needed for websockets
   timeout tunnel 3600s
-  default-server init-addr last,libc,none
+  #default-server init-addr last,libc,none

 ####
 # AtScale Service Frontends
 ####
 frontend design_center_front
-  bind *:10500
+  bind *:10500 ssl crt '${_certificate}'
   default_backend design_center_back
 frontend sidecar_server_front
-  bind *:10501
+  bind *:10501 ssl crt '${_certificate}'
   default_backend sidecar_server_back
 frontend engine_http_front
-  bind *:10502
+  bind *:10502 ssl crt '${_certificate}'
   default_backend engine_http_back
 frontend auth_front
-  bind *:10503
+  bind *:10503 ssl crt '${_certificate}'
   default_backend auth_back
 frontend account_front
-  bind *:10504
+  bind *:10504 ssl crt '${_certificate}'
   default_backend account_back
 frontend engine_wamp_front
-  bind *:10508
+  bind *:10508 ssl crt '${_certificate}'
   default_backend engine_wamp_back
 frontend servicecontrol_front
-  bind *:10516
+  bind *:10516 ssl crt '${_certificate}'
   default_backend servicecontrol_back

 frontend engine_tcp_front_11111
   mode tcp
-  bind *:11111
+  bind *:11111 ssl crt '${_certificate}'
   default_backend engine_tcp_back_11111
 frontend engine_tcp_front_11112
   mode tcp
-  bind *:11112
+  bind *:11112 ssl crt '${_certificate}'
   default_backend engine_tcp_back_11112
 frontend engine_tcp_front_11113
   mode tcp
-  bind *:11113
+  bind *:11113 ssl crt '${_certificate}'
   default_backend engine_tcp_back_11113

 ####
@@ -65,46 +66,46 @@
 ####
 backend design_center_back
   option httpchk GET /ping HTTP/1.1\r\nHost:\ www
-  server '${_master_node}' '${_master_node}':10500 check
-  server '${_slave_node}' '${_slave_node}':10500 check
+  server '${_master_node}' '${_master_node}':10500 ssl crt '${_certificate}' check
+  server '${_slave_node}' '${_slave_node}':10500 ssl crt '${_certificate}' check
 backend sidecar_server_back
   option httpchk GET /ping HTTP/1.1\r\nHost:\ www
-  server '${_master_node}' '${_master_node}':10501 check
-  server '${_slave_node}' '${_slave_node}':10501 check
+  server '${_master_node}' '${_master_node}':10501 ssl crt '${_certificate}' check
+  server '${_slave_node}' '${_slave_node}':10501 ssl crt '${_certificate}' check
 backend engine_http_back
   option httpchk GET /ping HTTP/1.1\r\nHost:\ www
-  server '${_master_node}' '${_master_node}':10502 check
-  server '${_slave_node}' '${_slave_node}':10502 check
+  server '${_master_node}' '${_master_node}':10502 ssl crt '${_certificate}' check
+  server '${_slave_node}' '${_slave_node}':10502 ssl crt '${_certificate}' check
 backend auth_back
-  server '${_master_node}' '${_master_node}':10503 check
-  server '${_slave_node}' '${_slave_node}':10503 check
+  server '${_master_node}' '${_master_node}':10503 ssl crt '${_certificate}' check
+  server '${_slave_node}' '${_slave_node}':10503 ssl crt '${_certificate}' check
 backend account_back
   option httpchk GET /ping HTTP/1.1\r\nHost:\ www
-  server '${_master_node}' '${_master_node}':10504 check
-  server '${_slave_node}' '${_slave_node}':10504 check
+  server '${_master_node}' '${_master_node}':10504 ssl crt '${_certificate}' check
+  server '${_slave_node}' '${_slave_node}':10504 ssl crt '${_certificate}' check
 backend engine_wamp_back
-  server '${_master_node}' '${_master_node}':10508 check
-  server '${_slave_node}' '${_slave_node}':10508 check
+  server '${_master_node}' '${_master_node}':10508 ssl crt '${_certificate}' check
+  server '${_slave_node}' '${_slave_node}':10508 ssl crt '${_certificate}' check
 backend servicecontrol_back
   option httpchk GET /status HTTP/1.1\r\nHost:\ www
-  server '${_master_node}' '${_master_node}':10516 check
-  server '${_slave_node}' '${_slave_node}':10516 check backup
+  server '${_master_node}' '${_master_node}':10516 ssl crt '${_certificate}' check
+  server '${_slave_node}' '${_slave_node}':10516 ssl crt '${_certificate}' check backup

 backend engine_tcp_back_11111
   mode tcp
   option httpchk GET /ping HTTP/1.1\r\nHost:\ www
-  server '${_master_node}' '${_master_node}':11111 check port 10502
-  server '${_slave_node}' '${_slave_node}':11111 check port 10502
+  server '${_master_node}' '${_master_node}':11111 ssl crt '${_certificate}' check port 10502
+  server '${_slave_node}' '${_slave_node}':11111 ssl crt '${_certificate}' check port 10502
 backend engine_tcp_back_11112
   mode tcp
   option httpchk GET /ping HTTP/1.1\r\nHost:\ www
-  server '${_master_node}' '${_master_node}':11112 check port 10502
-  server '${_slave_node}' '${_slave_node}':11112 check port 10502
+  server '${_master_node}' '${_master_node}':11112 ssl crt '${_certificate}' check port 10502
+  server '${_slave_node}' '${_slave_node}':11112 ssl crt '${_certificate}' check port 10502
 backend engine_tcp_back_11113
   mode tcp
   option httpchk GET /ping HTTP/1.1\r\nHost:\ www
-  server '${_master_node}' '${_master_node}':11113 check port 10502
-  server '${_slave_node}' '${_slave_node}':11113 check port 10502
+  server '${_master_node}' '${_master_node}':11113 check port 10502
+  server '${_slave_node}' '${_slave_node}':11113 check port 10502

 ####
 # HAProxy Stats' > /etc/haproxy/haproxy.cfg.patch || return $?
    patch < /etc/haproxy/haproxy.cfg.patch || return $?

    # NOTE: need to configure rsyslog.conf for log
    service haproxy reload
}

help() {
    local _function_name="$1"
    local _show_code="$2"
    local _doc_only="$3"

    if [ -z "$_function_name" ]; then
        echo "help <function name> [Y]"
        echo ""
        _list "func"
        echo ""
        return
    fi

    local _output=""
    if [[ "$_function_name" =~ ^[fp]_ ]]; then
        local _code="$(type $_function_name 2>/dev/null | grep -v "^${_function_name} is a function")"
        if [ -z "$_code" ]; then
            echo "Function name '$_function_name' does not exist."
            return 1
        fi

        eval "$(echo -e "${_code}" | awk '/__doc__=/,/;/')"
        if [ -z "$__doc__" ]; then
            _output="No help information in function name '$_function_name'.\n"
        else
            _output="$__doc__"
            if [[ "${_doc_only}" =~ (^y|^Y) ]]; then
                echo -e "${_output}"; return
            fi
        fi

        local _params="$(type $_function_name 2>/dev/null | grep -iP '^\s*local _[^_].*?=.*?\$\{?[1-9]' | grep -v awk)"
        if [ -n "$_params" ]; then
            _output="${_output}Parameters:\n"
            _output="${_output}${_params}\n\n"
        fi
        if [[ "${_show_code}" =~ (^y|^Y) ]] ; then
            _output="${_output}${_code}\n"
            echo -e "${_output}" | less
        else
            [ -n "$_output" ] && echo -e "${_output}"
        fi
    else
        echo "Unsupported Function name '$_function_name'."
        return 1
    fi
}
_list() {
    local _name="$1"
    #local _width=$(( $(tput cols) - 2 ))
    local _tmp_txt=""
    # TODO: restore to original posix value
    set -o posix

    if [[ -z "$_name" ]]; then
        (for _f in `typeset -F | grep -P '^declare -f [fp]_' | cut -d' ' -f3`; do
            #eval "echo \"--[ $_f ]\" | gsed -e :a -e 's/^.\{1,${_width}\}$/&-/;ta'"
            _tmp_txt="`help "$_f" "" "Y"`"
            printf "%-28s%s\n" "$_f" "$_tmp_txt"
        done)
    elif [[ "$_name" =~ ^func ]]; then
        typeset -F | grep '^declare -f [fp]_' | cut -d' ' -f3
    elif [[ "$_name" =~ ^glob ]]; then
        set | grep ^[g]_
    elif [[ "$_name" =~ ^resp ]]; then
        set | grep ^[r]_
    fi
}



### main ########################
if [ "$0" = "$BASH_SOURCE" ]; then
    if [[ "$1" =~ ^(-h|help)$ ]]; then
        if [[ "$2" =~ ^[fp]_ ]]; then
            help "$2" "Y"
        else
            usage
            _list
        fi
        exit
    fi
    #set -x
    _SCHEMA_AND_HDFSDIR="atscale$$"
    f_setup
    f_install_atscale
fi