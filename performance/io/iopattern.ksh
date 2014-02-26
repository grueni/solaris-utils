#!/usr/bin/ksh
#
# iopattern - print disk I/O pattern.
#             Written using DTrace (Solaris 10 3/05).
#
# This prints details on the I/O access pattern for the disks, such as
# percentage of events that were of a random or sequential nature.
# By default totals for all disks are printed.
#
# $Id: iopattern 65 2007-10-04 11:09:40Z brendan $
#
# USAGE:	iopattern [-rvw] [-d device] [-f filename] [-m mount_point] 
#			  [interval [count]]
#
#		       -r       	# only observe read operations
#		       -v       	# print timestamp, string
#		       -w       	# only observe write operations
#		       -d device	# instance name to snoop (eg, dad0)
#		       -f filename	# full pathname of file to snoop
#		       -m mount_point	# this FS only (will skip raw events)
#  eg,
#		iopattern   	# default output, 1 second intervals
#		iopattern 10  	# 10 second samples
#		iopattern 5 12	# print 12 x 5 second samples
#	        iopattern -m /  # snoop events on filesystem / only
# 	
# FIELDS:
#		%RAN  		percentage of events of a random nature
#		%SEQ 	 	percentage of events of a sequential nature
#		COUNT		number of I/O events
#		MIN		minimum I/O event size
#		MAX		maximum I/O event size
#		AVG		average I/O event size
#		KR		total kilobytes read during sample
#		KW		total kilobytes written during sample
#		DEVICE		device name
#		MOUNT		mount point
#		FILE		filename
#		TIME		timestamp, string
# 
# NOTES:
#
#  An event is considered random when the heads seek. This program prints
#  the percentage of events that are random. The size of the seek is not
#  measured - it's either random or not.
#
# SEE ALSO: iosnoop, iotop
# 
# IDEA: Ryan Matteson
#
# COPYRIGHT: Copyright (c) 2005 Brendan Gregg.
#
# CDDL HEADER START
#
#  The contents of this file are subject to the terms of the
#  Common Development and Distribution License, Version 1.0 only
#  (the "License").  You may not use this file except in compliance
#  with the License.
#
#  You can obtain a copy of the license at Docs/cddl1.txt
#  or http://www.opensolaris.org/os/licensing.
#  See the License for the specific language governing permissions
#  and limitations under the License.
#
# CDDL HEADER END
#
# Author: Brendan Gregg  [Sydney, Australia]
#
# 25-Jul-2005	Brendan Gregg	Created this.
# 25-Jul-2005	   "      "	Last update.
#  3-Oct-2008  Richard Elling  added read/write filters
#


##############################
# --- Process Arguments ---
#

### default variables
opt_device=0; opt_file=0; opt_mount=0; opt_time=0; opt_reads=0; opt_writes=0
filter=0; device=.; filename=.; mount=.; interval=1; count=-1

### process options
while getopts d:f:hm:rvw name
do
	case $name in
	d)	opt_device=1; device=$OPTARG ;;
	f)	opt_file=1; filename=$OPTARG ;;
	m)	opt_mount=1; mount=$OPTARG ;;
	r)	opt_reads=1; opt_writes=0 ;;
	v)	opt_time=1 ;;
	w)	opt_writes=1; opt_reads=0 ;;
	h|?)	cat <<-END >&2
		USAGE: iopattern [-rvw] [-d device] [-f filename] [-m mount_point]
		                 [interval [count]]
 
		                -r              # only observe read operations
		                -v              # print timestamp
		                -w              # only observe write operations
		                -d device       # instance name to snoop 
		                -f filename     # snoop this file only
		                -m mount_point  # this FS only 
		   eg,
		        iopattern         # default output, 1 second samples
		        iopattern 10      # 10 second samples
		        iopattern 5 12    # print 12 x 5 second samples
		        iopattern -m /    # snoop events on filesystem / only
		END
		exit 1
	esac
done

shift $(( $OPTIND - 1 ))

### option logic
if [[ "$1" > 0 ]]; then
        interval=$1; shift
fi
if [[ "$1" > 0 ]]; then
        count=$1; shift
fi
if (( opt_device || opt_mount || opt_file || opt_reads || opt_writes)); then
	filter=1
fi


#################################
# --- Main Program, DTrace ---
#
/usr/sbin/dtrace -n '
 /*
  * Command line arguments
  */
 inline int OPT_time 	= '$opt_time';
 inline int OPT_device 	= '$opt_device';
 inline int OPT_mount 	= '$opt_mount';
 inline int OPT_file 	= '$opt_file';
 inline int OPT_reads	= '$opt_reads';
 inline int OPT_writes	= '$opt_writes';
 inline int INTERVAL 	= '$interval';
 inline int COUNTER 	= '$count';
 inline int FILTER 	= '$filter';
 inline string DEVICE 	= "'$device'";
 inline string FILENAME = "'$filename'";
 inline string MOUNT 	= "'$mount'";
 
 #pragma D option quiet

 int last_loc[string];

 /*
  * Program start
  */
 dtrace:::BEGIN 
 {
        /* starting values */
	diskcnt = 0;
	diskmin = 0;
	diskmax = 0;
	diskran = 0;
	diskr = 0;
	diskw = 0;
        counts = COUNTER;
        secs = INTERVAL;
	LINES = 20;
	line = 0;
	last_event[""] = 0;
 }

 /*
  * Print header
  */
 profile:::tick-1sec
 /line <= 0 /
 {
	/* print optional headers */
	OPT_time   ? printf("%-20s ", "TIME")  : 1;
	OPT_device ? printf("%-9s ", "DEVICE") : 1;
	OPT_mount  ? printf("%-12s ", "MOUNT") : 1;
	OPT_file   ? printf("%-12s ", "FILE") : 1;

	/* print header */
	printf("%4s %4s %6s %6s %6s %6s ",
	    "%RAN", "%SEQ", "COUNT", "MIN", "MAX", "AVG");
	OPT_reads ? printf("%6s\n", "KR") : 1;
	OPT_writes ? printf("%6s\n", "KW") : 1;
	(!OPT_reads && !OPT_writes) ? printf("%6s %6s\n", "KR", "KW") : 1;

	line = LINES;
 }

 /*
  * Check event is being traced
  */
 io:genunix::done
 { 
	/* default is to trace unless filtering */
	self->ok = FILTER ? 0 : 1;

	/* check each filter */
	(OPT_device == 1 && DEVICE == args[1]->dev_statname)? self->ok = 1 : 1;
	(OPT_file == 1 && FILENAME == args[2]->fi_pathname) ? self->ok = 1 : 1;
	(OPT_mount == 1 && MOUNT == args[2]->fi_mount)  ? self->ok = 1 : 1;
	(OPT_reads == 1 && args[0]->b_flags & B_READ) ? self->ok = 1 : 1;
	(OPT_writes == 1 && !(args[0]->b_flags & B_READ)) ? self->ok = 1 : 1;
 }

 /*
  * Process and Print completion
  */
 io:genunix::done
 /self->ok/
 {
	/*
	 * Save details
	 */
	this->loc = args[0]->b_blkno * 512;
	this->pre = last_loc[args[1]->dev_statname];
	diskr += args[0]->b_flags & B_READ ? args[0]->b_bcount : 0;
	diskw += args[0]->b_flags & B_READ ? 0 : args[0]->b_bcount;
	diskran += this->pre == this->loc ? 0 : 1;
	diskcnt++;
	diskmin = diskmin == 0 ? args[0]->b_bcount :
	    (diskmin > args[0]->b_bcount ? args[0]->b_bcount : diskmin);
	diskmax = diskmax < args[0]->b_bcount ? args[0]->b_bcount : diskmax;

	/* save disk location */
	last_loc[args[1]->dev_statname] = this->loc + args[0]->b_bcount;

	/* cleanup */
	self->ok = 0;
 }

 /*
  * Timer
  */
 profile:::tick-1sec
 {
	secs--;
 }

 /*
  * Print Output
  */
 profile:::tick-1sec
 /secs == 0/
 {
	/* calculate diskavg */
	diskavg = diskcnt > 0 ? (diskr + diskw) / diskcnt : 0;

	/* convert counters to Kbytes */
	diskr /= 1024;
	diskw /= 1024;

	/* convert to percentages */
	diskran = diskcnt == 0 ? 0 : (diskran * 100) / diskcnt;
	diskseq = diskcnt == 0 ? 0 : 100 - diskran;

	/* print optional fields */
	OPT_time   ? printf("%-20Y ", walltimestamp) : 1;
	OPT_device ? printf("%-9s ", DEVICE) : 1;
	OPT_mount  ? printf("%-12s ", MOUNT) : 1;
	OPT_file   ? printf("%-12s ", FILENAME) : 1;

	/* print data */
	printf("%4d %4d %6d %6d %6d %6d ",
	    diskran, diskseq, diskcnt, diskmin, diskmax, diskavg);
	OPT_reads ? printf("%6d\n", diskr) : 1;
	OPT_writes ? printf("%6d\n", diskw) : 1;
	(!OPT_reads && !OPT_writes) ? printf("%6d %6d\n", diskr, diskw) : 1;

	/* clear data */
	diskmin = 0;
	diskmax = 0;
	diskcnt = 0;
	diskran = 0;
	diskr = 0;
	diskw = 0;

	secs = INTERVAL;
	counts--;
	line--;
 }

 /*
  * End of program
  */
 profile:::tick-1sec
 /counts == 0/
 {
	exit(0);
 }
'