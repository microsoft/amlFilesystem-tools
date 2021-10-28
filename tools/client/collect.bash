#!/bin/bash
#
# Copyright (c) Microsoft Corporation. All rights reserved.
#
# collect Lustre info for troubleshooting

set -u

usage() {
    less <<EOF
Usage ${0##*/} [options]
collect lustre info
    -d dump debug logs
    -l <log dir> default to "."
    -h usage
    -m <mount point without trailing "/"> (can be multiple) default to all Lustre mount points
    -s <dir> (for lfs getstripe, can be multiple)
    -v verbose
    -D <file> start debug_daemon with debug log file
    -Q <file> stop debug_daemon with debug log file previously set with -D
    -M <debug mask> optional. examples: "+net", "-net", or "-1" for "start debug_daemon"
    -Z <max size> debug log file size, default to unlimited for "start debug_daemon"
EOF
    exit
}

tar_file=

main() {
    # option vars
    debug_kernel_dump=
    log_dir="."
    mount_opts=()
    getstripe_dirs=()
    verbose=
    start_debug_daemon=
    stop_debug_daemon=
    debug_daemon_binary_file=
    debug_trace_mask=
    debug_file_size=

    # other vars
    log_file=
    debug_kernel_dump_file=
    debug_daemon_dump_file=

    while getopts "dhl:m:s:vD:M:Q:Z:" arg; do
        case $arg in
            d)
                debug_kernel_dump=1
                ;;
            h)
                usage
                ;;
            l)
                log_dir="$OPTARG"
                ;;
            m)
                mount_opts+=("$OPTARG")
                ;;
            s)
                getstripe_dirs+=("$OPTARG")
                ;;
            v)
                verbose=1
                ;;
            D)
                debug_daemon_binary_file=("$OPTARG")
                start_debug_daemon=1
                ;;
            M)
                debug_trace_mask=("$OPTARG")
                ;;
            Q)
                debug_daemon_binary_file=("$OPTARG")
                stop_debug_daemon=1
                ;;
            Z)
                debug_file_size=("$OPTARG")
                ;;
        esac
    done

    if [[ ! -d $log_dir ]] || [[ ! -w $log_dir ]]; then
        >&2 echo "ERROR: log directory $log_dir must exist and be writable"
        exit -1
    fi

    date_str=$(date --utc --iso-8601=seconds | cut -d'+' -f1 | sed "s/:/-/g")
    debug_daemon_dump_file="$log_dir/debug_daemon_dump.$date_str"
    debug_kernel_dump_file="$log_dir/debug_kernel_dump.$date_str"

    if [[ -n "$debug_kernel_dump" ]]; then
        echo "INFO: lctl dk > ${debug_kernel_dump_file}.gz"
        lctl dk > $debug_kernel_dump_file
        chmod o+r $debug_kernel_dump_file
        gzip $debug_kernel_dump_file
        exit
    fi

    if [[ -n "$start_debug_daemon" ]] && [[ -n "$stop_debug_daemon" ]]; then
        >&2 echo "ERROR: must have either start (-D) or stop (-Q) debug_daemon, not both"
        exit -1
    fi

    if [[ -n "$start_debug_daemon" ]]; then
        if [[ -n "$debug_trace_mask" ]]; then
            echo "INFO: lctl set_param debug=$debug_trace_mask"
            lctl set_param debug=$debug_trace_mask
        fi
        echo "INFO: start debug daemon. Log to binary file $debug_daemon_binary_file"
        lctl debug_daemon start $debug_daemon_binary_file $debug_file_size
        exit
    fi

    if [[ -n "$stop_debug_daemon" ]]; then
        if [[ ! -f $debug_daemon_binary_file ]]; then
            >&2 echo "ERROR: debug_daemon dump file $debug_daemon_binary_file must exist"
            exit -1
        fi
        echo "INFO: stop debug daemon. Log to ${debug_daemon_dump_file}.gz"
        lctl debug_daemon stop
        lctl df $debug_daemon_binary_file $debug_daemon_dump_file
        chmod o+r $debug_daemon_dump_file
        gzip $debug_daemon_dump_file
        exit
    fi

    log_file="$log_dir/collect_log.$date_str"
    touch $log_file
    chmod o+r $log_file

    # tar file with full path for packing files under /sys and /proc
    tar_file=$(realpath "$log_dir/all_in_one.$date_str.tar")
    # create tar file for adding other files later
    tar fc $tar_file -T /dev/null
    chmod o+r $tar_file

    if [[ -z $verbose ]]; then
        # stdout goes to log only.  stderr goes to console only.
        exec > $log_file
    else
        # stdout and stderr go to both console and log.
        exec > >(tee -i $log_file)
        exec 2>&1
    fi

    # get active mount points
    fs_names=$(lfs getname)
    if [[ -z $fs_names ]]; then
        if [[ ${#mount_opts[@]} -ne 0 ]]; then
            >&2 echo "ERROR: invalid or inactive mount point(s): ${mount_opts[@]}"
            exit 1
        else
            echo -e "INFO: no active mount points found\n"
            pack_info
            exit
        fi
    fi

    echo "INFO: mounted lustre fs names:"
    echo -e "${fs_names}\n"

    mounts=$(mount -t lustre)
    echo "INFO: lustre mounts:"
    echo -e "${mounts}\n"

    # mount_map[mount_point] is mount point uuid
    declare -A lfs_mounts=()
    while read -r line; do
        # "lfs getname": lustrefs-ffff939200113800 /lustre (the uuid is very useful)
        mount=$(echo $line | cut -d' ' -f2)
        lfs_mounts["$mount"]=$(echo $line | cut -d' ' -f1 | cut -d'-' -f2)
    done <<< "$fs_names"

    # if active lustre mount point is in the -m set, add to mount_map
    declare -A mount_map=()
    for mount in "${!lfs_mounts[@]}"; do
        for i in "${!mount_opts[@]}"; do
            if [[ "${mount_opts[i]}" = "${mount}" ]]; then
                mount_map["$mount"]="${lfs_mounts["$mount"]}"
                unset 'mount_opts[i]'
                break
            fi
        done
    done

    # what's left in mount_opts are invalid/inactive mount points
    if [[ ${#mount_opts[@]} -ne 0 ]]; then
        >&2 echo "ERROR: invalid or inactive mount point(s): ${mount_opts[@]}"
        exit -1
    fi

    # if no specified mount points, use all active mount points discovered
    if [[ ${#mount_map[@]} -eq 0 ]]; then
        for mount in "${!lfs_mounts[@]}"; do
            mount_map["$mount"]="${lfs_mounts["$mount"]}"
        done
        echo -e "====== Collect info for all active Lustre mount points =====\n"
    else
        echo -e "====== Collect info for user specified Lustre mount points =====\n"
    fi

    for mount in "${!mount_map[@]}"; do
        get_mount_info "$mount" "${mount_map["$mount"]}"
    done

    if [[ ${#getstripe_dirs[@]} -gt 0 ]]; then
        echo -e "====== Stripe info for user specified directories =====\n"
        for dir in "${getstripe_dirs[@]}"; do
            echo "INFO: lfs getstripe $dir:"
            lfs getstripe $dir
        done
    fi

    pack_info
}

# pack info with/without active mount points
pack_info() {
    # tar files under /sys/fs/lustre and /sys/fs/lustre/ldlm/services.
    # they are not associated to any mount point.
    # exclude jobid_this_session ("file not exist" with read op)
    file_list=()
    if [[ -d /sys/fs/lustre ]]; then
        lustre_files=$(cd / && find sys/fs/lustre -maxdepth 1 -type f | grep -v jobid_this_session)
        IFS=$'\n' read -d '' -a file_list <<< "$lustre_files"
    fi
    if [[ -d /sys/fs/lustre/ldlm/services ]]; then
        lustre_files=$(cd / && find sys/fs/lustre/ldlm/services -maxdepth 1 -type f)
        IFS=$'\n' read -d '' -a added_file_list <<< "$lustre_files"
        file_list+=("${added_file_list[@]}")
    fi

    echo -e "===== Tar ${#file_list[@]} system-wide files under /sys/fs/lustre =====\n"
    for file in "${file_list[@]}"; do
        (cd / && tar rf $tar_file --warning=no-file-shrank $file)
    done

    echo -e "===== Dump debug kernel log =====\n"
    echo -e "INFO: lctl dk > ${debug_kernel_dump_file}\n"
    lctl dk > $debug_kernel_dump_file
    chmod o+r $debug_kernel_dump_file
    tar rf $tar_file $debug_kernel_dump_file

    echo "===== Collected info packed in ${tar_file}.gz ====="
    tar rf $tar_file $log_file
    gzip $tar_file
}

# $1: mount point, $2: mount point uuid
get_mount_info() {
    mount_point=$1
    mount_uuid=$2

    echo -e "===== mount point $mount_point (uuid $mount_uuid) ======\n"

    lsof_output=$(lsof $mount_point 2>/dev/null)
    if [[ -z $lsof_output ]]; then
        echo -e "INFO: no open files on ${mount_point}\n"
    else
        echo "INFO: lsof ${mount_point}:"
        echo -e "${lsof_output}\n"

        # identify lsof header, then read processes
        start_procs=
        while read -r line; do
            line=$(echo $line | tr -s " ")
            if [[ -z $start_procs ]]; then
                # reg ex for header "COMMAND PID USER FD TYPE DEVICE SIZE/OFF NODE NAME"
                regex_str="COMMAND PID USER FD TYPE DEVICE SIZE/OFF NODE NAME"
                if [[ $line =~ $regex_str ]]; then
                    start_procs=1
                fi
            else
                # split "app 14647 azureuser cwd DIR 1296,295330 33280 144115188193296385 /lustre"
                proc_parts=(${line// / })
                proc="${proc_parts[1]}"
                uid=$(stat -c "%u" /proc/$proc)
                echo "INFO: lfs quota -u $uid ${mount_point}:"
                lfs quota -u $uid $mount_point
                echo
            fi
        done  <<< "$lsof_output"
    fi

    mount_uuid_ip_grep_str=$mount_uuid
    # "findmnt -D <mount>": 10.1.37.7@tcp:/lustre lustre  7.5G  65M  7.4G   1% /mnt/lustre
    mount_ip=$(findmnt -D $mount_point | sed -n 2p | cut -d " " -f1 | cut -d ":" -f1)
    if [[ -z $mount_ip ]]; then
        echo -e "WARNING: cannot find mount ip -> may not tar stat files on the paths containing mount ip\n"
    else
        mount_uuid_ip_grep_str="${mount_uuid_ip_grep_str}|${mount_ip}"
    fi

    nids=($(lctl list_nids $mount_point))
    for nid in "${nids[@]}"; do
        echo "INFO: lctl ping $nid ${mount_point}:"
        lctl ping $nid $mount_point
        echo
    done

    echo "INFO: lfs check all for ${mount_point}:"
    lfs_check_all_output=$(lfs check all)
    if [[ -z $lfs_check_all_output ]]; then
        echo -e "WARNING: no output from lfs check all\n"
    else
        egrep "${mount_uuid_ip_grep_str}" <<< $lfs_check_all_output
        echo
    fi

    echo "INFO: lfs df ${mount_point}:"
    lfs df -h $mount_point

    echo "INFO: lctl dl for ${mount_point}:"
    lctl_dl_output=$(lctl dl)
    if [[ -z $lctl_dl_output ]]; then
        echo -e "WARNING: no output from lclt dl\n"
    else
        egrep "${mount_uuid_ip_grep_str}" <<< $lctl_dl_output
        echo
    fi

    # tar /sys/fs/lustre/... and maybe /proc/fs/lustre/... at root "/"
    # to avoid warning "removing leading slash"
    # /proc/fs/lustre will be deprecated per lustre plan.
    tar_dirs=("sys/fs/lustre" "proc/fs/lustre")
    for dir in "${tar_dirs[@]}"; do
        if [[ -d /$dir ]]; then
            file_list=()

            # files associated with the mount uuid or mount ip, like
            # /sys/fs/lustre/lmv/lustre-clilmv-ffff9dadfbc6e800/qos_maxage or
            # /sys/fs/lustre/ldlm/namespaces/MGC10.1.37.7@tcp/pool/cancel_rate.
            # exclude idle_connect files under /sys/fs/lustre (not readable)
            lustre_files=$(cd / && find $dir -type f ! -name idle_connect | egrep $mount_uuid_ip_grep_str)
            IFS=$'\n' read -d '' -a file_list <<< "$lustre_files"

            echo -e "INFO: tar ${#file_list[@]} files under /${dir} for ${mount_point}\n"
            for file in "${file_list[@]}"; do
                (cd / && tar rf $tar_file --warning=no-file-shrank $file)
            done
        fi
    done
}

main "$@"
exit
