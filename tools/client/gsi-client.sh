#!/bin/bash
# Copyright (c) Microsoft Corporation. All rights reserved.
#
# collect Lustre info for troubleshooting


usage() {
    less <<EOF
Usage ${0##*/} [options]
collect lustre info
    -l <log dir> starting dir for client-gsi-<date/time> dir.  Default to $HOME
    -h usage
EOF
    exit
}

main() {
    logdir=$HOME
	while getopts "dhl:m:s:vD:M:Q:Z:" arg; do
        case $arg in
            h)
                usage
                ;;
            l)
                logdir="$OPTARG"
                ;;
        esac
    done
	prerequisites_met=1
	if [[ ! -d $logdir ]] || [[ ! -w $logdir ]]; then
        >&2 echo "ERROR: log directory $logdir must exist and be writable"
        # exit -1
		prerequisites_met=0
    fi
	sudo_works=`sudo -n uptime 2>&1 | grep "load" | wc -l`
	if [ $sudo_works == 0 ]; then
		>&2 echo "ERROR: sudo access is required to run gsi-client.sh"
		prerequisites_met=0
	fi
	lfs_exists=`which lfs`
	lctl_exists=`which lctl`
	lnetctl_exists=`which lnetctl`
	# echo "lfs: " $lfs_exists "lctl: " $lctl_exists "lnetctl: " $lnetctl_exists
	if ! ([ $lfs_exists ] || [ $lctl_exists ] || [ $lnetctl_exists ]); then
		echo "not a lustre client"
		prerequisites_met=0
	else
		echo "Yes, Luster client!"
	fi

	if [ $prerequisites_met == 1 ]; then
		clientgsidir="client-gsi-$(date +"%FT%T")"
		echo $clientgsidir
		cd $logdir
		mkdir $clientgsidir
		cd $clientgsidir
		echo $(date +"%FT%T"): "Starting gsi_client.sh cpature." > gsi_client.log
		echo $(date +"%FT%T"): "client gsi dir: " $clientgsidir >> gsi_client.log
		command_divider "uname -a"
		uname -a |tee uname_a >> gsi_client.log
		if [ -f /etc/lsb-release ]
		then
				command_divider "cat /etc/lsb-release"
				cat /etc/lsb-release |tee lsb-release >> gsi_client.log
		fi
		if [ -f /etc/redhat-release ]
		then
			command_divider "cat /etc/redhat-release"
			cat /etc/redhat-release |tee redhat-release >> gsi_client.log
		fi
		command_divider "uptime; uptime -p"
		uptime |tee uptime >> gsi_client.log; uptime -p |tee -a uptime >> gsi_client.log
		command_divider "netstat -rn"
		netstat -rn |tee netstat_rn >> gsi_client.log
		command_divider "netstat -Wan"
		netstat -Wan > netstat_Wan
		command_divider "ifconfig -a"
		ifconfig -a 2>&1 |tee ifconfig_a >> gsi_client.log
		command_divider "printenv"
		printenv |tee printenv >> gsi_client.log

		if [ -f /usr/bin/lfs ]
		then
			command_divider "lfs --version"
			lfs --version |tee lfs_version >> gsi_client.log
			command_divider "lfs df -h"
			lfs df -h |tee lfs_df >> gsi_client.log
			command_divider "lfs check all"
			lfs check all 2>&1 |tee lfs_check_all >> gsi_client.log
		fi

		if [ -f /var/log/syslog ]
		then
			cd /var/log
			command_divider "cd /var/log; tail -30 syslog"
			tail -30 syslog |tee >> ~/$clientgsidir/gsi_client.log
			command_divider "cd /var/log; tar cvfz ~/$clientgsidir/syslog.tgz syslog*"
			tar cvfz ~/$clientgsidir/syslog.tgz syslog* >> ~/$clientgsidir/gsi_client.log
			cd ~/$clientgsidir
		fi
		if [ -f /var/log/messages ]
		then
			cd /var/log
			command_divider "cd /var/log; sudo tail -30 messages"
			sudo tail -30 messages |tee >> ~/$clientgsidir/gsi_client.log
			command_divider "cd /var/log; sudo tar cvfz ~/$clientgsidir/messages.tgz messages*"
			sudo tar cvfz ~/$clientgsidir/messages.tgz messages* >> ~/$clientgsidir/gsi_client.log
			cd ~/$clientgsidir
		fi		

		command_divider "sudo dmesg -T"
		sudo dmesg -T > dmesg
		command_divider "sudo sysctl -a"
		sudo sysctl -a > sysctl
		command_divider "sudo lnetctl stats show"
		sudo lnetctl stats show |tee lnetctl_stats >> gsi_client.log
		command_divider "sudo lctl dl -t"
		sudo lctl dl -t |tee lctl_dl >> gsi_client.log
		command_divider "mount |egrep lustre; mount"
		mount |egrep lustre |tee mount >> gsi_client.log; mount >> mount
		if [ -f /etc/fstab ]
		then
			command_divider "cat /etc/fstab |egrep lustre; cat /etc/fstab"
			cat /etc/fstab |egrep lustre |tee fstab >> gsi_client.log; cat /etc/fstab |tee -a fstab >> gsi_client.log
		else
			command_divider "No /etc/fstab file."
		fi

		local_lustre_mount=`mount |egrep "type lustre" |awk '{print $3}' |tail -1`
		if [ $local_lustre_mount ]
		then
			for read_ahead_kb in `ls /sys/devices/virtual/bdi/lustrefs-*/read_ahead_kb`
			do
					command_divider "cat $read_ahead_kb"
					echo -n "$read_ahead_kb: " >> read_ahead_kb
				cat $read_ahead_kb |tee -a read_ahead_kb >> gsi_client.log
			done
		fi

		if [ $read_ahead_kb ]
		then
			echo "Further analysis required if read_ahead_kb is > 0" >> gsi_client.log
		else
			command_divider "client does not contain a value for lustrefs read_ahead_kb.  All good."
		fi

		if [ $local_lustre_mount ]
		then
			for local_lustre_mount in `mount |egrep "type lustre" |awk '{print $3}'`
			do 
				command_divider "find $local_lustre_mount -type f -print0 |xargs -0 -n 1 lfs  hsm_state"
				hsm_state_file=`echo "hsm_state"$local_lustre_mount |sed 's/\//_/g'`
				echo $local_lustre_mount |tee $hsm_state_file >> gsi_client.log
				find $local_lustre_mount -type f -print0 |xargs -0 -n 1 lfs hsm_state >> $hsm_state_file
				number_of_files=`wc -l $hsm_state_file`
				echo "Number of files: $number_of_files" |tee -a $hsm_state_file >> gsi_client.log

			done
		else
			command_divider "Cannot find local lustre mount point.  Unable to display hsm_state."
		fi
		pwd; whoami
		chmod 666 *
		cd ..
		gsi_compressed=`echo $clientgsidir.tgz |sed 's/:/-/g'`
		tar cvfz $gsi_compressed $clientgsidir/ >/dev/null
	fi
	}

command_divider()
{
    echo $(date +"%FT%T"): " " >>  $logdir/$clientgsidir/gsi_client.log
    echo $(date +"%FT%T"): "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~" >>  $logdir/$clientgsidir/gsi_client.log
	echo $(date +"%FT%T"): "command: ${*}" >>  $logdir/$clientgsidir/gsi_client.log
	echo $(date +"%FT%T"): " " >>  $logdir/$clientgsidir/gsi_client.log
}

main "$@"
exit