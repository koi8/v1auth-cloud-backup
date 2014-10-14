#!/usr/local/bin/bash
#version 0.2.46

CONFIG="/root/scripts/cloud_backup.conf"
# Read config file
REMOVEOLDINCCOUNT='1'
CRON_MTIME='1'
if [ ! -z "$CONFIG" -a -f "$CONFIG" ];
then
  . $CONFIG
else
  echo "Errors: 1 can't find config file! (${CONFIG})" >&2
  usage
  exit 1
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
  MOUNTS=`mount|grep "nfs\|nullfs\|bind"|grep -v "sunrpc\|nfsd"|awk '{print $3}'`
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
    for i in `/bin/mount|cut -d ' ' -f 1 | grep -v "swap\|devpts\|proc\|sysfs\|tmpfs" | sort | uniq`; do grep $i /etc/fstab | head -n 1 | awk '{print $2}'; done >/root/scripts/cloud_backup_inc.list
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
  echo "${EXLIST}" > /root/scripts/cloud_backup_exc.lst
  
case `uname -s` in
  Linux)
    /bin/mount |grep "nfs\|nullfs\|bind"|grep -v "sunrpc\|nfsd"|awk '{print $3}' >> /root/scripts/cloud_backup_exc.lst
  ;;

  FreeBSD)
    /sbin/mount |grep "nfs\|nullfs\|bind"|grep -v "sunrpc\|nfsd"|awk '{print $3}' >> /root/scripts/cloud_backup_exc.lst
  ;;

  *)
    echo "Couldn't detect OS"
  ;;
esac

}

usage()
{
  echo " ALL SETTINGS ARE STORED AT cloud_backup.conf "
  echo "CURRENT VARIABLES:"
  echo ""
  echo "  FULLIFOLDER: We will do full backup, if the last full backup was done '$FULLIFOLDER' (days) ago."
  echo "  REMOVEOLDERTHEN: We will clean backups older the '$REMOVEOLDERTHEN' (days)."
  echo "  We will store only 1 incremental chain."
  echo "  VOLSIZE: We will do '${VOLSIZE}' (Mb) archives."
  echo ""
  echo "  FLIST: We will backup this folders:"
  echo "$FLIST"
  echo ""
  echo "  EXLIST: And exclude this folders:"
  echo "$EXLIST"
  echo ""
  echo "##########################################################################################"
  echo "BACKUP"
  echo ""
  echo "  Change CLOUDFILES_USERNAME, CLOUDFILES_APIKEY, FLIST, EXLIST, then run"
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

  echo "Managed backup is OK"; exit 0;
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

clb_install()
{
case `uname -s` in
  Linux)
    echo "It's Linux"
    chmod +x ~/scripts/cloud_backup.bash
    #nrpe
    [ -e /usr/lib64/nagios/plugins/cloud_backup.bash ] || ln -s /root/scripts/cloud_backup.bash /usr/lib64/nagios/plugins/cloud_backup.bash && echo "Symlink /usr/lib64/nagios/plugins/cloud_backup.bash created"
    grep -q 'check_managed_backup' /etc/nagios/nrpe.cfg || echo "command[check_managed_backup]=/usr/lib64/nagios/plugins/cloud_backup.bash check" >> /etc/nagios/nrpe.cfg && /sbin/service nrpe restart && echo "NRPE command installed"
    #cron
    crontab -l|grep -q "cloud_backup.bash backup" || cron_install linux && echo "Cron added"
    ;;
    
  FreeBSD)
    echo "It's FreeBSD"
    chmod +x ~/scripts/cloud_backup.bash
    #nrpe
    [ -e /usr/local/libexec/nagios/cloud_backup.bash ] || ln -s /root/scripts/cloud_backup.bash /usr/local/libexec/nagios/cloud_backup.bash && echo "Creating symlink /usr/local/libexec/nagios/cloud_backup.bash"
    grep -q 'check_managed_backup' /usr/local/etc/nrpe.cfg || echo "command[check_managed_backup]=/usr/local/libexec/nagios/cloud_backup.bash check" >> /usr/local/etc/nrpe.cfg && /usr/local/etc/rc.d/nrpe2 restart && echo "NRPE command installed"
    #cron
    crontab -l|grep -q "cloud_backup.bash backup" || cron_install freebsd && echo "Cron added"
    ;;
    
  *)
    echo "Couldn't detect OS"
    ;;
    
esac

#config
ls ~/scripts/cloud_backup.conf || config_setup && echo "Config installed"

}

config_setup()
#Download right config for cloud_backup based on OS and DC
{

case `uname -s` in
  Linux)
    wget -O /root/scripts/cloud_backup.conf_template https://noc.webzilla.com/INSTALL/scripts/cloud_backup.conf_template
    if ( `hostname | grep -q -e '^v-.*$'` ) ; then {
      cat /root/scripts/cloud_backup.conf_template|sed 's/CHANGEME/eu/; s/PATHTOARCH/home/'>/root/scripts/cloud_backup.conf
    }
    else
      cat /root/scripts/cloud_backup.conf_template|sed 's/CHANGEME/us/; s/PATHTOARCH/home/'>/root/scripts/cloud_backup.conf
    fi
    rm -rf /root/scripts/cloud_backup.conf_template
    ;;

  FreeBSD)
    fetch --no-verify-peer -o /root/scripts/cloud_backup.conf_template https://noc.webzilla.com/INSTALL/scripts/cloud_backup.conf_template
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
  #checking container and creating it if it is not exists
  export CLOUDFILES_USERNAME="$TENANT_NAME.$USER_NAME"
  uname -s| grep FreeBSD && lftp -e "set net:max-retries 2; ls $container; bye" -u $CLOUDFILES_USERNAME,$CLOUDFILES_APIKEY $CLOUDFILES_FTPHOST|awk '{system("date \"+%Y-%m-%d %H:%M:%S\"|tr -d \"\\n\"");print " "$0}' >>${LOG} 2>>${LOG} || lftp -e "set net:max-retries 2; mkdir $container; bye" -u $CLOUDFILES_USERNAME,$CLOUDFILES_APIKEY $CLOUDFILES_FTPHOST|awk '{system("date \"+%Y-%m-%d %H:%M:%S\"|tr -d \"\\n\"");print " "$0}' >>${LOG} 2>>${LOG} && echo "Container created"|awk '{system("date \"+%Y-%m-%d %H:%M:%S\"|tr -d \"\\n\"");print " "$0}' >>${LOG} 2>>${LOG}
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
  #function to clean data from the cloud
  killall -9 duplicity
  export CLOUDFILES_USERNAME="$TENANT_NAME.$USER_NAME"
  uname -s| grep FreeBSD && lftp -e "set net:max-retries 2; rm -r $container; bye" -u $CLOUDFILES_USERNAME,$CLOUDFILES_APIKEY $CLOUDFILES_FTPHOST|awk '{system("date \"+%Y-%m-%d %H:%M:%S\"|tr -d \"\\n\"");print " "$0}' >>${LOG} 2>>${LOG} && echo "Container $container deleted"|awk '{system("date \"+%Y-%m-%d %H:%M:%S\"|tr -d \"\\n\"");print " "$0}' >>${LOG} 2>>${LOG}
  uname -s| grep Linux && yum install -y lftp && lftp -e "set net:max-retries 2; rm -r $container; bye" -u $CLOUDFILES_USERNAME,$CLOUDFILES_APIKEY $CLOUDFILES_FTPHOST|awk '{system("date \"+%Y-%m-%d %H:%M:%S\"|tr -d \"\\n\"");print " "$0}' >>${LOG} 2>>${LOG} && echo "Container $container deleted"|awk '{system("date \"+%Y-%m-%d %H:%M:%S\"|tr -d \"\\n\"");print " "$0}' >>${LOG} 2>>${LOG}
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
    
  status)
    collection_status
    ;;
    
  delete)
    cleanup_backup
    ;;
    
  *)
    usage
    ;;
    
esac

unset CLOUDFILES_USERNAME
unset CLOUDFILES_APIKEY
unset CLOUDFILES_AUTHURL
unset TMPDIR
