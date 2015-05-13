#!/usr/local/bin/bash
#version 0.2.65
CONFIG="/root/scripts/cloud_backup.conf"

usage()
{
  echo " ALL SETTINGS ARE STORED AT cloud_backup.conf "
  echo "CURRENT VARIABLES:"
  echo ""
  echo "  FULLIFOLDER: We will do full backup, if the last full backup was done '$FULLIFOLDER' (days) ago."
  echo "  REMOVEOLDERTHEN: We will clean backups older the '$REMOVEOLDERTHEN' (days)."
  echo "  REMOVEOLDINCCOUNT: We will store '${REMOVEOLDINCCOUNT}' incremental chain(s)."
  echo "  VOLSIZE: We will do '${VOLSIZE}' (Mb) archives."
  echo "  CRON_MTIME: Check is configured for cron running every '${CRON_MTIME}' days."
  echo "  We will backup all server"
  echo "  EXLIST: And exclude this folders:"
  echo "$EXLIST"
  echo ""
  echo "##########################################################################################"
  echo "BACKUP"
  echo ""
  echo "  Change CLOUDFILES_USERNAME, CLOUDFILES_APIKEY, EXLIST, then run"
  echo "  'cloud_backup.bash backup' - to run backup"
  echo ""
  echo "##########################################################################################"
  echo "RESTORE EXAMPLES"
  echo ""
  echo "  cloud_backup.bash restore usr/local/nginx/conf/ /home/koi/conf"
  echo "  Folder /usr/local/nginx/conf will be restored from the cloud as /home/koi/conf folder"
  echo ""
  echo "  cloud_backup.bash restore -t 2D usr/test /home/koi/restored_test"
  echo "  Will be restored copy two days ago of the file /usr/test as /home/koi/restored_test"
  echo ""
  echo "  cloud_backup.bash restore full /home/koi/full_restored"
  echo "  Will be restored full copy to the folder /home/koi/full_restored"
  echo "##########################################################################################"
  echo "'cloud_backup.bash delete' - will remove server container from the cloud storage"
  echo "'cloud_backup.bash status' - shows current status of the backup"
  echo "'cloud_backup.bash list'   - shows list of backuped files"
  echo "'cloud_backup.bash check'  - function for nrpe checks"
  echo "'cloud_backup.bash cleanup'- cleaning incomplete backup chains"
}


# Read config file
if [ ! -z "$CONFIG" -a -f "$CONFIG" ];
then
  . $CONFIG
else
  if [ "$1" != "install" ];
  then
    echo "Errors: 1 can't find config file! (${CONFIG})" >&2
    exit 1
  fi
fi

export PATH="/sbin:/usr/sbin:/bin:/usr/bin:/usr/local/sbin:/usr/local/bin"
DUPLY=`which duplicity`


settmp()
{
  mkdir -p /home/tmp >&/dev/null
  export TMPDIR="${ARCHDIR}"
}

setlogs()
{
  mkdir -p "${LOGDIR}" >&/dev/null
  LOCKFILE="${LOGDIR}/backup.lock"
  LOG="${LOGDIR}/cloud_backup.log"
}

lock()
{
  echo "Attempting to acquire lock ${LOCKFILE}" | awk '{system("date \"+%Y-%m-%d %H:%M:%S\"|tr -d \"\\n\"");print " "$0}' >>${LOG} 2>>${LOG}
  if ( set -o noclobber; echo "$$" > "${LOCKFILE}" ) 2> /dev/null; then
      trap 'EXITCODE=$?; echo "Removing lock. Exit code: ${EXITCODE}" >>${LOG} 2>>${LOG}; rm -f "${LOCKFILE}"' 0
      echo "successfully acquired lock." | awk '{system("date \"+%Y-%m-%d %H:%M:%S\"|tr -d \"\\n\"");print " "$0}' >>${LOG} 2>>${LOG}
  else
      echo "lock failed, could not acquire ${LOCKFILE}" | tee -a ${LOG} >&2
      echo "lock held by $(cat ${LOCKFILE})" | tee -a ${LOG} >&2
      exit 2
  fi
  rm -rf ${ARCHDIR}/*/lockfile.lock
}

include_exclude()
{
#building include list from FLIST
  for include in ${FLIST}   
    do
      TMP=" --include="$include
      INCLUDE=$INCLUDE$TMP
  done

#building exclude list from EXLIST  
  for exclude in ${EXLIST}
      do
      TMP=" --exclude "$exclude
      EXCLUDE=$EXCLUDE$TMP
  done
  
#excluding all nfs and nullfs(bind) mounts
  MOUNTS=`mount|grep "nfs\|nullfs\|bind"|grep -v "sunrpc\|nfsd\|nfsv4acls"|awk '{print $3}'`
  for mount in ${MOUNTS}
      do
      TMP=" --exclude "${mount}
      EXCLUDE=$EXCLUDE$TMP
  done
  
#now excluding everything instead of included
    TMP=" --exclude=**"
    INCLUDE=$INCLUDE$TMP
}

include_file()
{

case `uname -s` in
  Linux)
    for i in `/bin/mount|cut -d ' ' -f 1 | grep -v "swap\|devpts\|proc\|sysfs\|tmpfs\|none" | sort | uniq`; do grep $i /etc/fstab | head -n 1 | awk '{print $2}'; done >/root/scripts/cloud_backup_inc.list
  ;;

  FreeBSD)
    for i in `/sbin/mount|cut -d ' ' -f 1 | grep -v "swap\|devpts\|proc\|sysfs\|tmpfs" | sort | uniq`; do grep $i /etc/fstab | head -n 1 | awk '{print $2}'; done >/root/scripts/cloud_backup_inc.list
  ;;

  *)
    echo "Couldn't detect OS"
  ;;
esac

echo "- **" >>/root/scripts/cloud_backup_inc.list
}

exclude_file()
{
  echo "${EXLIST}" > /root/scripts/cloud_backup_exc.list
  
case `uname -s` in
  Linux)
    /bin/mount |grep "nfs\|nullfs\|bind"|grep -v "sunrpc\|nfsd"|awk '{print $3}' >> /root/scripts/cloud_backup_exc.list
  ;;

  FreeBSD)
    /sbin/mount |grep "nfs\|nullfs\|bind"|grep -v "sunrpc\|nfsd"|awk '{print $3}' >> /root/scripts/cloud_backup_exc.list
  ;;

  *)
    echo "Couldn't detect OS"
  ;;
esac

}


backup()
{
  settmp
  setlogs
  lock
  include_exclude
  include_file
  exclude_file
  container_handler|awk '{system("date \"+%Y-%m-%d %H:%M:%S\"|tr -d \"\\n\"");print " "$0}' >>${LOG} 2>>${LOG}
  if [ "$FTPUPLOAD" == "yes" ]; then
  echo "FTPUPLOAD enabled"
    export CLOUDFILES_USERNAME="$TENANT_NAME.$USER_NAME"
    #old string to backup
#    $DUPLY -v3 --full-if-older-than ${FULLIFOLDER} --volsize ${VOLSIZE} --asynchronous-upload ${STATIC_OPTIONS} ${EXCLUDE} ${INCLUDE} / ftp://${CLOUDFILES_USERNAME}:${CLOUDFILES_APIKEY}@${CLOUDFILES_FTPHOST}/${container} | awk '{system("date \"+%Y-%m-%d %H:%M:%S\"|tr -d \"\\n\"");print " "$0}' >>${LOG} 2>>${LOG}

    #new string to backup
    $DUPLY -v3 --full-if-older-than ${FULLIFOLDER} --volsize ${VOLSIZE} --asynchronous-upload ${STATIC_OPTIONS} --exclude-globbing-filelist /root/scripts/cloud_backup_exc.list --include-globbing-filelist /root/scripts/cloud_backup_inc.list / ftp://${CLOUDFILES_USERNAME}:${CLOUDFILES_APIKEY}@${CLOUDFILES_FTPHOST}/${container} | awk '{system("date \"+%Y-%m-%d %H:%M:%S\"|tr -d \"\\n\"");print " "$0}' >>${LOG} 2>>${LOG}

    #CLEANUP all old backups older then 14 days
    echo "cleaning up:" | awk '{system("date \"+%Y-%m-%d %H:%M:%S\"|tr -d \"\\n\"");print " "$0}' >>${LOG} 2>>${LOG}
    $DUPLY remove-older-than ${REMOVEOLDERTHEN} --force ${STATIC_OPTIONS} ftp://${CLOUDFILES_USERNAME}:${CLOUDFILES_APIKEY}@${CLOUDFILES_FTPHOST}/${container} | awk '{system("date \"+%Y-%m-%d %H:%M:%S\"|tr -d \"\\n\"");print " "$0}' >>${LOG} 2>>${LOG}
    #REMOVE OLD INCREMENTAL CHAINS
    $DUPLY remove-all-inc-of-but-n-full $REMOVEOLDINCCOUNT --force ${STATIC_OPTIONS} ftp://${CLOUDFILES_USERNAME}:${CLOUDFILES_APIKEY}@${CLOUDFILES_FTPHOST}/${container} | awk '{system("date \"+%Y-%m-%d %H:%M:%S\"|tr -d \"\\n\"");print " "$0}' >>${LOG} 2>>${LOG}
  else
  echo "FTPUPLOAD disabled"
    export CLOUDFILES_USERNAME="$TENANT_NAME:$USER_NAME"
    #old string to backup
#    $DUPLY -v3 --full-if-older-than ${FULLIFOLDER} --volsize ${VOLSIZE} --asynchronous-upload ${STATIC_OPTIONS} ${EXCLUDE} ${INCLUDE} / cf+http://${container} | awk '{system("date \"+%Y-%m-%d %H:%M:%S\"|tr -d \"\\n\"");print " "$0}' >>${LOG} 2>>${LOG}  

    #new string to backup
    $DUPLY -v3 --full-if-older-than ${FULLIFOLDER} --volsize ${VOLSIZE} --asynchronous-upload ${STATIC_OPTIONS} --exclude-globbing-filelist /root/scripts/cloud_backup_exc.list --include-globbing-filelist /root/scripts/cloud_backup_inc.list / cf+http://${container} | awk '{system("date \"+%Y-%m-%d %H:%M:%S\"|tr -d \"\\n\"");print " "$0}' >>${LOG} 2>>${LOG}  

    #CLEANUP all old backups older then 14 days
    echo "cleaning up:" | awk '{system("date \"+%Y-%m-%d %H:%M:%S\"|tr -d \"\\n\"");print " "$0}' >>${LOG} 2>>${LOG}
    $DUPLY remove-older-than ${REMOVEOLDERTHEN} --force ${STATIC_OPTIONS} cf+http://${container} | awk '{system("date \"+%Y-%m-%d %H:%M:%S\"|tr -d \"\\n\"");print " "$0}' >>${LOG} 2>>${LOG}
    #REMOVE OLD INCREMENTAL CHAINS
    $DUPLY remove-all-inc-of-but-n-full $REMOVEOLDINCCOUNT --force ${STATIC_OPTIONS} cf+http://${container} | awk '{system("date \"+%Y-%m-%d %H:%M:%S\"|tr -d \"\\n\"");print " "$0}' >>${LOG} 2>>${LOG}
  fi
  collection_status >/root/scripts/cloud_backup_status 2>/root/scripts/cloud_backup_status

}

list()
{
  settmp
  setlogs
  if [ "$FTPUPLOAD" == "yes" ]; then
    echo "FTPUPLOAD enabled"
    export CLOUDFILES_USERNAME="$TENANT_NAME.$USER_NAME"
    $DUPLY list-current-files ${STATIC_OPTIONS} ftp://${CLOUDFILES_USERNAME}:${CLOUDFILES_APIKEY}@${CLOUDFILES_FTPHOST}/${container}
  else
    echo "FTPUPLOAD disabled"
    export CLOUDFILES_USERNAME="$TENANT_NAME:$USER_NAME"
    $DUPLY list-current-files ${STATIC_OPTIONS} cf+http://${container}
  fi
}

check()
{
  setlogs
  #checking for log file updates(make sure cron is run every day)
  fresh_backup_count=`find ${LOGDIR}/* -mtime -${CRON_MTIME}|wc -l`
  if [[ "$fresh_backup_count" -le "0" ]]; then echo "Managed backup is CRITICAL. Fresh log file not found"; exit 2; fi
  
  #check for FTPUPLOAD(should be enabled on 413 errors)
  request_entiti=`grep -c '413 Request Entity Too Large' ${LOG}`
  if [[ "$request_entiti" -gt 0 ]]; then
     if [ "$FTPUPLOAD" == "no" ]; then
      echo "Managed backup is CRITICAL. Request Entity Too Large, change FTPUPLOAD param to yes"; exit 2;
    fi
  fi
  bigsignatures=`find ${ARCHDIR}/* -size +4700M | wc -l`
  if [[ "$bigsignatures" -gt 0 ]]; then
     if [ "$FTPUPLOAD" == "no" ]; then
      echo "WARNING. Signatures files size is close to critical, change FTPUPLOAD param to yes"; exit 1;
    fi
  fi
  
  #check for Auth errors
  day=`date "+%Y-%m-%d"`
  auth_error=`cat ${LOG}| grep $day | grep 'AuthenticationFailed\|was not accepted for login'|cut -d '-' -f 1|head -n 1`
  if [[ "$auth_error" -gt 0 ]]; then
    echo "Managed backup is CRITICAL. Authentication Failed. Check and test credentials, schedule monitoring till the next day"; exit 2;
  fi

  #check for last full backup
  lastfull_none=$(grep $(date +%Y-%m-%d) ${LOG}|grep 'Last full backup date: none'|wc -l)
  if [[ "$lastfull_none" -gt 0 ]]; then
    echo "WARNING. No full backups. Check logs"; exit 1;
  fi

  #check for restarting
  restarted_job=$(grep $(date +%Y-%m-%d) ${LOG}|grep 'Restarting backup at volume'|wc -l)
  if [[ "$restarted_job" -gt 0 ]]; then
    echo "WARNING. Uploading has not been done. Check logs"; exit 1;
  fi
  
  #check for dead lock
  if [ -e ${LOCKFILE} ]; then
    ppid=$(cat "${LOCKFILE}")
    if !(kill -0 "${ppid}"); then
      echo "Dead lock detected! Check why script crashed and remove ${LOCKFILE}"; exit 2;
    fi
  fi
  
  check_full_date
    
  echo "Managed backup is OK"; exit 0;
}

check_full_date()
{
  number=$(echo "$FULLIFOLDER"| sed 's/[A-Za-z]*//g')
  check_month1=$(date "+%B")
  last_full_month=$(cat /root/scripts/cloud_backup_status |grep full|cut -d ':' -f 2|awk '{print $2}')
  
  if $(echo "$FULLIFOLDER"|grep -q 'D'); then
    check_month2=$(date -r $(echo "`date +%s` - (${number} * 24 * 60 * 60)" |bc) "+%B")
  fi
  
  if $(echo "$FULLIFOLDER"|grep -q 'M'); then
    check_month2=$(date -r $(echo "`date +%s` - (${number} * 30 * 24 * 60 * 60)" |bc) "+%B")
  fi
  
  case "$last_full_month" in
    "$check_month1")
      ;;
    
    "$check_month2")
      ;;
    
    *)
      echo "Last full day to old, was made in $last_full_month . It is not in $check_month1 or $check_month2 ) ! Something wrong here!"; exit 2;
      ;;
      
    esac
}

collection_status()
{   
  settmp
  setlogs
  #lock
  if [ "$FTPUPLOAD" == "yes" ]; then
    export CLOUDFILES_USERNAME="$TENANT_NAME.$USER_NAME"
    $DUPLY collection-status ${STATIC_OPTIONS} ftp://${CLOUDFILES_USERNAME}:${CLOUDFILES_APIKEY}@${CLOUDFILES_FTPHOST}/${container}
  else  
    export CLOUDFILES_USERNAME="$TENANT_NAME:$USER_NAME"
    $DUPLY collection-status ${STATIC_OPTIONS} cf+http://${container}
  fi
}

cron_install()
{
case "$1" in
  freebsd)
    crontab -l > /root/crontab
    echo "" >> /root/crontab
    echo "30 6 * * * /usr/local/bin/trickle -u 6400 /usr/local/bin/bash /root/scripts/cloud_backup.bash backup" >> /root/crontab
    crontab /root/crontab
    rm -rf /root/crontab
    ;;
    
  linux)
    echo "installing linux cron"
    crontab -l > /root/crontab
    echo "" >> /root/crontab
    echo "30 6 * * * /usr/bin/trickle -u 6400 /bin/bash /root/scripts/cloud_backup.bash backup" >> /root/crontab
    crontab /root/crontab
    rm -rf /root/crontab
    ;;
    
  *)
    echo "OS not provided for cron installation"
    ;;
esac

}

update()
{
case `uname -s` in
  Linux)
    chmod 755 /root/scripts/cloud_backup.bash
    rpl -e '#!/usr/local/bin/bash' '#!/bin/bash' /root/scripts/cloud_backup.bash
    ;;
    
  *)
  ;;
esac
}

clb_install()
{
case `uname -s` in
  Linux)
    #installing packages from yum
    yum install -y python-cloudfiles duplicity trickle python-lockfile rpl
    chmod 755 /root/scripts/cloud_backup.bash
    rpl -e '#!/usr/local/bin/bash' '#!/bin/bash' /root/scripts/cloud_backup.bash
    
    #nrpe
    [ -e /usr/lib64/nagios/plugins/cloud_backup.bash ] || ln -s /root/scripts/cloud_backup.bash /usr/lib64/nagios/plugins/cloud_backup.bash && echo "Symlink /usr/lib64/nagios/plugins/cloud_backup.bash created"
    grep -q 'check_managed_backup' /etc/nagios/nrpe.cfg || echo "command[check_managed_backup]=/usr/lib64/nagios/plugins/cloud_backup.bash check" >> /etc/nagios/nrpe.cfg && /sbin/service nrpe restart && echo "NRPE command installed"
    #cron
    crontab -l|grep -q "cloud_backup.bash backup" || cron_install linux && echo "Cron added"
    ;;
    
  FreeBSD)
    #installing packages with pkgng
    pkg install -y popt libevent2 expat
    pkg install -y librsync trickle lftp
    pkg install -y ncftp
    pkg install -y python27
    pkg install -y py27-setuptools27
    pkg install -y py27-lockfile
    
    #Installing python cloudfiles
    mkdir /usr/home/tmp
    mkdir -p /usr/local/src
    chown root:wheel /usr/local/src
    chmod 700 /usr/local/src
    fetch --no-verify-peer -o /usr/local/src/python-cloudfiles.tar.gz https://noc.webzilla.com/INSTALL/src/python-cloudfiles.tar.gz
    cd /usr/local/src/
    tar -xvzf python-cloudfiles.tar.gz
    cd python-cloudfiles
    /usr/local/bin/python2.7 setup.py install 1>>/root/cloud_backup_installation.log 2>>/root/cloud_backup_installation.log
    
    #Installing duplicity
    fetch --no-verify-peer -o /usr/local/src/duplicity-0.6.25.tar.gz https://code.launchpad.net/duplicity/0.6-series/0.6.25/+download/duplicity-0.6.25.tar.gz
    cd /usr/local/src/
    tar -xvzf duplicity-0.6.25.tar.gz
    cd duplicity-0.6.25
    /usr/local/bin/python2.7 setup.py install --librsync-dir=/usr/local/ >>/root/cloud_backup_installation.log 2>>/root/cloud_backup_installation.log
    
    chmod 755 /root/scripts/cloud_backup.bash
    #nrpe
    [ -e /usr/local/libexec/nagios/cloud_backup.bash ] || ln -s /root/scripts/cloud_backup.bash /usr/local/libexec/nagios/cloud_backup.bash && echo "Creating symlink /usr/local/libexec/nagios/cloud_backup.bash"
    grep -q 'check_managed_backup' /usr/local/etc/nrpe.cfg || echo "command[check_managed_backup]=/usr/local/libexec/nagios/cloud_backup.bash check" >> /usr/local/etc/nrpe.cfg && /usr/local/etc/rc.d/nrpe2 restart && echo "NRPE command installed"
    #cron
    crontab -l|grep -q "cloud_backup.bash backup" || cron_install freebsd && echo "Cron added"
    ;;

  Darwin)
    echo "OS X not supported"    
    exit 1
    ;;
    
  *)
    echo "Couldn't detect OS"
    exit 1
    ;;
    
esac

#config
ls ~/scripts/cloud_backup.conf || config_setup && echo "Config installed, fill in credentials"

}

config_setup()
#Download right config for cloud_backup based on OS and DC
{

case `uname -s` in
  Linux)
    wget --no-check-certificate -O /root/scripts/cloud_backup.conf_template https://noc.webzilla.com/INSTALL/scripts/cloud_backup.conf_template
    if ( `hostname | grep -q -e '^v-.*$'` ) ; then {
      cat /root/scripts/cloud_backup.conf_template|sed 's/CHANGEME/eu/; s/PATHTOARCH/home/'>/root/scripts/cloud_backup.conf
    }
    else
      cat /root/scripts/cloud_backup.conf_template|sed 's/CHANGEME/us/; s/PATHTOARCH/home/'>/root/scripts/cloud_backup.conf
    fi
    rm -rf /root/scripts/cloud_backup.conf_template
    ;;

  FreeBSD)
    touch /root/scripts/cloud_backup.conf_template
    fetch -o /root/scripts/cloud_backup.conf_template https://noc.webzilla.com/INSTALL/scripts/cloud_backup.conf_template
    if ( `hostname | grep -q -e '^v-.*$'` ) ; then {
      cat /root/scripts/cloud_backup.conf_template|sed 's/CHANGEME/eu/; s/PATHTOARCH/usr\/home/'>/root/scripts/cloud_backup.conf
    }
    else
      cat /root/scripts/cloud_backup.conf_template|sed 's/CHANGEME/us/; s/PATHTOARCH/usr\/home/'>/root/scripts/cloud_backup.conf
    fi
    rm -rf /root/scripts/cloud_backup.conf_template
    ;;

  *)
    echo "Couldn't detect OS"
    ;;

esac
}

container_handler()
{
  #checking container and creating it if it is not exists for FreeBSD only. On CentOS it creates automatically.
  export CLOUDFILES_USERNAME="$TENANT_NAME.$USER_NAME"
  if $(uname -s|grep -q FreeBSD); then
    if ! $(lftp -e "set net:max-retries 2; ls $container; bye" -u $CLOUDFILES_USERNAME,$CLOUDFILES_APIKEY $CLOUDFILES_FTPHOST >/dev/null 2>/dev/null); then
      lftp -e "set net:max-retries 2; mkdir $container; bye" -u $CLOUDFILES_USERNAME,$CLOUDFILES_APIKEY $CLOUDFILES_FTPHOST | awk '{system("date \"+%Y-%m-%d %H:%M:%S\"|tr -d \"\\n\"");print " "$0}' >>${LOG} 2>>${LOG}
    fi
  fi
}

restore()
{
  settmp
  setlogs
  if [ "$FTPUPLOAD" == "yes" ]; then
    echo "FTPUPLOAD enabled"
    export CLOUDFILES_USERNAME="$TENANT_NAME.$USER_NAME"
    case "$2" in
      -t)
        $DUPLY ${STATIC_OPTIONS} -t $3 --file-to-restore=$4 ftp://${CLOUDFILES_USERNAME}:${CLOUDFILES_APIKEY}@${CLOUDFILES_FTPHOST}/${container} $5
        ;;
    
      full)
        $DUPLY ${STATIC_OPTIONS} ftp://${CLOUDFILES_USERNAME}:${CLOUDFILES_APIKEY}@${CLOUDFILES_FTPHOST}/${container} $3
        ;;
    
      *)
        $DUPLY ${STATIC_OPTIONS} --file-to-restore=$2 ftp://${CLOUDFILES_USERNAME}:${CLOUDFILES_APIKEY}@${CLOUDFILES_FTPHOST}/${container} $3

   esac
  
  else
    echo "FTP disabled"
    export CLOUDFILES_USERNAME="$TENANT_NAME:$USER_NAME"
    case "$2" in
      -t)
        $DUPLY ${STATIC_OPTIONS} -t $3 --file-to-restore=$4 cf+http://${container} $5
        ;;
    
      full)
        $DUPLY ${STATIC_OPTIONS} cf+http://${container} $3
        ;;
    
      *)
        $DUPLY ${STATIC_OPTIONS} --file-to-restore=$2 cf+http://${container} $3

   esac
   
  fi

}

cleanup_backup()
{
  settmp
  setlogs
  #function to clean data from the cloud
  killall -9 duplicity
  export CLOUDFILES_USERNAME="$TENANT_NAME.$USER_NAME"
  if [[ $OSTYPE == freebsd* ]]; then
      lftp -e "set net:max-retries 2; rm -r $container; bye" -u $CLOUDFILES_USERNAME,$CLOUDFILES_APIKEY $CLOUDFILES_FTPHOST|awk '{system("date \"+%Y-%m-%d %H:%M:%S\"|tr -d \"\\n\"");print " "$0}' >>${LOG} 2>>${LOG} && echo "Container $container deleted"|awk '{system("date \"+%Y-%m-%d %H:%M:%S\"|tr -d \"\\n\"");print " "$0}' >>${LOG} 2>>${LOG}

  elif [[ -f /etc/redhat-release ]]; then
      yum list installed |grep -w lftp > /dev/null 2>&1 || yum install lftp -y > /dev/null 2>&1 && lftp -e "set net:max-retries 2; rm -r $container; bye" -u $CLOUDFILES_USERNAME,$CLOUDFILES_APIKEY $CLOUDFILES_FTPHOST|awk '{system("date \"+%Y-%m-%d %H:%M:%S\"|tr -d \"\\n\"");print " "$0}' >>${LOG} 2>>${LOG} && echo "Container $container deleted"|awk '{system("date \"+%Y-%m-%d %H:%M:%S\"|tr -d \"\\n\"");print " "$0}' >>${LOG} 2>>${LOG}

  elif [[ -f /etc/debian_version ]]; then
      aptitude show lftp |grep -w lftp > /dev/null 2>&1 || apt-get install -y lftp > /dev/null 2>&1 && lftp -e "set net:max-retries 2; rm -r $container; bye" -u $CLOUDFILES_USERNAME,$CLOUDFILES_APIKEY $CLOUDFILES_FTPHOST|awk '{system("date \"+%Y-%m-%d %H:%M:%S\"|tr -d \"\\n\"");print " "$0}' >>${LOG} 2>>${LOG} && echo "Container $container deleted"|awk '{system("date \"+%Y-%m-%d %H:%M:%S\"|tr -d \"\\n\"");print " "$0}' >>${LOG} 2>>${LOG}
  fi
}

cleanup_incomplete()
{
  settmp
  setlogs
  #cleaning incomplete backup chains
  export CLOUDFILES_USERNAME="$TENANT_NAME.$USER_NAME"
  $DUPLY -v3 ${STATIC_OPTIONS} --force cleanup ftp://${CLOUDFILES_USERNAME}:${CLOUDFILES_APIKEY}@${CLOUDFILES_FTPHOST}/${container}
}



case "$1" in
  backup)
    backup
    ;;
    
  restore)
    restore $1 $2 $3 $4 $5
    ;;
    
  list)
    list
    ;;

  check)
    check
    ;;
    
  install)
    clb_install
    ;;
    
  update)
    update
    ;;

  status)
    collection_status
    ;;
    
  delete)
    cleanup_backup
    ;;

  cleanup)
    cleanup_incomplete
    ;;
    
  *)
    usage
    ;;
    
esac

unset CLOUDFILES_USERNAME
unset CLOUDFILES_APIKEY
unset CLOUDFILES_AUTHURL
unset TMPDIR
