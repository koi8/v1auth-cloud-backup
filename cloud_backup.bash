#!/usr/local/bin/bash
#version 0.2.29

CONFIG="/root/scripts/cloud_backup.conf"
# Read config file
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
  export TMPDIR=/usr/home/tmp
}

setlogs()
{
  mkdir -p "${LOGDIR}" >&/dev/null
  LOCKFILE="${LOGDIR}/backup.lock"
  DATA=`date "+%y%m%d-%H:%M:%S"`
  LOG="${LOGDIR}/${DATA}.log"
}

lock()
{
  echo "Attempting to acquire lock ${LOCKFILE}" >>${LOG} 2>>${LOG}
  if ( set -o noclobber; echo "$$" > "${LOCKFILE}" ) 2> /dev/null; then
      trap 'EXITCODE=$?; echo "Removing lock. Exit code: ${EXITCODE}" >>${LOG} 2>>${LOG}; rm -f "${LOCKFILE}"' 0
      echo "successfully acquired lock." >>${LOG} 2>>${LOG}
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
  MOUNTS=`mount -l|grep "nfs\|nullfs\|bind"|grep -v "sunrpc\|nfsd"|awk '{print $3}'`
  for mount in ${MOUNTS}
      do
      TMP=" --exclude "${mount}
      EXCLUDE=$EXCLUDE$TMP
  done
  
#now excluding everything instead of included
    TMP=" --exclude=**"
    INCLUDE=$INCLUDE$TMP
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
  echo "  cloud_backup.bash full /home/koi/full_restored"
  echo "  Will be restored full copy to the folder /home/koi/full_restored"
}

backup()
{
  settmp
  setlogs
  lock
  include_exclude
  container_handler
  if [ "$FTPUPLOAD" == "yes" ]; then
  echo "FTPUPLOAD enabled"
    export CLOUDFILES_USERNAME="$TENANT_NAME.$USER_NAME"
    $DUPLY -v3 --full-if-older-than ${FULLIFOLDER} --volsize ${VOLSIZE} --asynchronous-upload ${STATIC_OPTIONS} ${EXCLUDE} ${INCLUDE} / ftp://${CLOUDFILES_USERNAME}:${CLOUDFILES_APIKEY}@${CLOUDFILES_FTPHOST}/${container} >>${LOG} 2>>${LOG}
    #CLEANUP all old backups older then 14 days
    echo "cleaning up:" >>${LOG} 2>>${LOG}
    $DUPLY remove-older-than ${REMOVEOLDERTHEN} --force ${STATIC_OPTIONS} ftp://${CLOUDFILES_USERNAME}:${CLOUDFILES_APIKEY}@${CLOUDFILES_FTPHOST}/${container} >>${LOG} 2>>${LOG}
    #REMOVE OLD INCREMENTAL CHAINS
    $DUPLY remove-all-inc-of-but-n-full 1 --force ${STATIC_OPTIONS} ftp://${CLOUDFILES_USERNAME}:${CLOUDFILES_APIKEY}@${CLOUDFILES_FTPHOST}/${container} >>${LOG} 2>>${LOG}
  else
  echo "FTPUPLOAD disabled"
    export CLOUDFILES_USERNAME="$TENANT_NAME:$USER_NAME"
    $DUPLY -v3 --full-if-older-than ${FULLIFOLDER} --volsize ${VOLSIZE} --asynchronous-upload ${STATIC_OPTIONS} ${EXCLUDE} ${INCLUDE} / cf+http://${container} >>${LOG} 2>>${LOG}  
    #CLEANUP all old backups older then 14 days
    echo "cleaning up:" >>${LOG} 2>>${LOG}
    $DUPLY remove-older-than ${REMOVEOLDERTHEN} --force ${STATIC_OPTIONS} cf+http://${container} >>${LOG} 2>>${LOG}
    #REMOVE OLD INCREMENTAL CHAINS
    $DUPLY remove-all-inc-of-but-n-full 1 --force ${STATIC_OPTIONS} cf+http://${container} >>${LOG} 2>>${LOG}
  fi


}

list()
{
  settmp
  setlogs
  lock
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
  fresh_backup_count=`find /home/logs/backup/* -mtime -1|wc -l`
  if [[ "$fresh_backup_count" -le "0" ]]; then echo "Managed backup is CRITICAL. Fresh log files not found"; exit 2; fi
  for i in `ls /home/logs/backup/`; do
    ecount=`grep 'Errors' /home/logs/backup/${i}|cut -d ' ' -f 2`
    if [[ $ecount -gt 0 ]]; then echo "Managed backup is CRITICAL. Check logfile /home/logs/backup/${i}"; exit 1; fi
  done



  echo "Managed backup is OK"; exit 0;
}

cron_install()
{
case "$1" in
  freebsd)
    crontab -l > /root/crontab
    echo "30 6 * * * /usr/local/bin/bash /root/scripts/cloud_backup.bash backup" >> /root/crontab
    crontab /root/crontab
    rm -rf /root/crontab
    ;;
    
  linux)
    echo "installing linux cron"
    crontab -l > /root/crontab
    echo "30 6 * * * /bin/bash /root/scripts/cloud_backup.bash backup" >> /root/crontab
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
    grep -q 'check_managed_backup' /etc/nagios/nrpe.cfg || echo "command[check_managed_backup]=/bin/bash /usr/lib64/nagios/plugins/cloud_backup.bash check" >> /etc/nagios/nrpe.cfg && /sbin/service nrpe restart && echo "NRPE command installed"
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
}

container_handler()
{
  #checking container and creating it if it is not exists
  export CLOUDFILES_USERNAME="$TENANT_NAME.$USER_NAME"
  uname -s| grep FreeBSD && lftp -e "set net:max-retries 2; ls $container; bye" -u $CLOUDFILES_USERNAME,$CLOUDFILES_APIKEY $CLOUDFILES_FTPHOST || lftp -e "set net:max-retries 2; mkdir $container; bye" -u $CLOUDFILES_USERNAME,$CLOUDFILES_APIKEY $CLOUDFILES_FTPHOST && echo "Container created"
}

restore()
{
  settmp
  setlogs
  lock
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

  *)
    usage
    ;;
    
esac

unset CLOUDFILES_USERNAME
unset CLOUDFILES_APIKEY
unset CLOUDFILES_AUTHURL
unset TMPDIR
