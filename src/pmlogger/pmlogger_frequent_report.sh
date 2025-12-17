#! /bin/sh
#
# Copyright (c) 2025 Red Hat.
#
# This program is free software; you can redistribute it and/or modify it
# under the terms of the GNU General Public License as published by the
# Free Software Foundation; either version 2 of the License, or (at your
# option) any later version.
#
# This program is distributed in the hope that it will be useful, but
# WITHOUT ANY WARRANTY; without even the implied warranty of MERCHANTABILITY
# or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU General Public License
# for more details.
#
#
# Administrative script for frequent metric collection using pmrep.
# This script collects the same metrics as pmlogger_daily_report but runs
# more frequently (every 5 minutes) without time-based skipping.
#
# Sample crontab entry for 5-minute intervals:
#
# # frequent metric collection
# */5   *  *  *  *  pcp  /usr/libexec/pcp/bin/pmlogger_frequent_report
#
# Output is written to /var/log/pcp/pmlogger/daily/report-YYYYMMDD-HHMM
#

. $PCP_DIR/etc/pcp.env
. $PCP_SHARE_DIR/lib/utilproc.sh

status=0
prog=`basename $0`

# optional begin logging to $PCP_LOG_DIR/NOTICES
#
if $PCP_LOG_RC_SCRIPTS
then
    logmsg="begin pid:$$ $prog args:$*"
    if which pstree >/dev/null 2>&1
    then
	logmsg="$logmsg [`_pstree_oneline $$`]"
    fi
    $PCP_BINADM_DIR/pmpost "$logmsg"
fi

# error messages should go to stderr, not the GUI notifiers
unset PCP_STDERR

LOGDIR=$PCP_LOG_DIR/pmlogger
REPORTDIR=$LOGDIR/daily
VERBOSE=false
tmp=`mktemp -d /var/tmp/pmlogger_frequent_report.XXXXXXXXX` || exit 1
trap "rm -rf $tmp; exit \$status" 0 1 2 3 15

_usage()
{
    cat <<EOF
Usage: $prog [options]

Options:
  -h HOSTNAME     override hostname (default: localhost.localdomain)
  -V              verbose output
  -?              show this usage message
EOF
    status=1
    exit
}

HOSTNAME=`hostname -f 2>/dev/null || hostname`

while getopts "h:V?" c
do
    case $c in
	h)
	    HOSTNAME=$OPTARG
	    ;;
	V)
	    VERBOSE=true
	    ;;
	?)
	    _usage
	    ;;
    esac
done
shift `expr $OPTIND - 1`

# Create output directory if it doesn't exist
if [ ! -d "$REPORTDIR" ]
then
    mkdir -p "$REPORTDIR" 2>/dev/null
    if [ ! -d "$REPORTDIR" ]
    then
	echo "$prog: Error: cannot create directory $REPORTDIR"
	status=1
	exit
    fi
    chown pcp:pcp "$REPORTDIR" 2>/dev/null
    chmod 775 "$REPORTDIR" 2>/dev/null
fi

# Find the most recent archive for the current host
ARCHIVEPATH=""
if [ -d "$LOGDIR/$HOSTNAME" ]
then
    # Get the latest archive directory (today's date)
    TODAY=`date +%Y%m%d`
    if [ -d "$LOGDIR/$HOSTNAME/$TODAY" ]
    then
	ARCHIVEPATH="$LOGDIR/$HOSTNAME/$TODAY"
    else
	# Fall back to most recent archive
	ARCHIVEPATH=`ls -td $LOGDIR/$HOSTNAME/[0-9]* 2>/dev/null | head -1`
    fi
fi

if [ -z "$ARCHIVEPATH" -o ! -d "$ARCHIVEPATH" ]
then
    echo "$prog: Warning: no archive found for host $HOSTNAME in $LOGDIR/$HOSTNAME"
    status=1
    exit
fi

# Generate timestamp for output filename
TIMESTAMP=`date +%Y%m%d-%H%M`
REPORTFILE="$REPORTDIR/report-$TIMESTAMP"

# Set up pmrep options
REPORT_OPTIONS="-a $ARCHIVEPATH -z -E 0 -p -f%H:%M:%S -t 1m"

# Common reporting function
#
_report()
{
    _conf=$1
    _comment="$2"

    $VERBOSE && echo "Generating report for $_conf $_comment"
    echo >>$REPORTFILE; echo >>$REPORTFILE
    pmdumplog -z -l $ARCHIVEPATH | awk '/commencing/ {print "# ",$2,$3,$4,$5,$6}' >>$REPORTFILE
    echo "$_comment" >>$REPORTFILE
    $VERBOSE && echo "pmrep $REPORT_OPTIONS $_conf"
    pmrep $REPORT_OPTIONS $_conf >$tmp/out 2>$tmp/err
    if [ -s $tmp/out ]
    then
    	cat $tmp/out >>$REPORTFILE
    else
	if grep 'PM_ERR_NAME' $tmp/err >/dev/null 2>&1
	then
	    metric=`$PCP_AWK_PROG <$tmp/err '/PM_ERR_NAME/ { print $3; exit }'`
	    echo "-- no report for config \"$_conf\" because the metric \"$metric\" is not in the archive" >>$REPORTFILE
	elif grep 'PM_ERR_INDOM_LOG' $tmp/err >/dev/null 2>&1
	then
	    metric=`$PCP_AWK_PROG <$tmp/err '/PM_ERR_INDOM_LOG/ { print $3; exit }'`
	    echo "-- no report for config \"$_conf\" because there are no values for any instance of the metric \"$metric\" in the archive" >>$REPORTFILE
	elif grep 'PM_ERR_BADDERIVE' $tmp/err >/dev/null 2>&1
	then
	    metric=`$PCP_AWK_PROG <$tmp/err '/PM_ERR_BADDERIVE/ { print $3; exit }'`
	    echo "-- no report for config \"$_conf\" because one or more metrics for the derived metric \"$metric\" is not in the archive" >>$REPORTFILE
	else
	    cat $tmp/err >>$REPORTFILE
	    echo "-- no report for config \"$_conf\"" >>$REPORTFILE
	fi
    fi
}

# Write report header
echo "Frequent System Activity Report" >>$REPORTFILE
echo >>$REPORTFILE
echo "Host:            $HOSTNAME" >>$REPORTFILE
echo "Archive:         $ARCHIVEPATH" >>$REPORTFILE
echo "Report created:  `date`" >>$REPORTFILE

# Generate all reports - same metrics as pmlogger_daily_report
_report :sar-u-ALL '# CPU Utilization statistics, all CPUS'
_report :sar-u-ALL-P-ALL '# CPU Utilization statistics, per-CPU'
_report :vmstat '# virtual memory (vmstat) statistics'
_report :vmstat-a '# virtual memory active/inactive memory statistics'
_report :sar-B '# paging statistics'
_report :sar-b '# I/O and transfer rate statistics'
_report :sar-d-dev '# block device statistics'
_report :sar-d-dm '# device-mapper device statistics'
_report :sar-F '# mounted filesystem statistics'
_report :sar-H '# hugepages utilization statistics'
_report :sar-I-SUM '# interrupt statistics, summed'
_report :sar-n-DEV '# network statistics, per device'
_report :sar-n-EDEV '# network error statistics, per device'
_report :sar-n-NFSv4 '# NFSv4 client and RPC statistics'
_report :sar-n-NFSDv4 '# NFSv4 server and RPC statistics'
_report :sar-n-SOCK '# socket statistics'
_report :sar-n-TCP-ETCP '# TCP statistics'
_report :sar-q '# queue length and load averages'
_report :sar-r '# memory utilization statistics'
_report :sar-S '# swap usage statistics'
_report :sar-W '# swapping statistics'
_report :sar-w '# task creation and system switching statistics'
_report :sar-y '# TTY devices activity'
_report :numa-hint-faults '# NUMA hint fault statistics'
_report :numa-per-node-cpu '# NUMA per-node CPU statistics'
_report :numa-pgmigrate-per-node '# NUMA per-node page migration statistics'

$VERBOSE && echo "Report written to $REPORTFILE"

# optional end logging to $PCP_LOG_DIR/NOTICES
#
if $PCP_LOG_RC_SCRIPTS
then
    $PCP_BINADM_DIR/pmpost "end pid:$$ $prog status=$status"
fi

exit
