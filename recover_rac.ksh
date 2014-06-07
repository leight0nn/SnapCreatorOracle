#!/bin/ksh93
#######################################################################################################
# recover_rac.ksh
# Created 05/17/2014
#
# 
#
# Authors:	Leighton L. Nelson
#			leightonn@gmail.com
#
# Purpose: Recover and rename cloned RAC database with multiple threads to a single instance
# The script assumes that the database has already been cloned and controlfile recreated.
# The target should also be in mount mode (check not yet implemented).
#
# Usage recover_rac.ksh clnsid
#	where clnsid is the name of the target database
# The name of the source database is hard-coded but can be passed as a parameter or from SC config
# To Do:
#		1) Check mount state of database
#		2) Need deterministic way of determining when logs have been applied instead of "sleep"
#		3) Parameterize more options
#
#######################################################################################################
ORACLE_HOME=$ORACLE_BASE/11.2.0/dbhome_1
ORACLE_SID=$1
#CLONE=$ORACLE_SID
CLNSID=$ORACLE_SID
SRCSID=mydb
ARCH_LOGS=/mnt/clone/logs.txt #List of archivelogs from source database
TMPDIR=/tmp
CLONE_LOGS=$TMPDIR/${CLNSID}_logs.txt
OUTPUT=$TMPDIR/output
SQLPIPE=$TMPDIR/sql
LOGDIR=/home/oracle/logs/clone
TIME=`date +%m-%d-%y-%H.%M`
retry_count=6 # This is really the maximum number of archivelogs to try
reco_sleep_cnt=15 # You may want to increase this if archivelogs are large (> 2GB)
temp=TEMP

#Cleanup
####################
function cleanup_tmp
###################
{
rm -f $OUTPUT
rm -f $SQLPIPE
rm -f $TMPDIR/pipe.sh
rm -f $TMPDIR/connect.sh
rm -f $TMPDIR/mkinit$CLNSID.sh
rm -f $TMPDIR/start$CLNSID.sh
rm -f $TMPDIR/mkspfile$CLNSID.sh
rm -f $TMPDIR/init$CLSID.ora
rm -f $TMPDIR/chdbid$CLNSID.sh
rm -f $TMPDIR/resetlogs$CLNSID.sh
rm -f $TMPDIR/recover$CLNSID.sh
rm -f $TMPDIR/mkclonelogs.sh
}

##################
function if_error
##################
{
if [[ $? -ne 0 ]]; then # check return code passed to function
    print "$1" # if rc > 0 then print error msg and quit
exit $?
fi
}

##################
function recover
##################
{
retries=0
    while [[ $retries -lt $retry_count ]];
    do
	THREAD_NO=$(grep -E thread ${OUTPUT} | grep -E ORA-00280 ${OUTPUT} | awk '{print $6}' | tail -1)
    	# Find the logs based on the thread#($2), first_change#($4) and next_change#($5)
        APPLYLOG=$(awk "{if (\$2==$THREAD_NO && \$4<=${RECOVERY_SCN} && \$5>${RECOVERY_SCN}) print \$1}" ${CLONE_LOGS})
        echo "${APPLYLOG}" > $SQLPIPE
        sleep $reco_sleep_cnt
	((retries+=1))
	echo "Retry count is: $retries"
        if (grep -i "no longer needed" ${OUTPUT});
        then
        	echo "CANCEL" > $SQLPIPE
		if (grep -i "ORA-01547:" ${OUTPUT});
			then
			echo "Error: Recovery not completed."
			exit 4
		else
			echo "Recovery completed successfully"
			break
		fi
        fi

    done
}

#####################
function cleanup_pipe
#####################
{
ps -ef | grep pipe | awk '{print $2}' | xargs kill > /dev/null 2>&1
ps -ef | grep sh-np- | grep -v grep | awk '{print }' | xargs kill -9 > /dev/null 2>&1
rm -f $TMPDIR/sh-np-* > /dev/null 2>&1
}

# Check the database status
#####################
function get_db_status
#####################
{
$ORACLE_HOME/bin/sqlplus "/ as sysdba" <<EOF
spool '$TMPDIR/dbstat.out' replace
select open_mode from v\$database;
spool off
exit
EOF
}

# Add tempfiles
#####################
function add_temp_file
#####################
{
$ORACLE_HOME/bin/sqlplus "/ as sysdba" <<EOF
spool '$TMPDIR/add_temp.out' replace
alter tablespace $temp add tempfile '+DG_DATA_$CLNSID' size 10G autoextend on next 1G maxsize 32G;
spool off
exit
EOF
}

# Open database resetlogs
#####################
function open_reset_logs
#####################
{
$ORACLE_HOME/bin/sqlplus "/ as sysdba" <<EOF
spool '$TMPDIR/openresetlogs.out' replace
alter database open resetlogs;
shutdown immediate;
startup mount pfile=$TMPDIR/init$CLNSID.ora;
spool off
exit
EOF
}

echo "sed  -e 's/_ARCH/_ARCH_$CLNSID/g' $ARCH_LOGS > $CLONE_LOGS" > $TMPDIR/mkclonelogs.sh
chmod +x $TMPDIR/mkclonelogs.sh
$TMPDIR/mkclonelogs.sh
if_error "Error: Could not generate logs"

# Create pipe to dynamically send archivelogs needed to recover database
echo "Create pipe for reading (output) and writing (sql)..."
echo "#!/bin/bash" >> $TMPDIR/pipe.sh
echo "rm -f $TMPDIR/pipe.sh" >> $TMPDIR/pipe.sh
echo "mkfifo ${SQLPIPE}" >> $TMPDIR/pipe.sh
echo "touch ${OUTPUT}" >> $TMPDIR/pipe.sh
echo "cat > ${SQLPIPE} >(sqlplus / as sysdba < ${SQLPIPE} > $OUTPUT)" >> $TMPDIR/pipe.sh
chmod +x $TMPDIR/pipe.sh
nohup $TMPDIR/pipe.sh 2> /dev/null &

# Execute the recover database statement through the pipe
echo "echo \"RECOVER DATABASE USING BACKUP CONTROLFILE UNTIL CANCEL NOPARALLEL;\" > ${SQLPIPE}" > $TMPDIR/recover$CLNSID.sh
chmod +x $TMPDIR/recover$CLNSID.sh
$TMPDIR/recover$CLNSID.sh > $LOGDIR/recover-$CLNSID-$TIME.log 2>&1
if_error "Error: Executing recover SQL statement failed."
sleep 15

# Find recovery SCN from output of recover sql command
RECOVERY_SCN=$(grep ORA-00279 ${OUTPUT} | awk '{print $4}')
echo $RECOVERY_SCN

# Recover the database
if [[ -n RECOVERY_SCN ]];
then
	recover
else
	echo "Recover SCN not identified."
	echo "Please check logs for details."
	cleanup_pipe
	exit
fi
sleep 10

cleanup_pipe
sleep 5

# Startup cloned database and open with resetlogs
open_reset_logs
if grep ERROR $TMPDIR/openresetlogs.out ; 
then
 echo "Error: Open resetlogs failed."
exit
fi

# Change database name and dbid
echo "Changing internal DBID with nid..."
echo "$ORACLE_HOME/bin/nid target=/ dbname=$CLNSID logfile=$LOGDIR/nid$CLNSID-$TIME.log" > $TMPDIR/chdbid$CLNSID.sh
chmod +x $TMPDIR/chdbid$CLNSID.sh
$TMPDIR/chdbid$CLNSID.sh
if_error "Error: Could not rename database"

# Create a new pfile with new dbname(CLNSID) and make a spfile for subsequent operations
echo "Create new pfile/spfile after changing DBID..."
echo "sed -e '/db_name=/ s/=.*/='$CLNSID'/' $TMPDIR/init$CLNSID.ora > $ORACLE_HOME/dbs/init$CLNSID.ora" > $TMPDIR/mkspfile$CLNSID.sh
echo "$ORACLE_HOME/bin/sqlplus / as sysdba << EOF" >> $TMPDIR/mkspfile$CLNSID.sh
echo "startup mount pfile=$ORACLE_HOME/dbs/init$CLNSID.ora" >> $TMPDIR/mkspfile$CLNSID.sh
echo "create spfile from pfile='$ORACLE_HOME/dbs/init$CLNSID.ora';" >> $TMPDIR/mkspfile$CLNSID.sh
echo "shutdown immediate;" >> $TMPDIR/mkspfile$CLNSID.sh
echo "EOF" >> $TMPDIR/mkspfile$CLNSID.sh
chmod +x $TMPDIR/mkspfile$CLNSID.sh
$TMPDIR/mkspfile$CLNSID.sh >> $LOGDIR/mkspfile$CLNSID-$TIME.log 2>&1
if_error "Error: Could not create spfile"

if grep ORA-01081 $LOGDIR/mkspfile$CLNSID-$TIME.log ; then
 echo "An error occurred while making spfile database.. cannot start already-running ORACLE - shut it down
first"
exit
fi

# Startup cloned database and open with resetlogs
echo "Starting database..."
echo "$ORACLE_HOME/bin/sqlplus "/ as sysdba" <<EOF" > $TMPDIR/resetlogs$CLNSID.sh
echo "startup mount;" >> $TMPDIR/resetlogs$CLNSID.sh
echo "alter database open resetlogs;" >> $TMPDIR/resetlogs$CLNSID.sh
echo "EOF" >> $TMPDIR/resetlogs$CLNSID.sh
chmod +x $TMPDIR/resetlogs$CLNSID.sh
$TMPDIR/resetlogs$CLNSID.sh >> $LOGDIR/resetlogs-$CLNSID-$TIME.LOG 2>&1
if_error "Error: Open resetlogs failed"

# Add a temp file to temp tablespace in cloned database
add_temp_file	

# Cleanup temp files
cleanup_tmp
#echo "Database Clone for $CLNSID completed successfully"
exit 
