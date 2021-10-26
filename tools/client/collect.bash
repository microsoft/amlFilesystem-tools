#!/bin/bash
#
# Copyright (c) Microsoft Corporation. All rights reserved.
#
# collect Lustre info for troubleshooting

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
    debug_file_size=""

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

    date_str=$(date | tr -s " " | sed "s/ /-/g" | sed "s/:/-/g")
    debug_daemon_dump_file="$log_dir/debug_daemon_dump.$date_str"
    debug_kernel_dump_file="$log_dir/debug_kernel_dump.$date_str"

    if [[ -n "$debug_kernel_dump" ]]; then
        echo "INFO lctl dk > ${debug_kernel_dump_file}.gz"
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
            echo "INFO lctl set_param debug=$debug_trace_mask"
            lctl set_param debug=$debug_trace_mask
        fi
        echo "INFO start debug daemon. Log to binary file $debug_daemon_binary_file"
        lctl debug_daemon start $debug_daemon_binary_file $debug_file_size
        exit
    fi

    if [[ -n "$stop_debug_daemon" ]]; then
        if [[ ! -f $debug_daemon_binary_file ]]; then
            >&2 echo "ERROR: debug_daemon dump file $debug_daemon_binary_file must exist"
            exit -1
        fi
        echo "INOF stop debug daemon. Log to ${debug_daemon_dump_file}.gz"
        lctl debug_daemon stop
        lctl df $debug_daemon_binary_file $debug_daemon_dump_file
        gzip $debug_daemon_dump_file
        chmod o+r ${debug_daemon_dump_file}.gz
        exit
    fi

    log_file="$log_dir/collect_log.$date_str"
    tar_file="$log_dir/all_in_one.$date_str.tar"
    touch $log_file
    chmod o+r $log_file

    if [[ -z $verbose ]]; then
        # stdout goes to log only.  stderr goes to console only.
        exec > $log_file
    else
        # stdout and stderr go to both console and log.
        exec > >(tee -i $log_file)
        exec 2>&1
    fi

    # create tar file for adding other files later
    tar fc $tar_file -T /dev/null
    chmod o+r $tar_file

    # get mounted mount points
    fs_names=$(lfs getname)
    echo "INFO mounted lustre fs names:"
    echo "$fs_names"
    echo

    mounts=$(mount -t lustre)
    echo "INFO lustre mounts:"
    echo "$mounts"
    echo

    # mount_map[mount_point] is mount point uuid
    declare -A lfs_mounts
    while read -r line; do
        # "lfs getname": lustrefs-ffff939200113800 /lustre (the uuid is very useful)
        fs_parts=(${line// / })
        fs_uuid="${fs_parts[0]}"
        mount="${fs_parts[1]}"
        fs_uuid_parts=(${fs_uuid//-/ })
        uuid="${fs_uuid_parts[1]}"
        lfs_mounts["$mount"]=$uuid
    done <<< "$fs_names"

    # if active lustre mount point is in the -m set, add to mount_map
    declare -A mount_map
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
        >&2 echo "ERROR: mount points ${mount_opts[@]} are invalid or not mounted"
        exit -1
    fi

    # if no specified mount points, use all active mount points discovered
    if [[ ${#mount_map[@]} -eq 0 ]]; then
        for mount in "${!lfs_mounts[@]}"; do
            mount_map["$mount"]="${lfs_mounts["$mount"]}"
        done
        echo "====== Collect info for all active Lustre mount points ====="
    else
        echo "====== Collect info for user specified Lustre mount points ====="
    fi
    echo

    for mount in "${!mount_map[@]}"; do
        get_mount_info "$mount" "${mount_map["$mount"]}"
    done

    if [[ ${#getstripe_dirs[@]} -gt 0 ]]; then
        echo "====== Stripe info for user specified directories ====="
        echo

        for dir in "${getstripe_dirs[@]}"; do
            echo "INFO lfs getstripe $dir:"
            lfs getstripe $dir
        done
    fi

    echo "====== Dump debug kernel log ====="
    echo
    echo "INFO lctl dk > $debug_kernel_dump_file"
    lctl dk > $debug_kernel_dump_file
    chmod o+r $debug_kernel_dump_file
    tar rf $tar_file $debug_kernel_dump_file
    echo

    echo "===== Collected info packed in ${tar_file}.gz ====="
    tar rf $tar_file $log_file
    gzip $tar_file
}

# $1: mount point, $2: mount point uuid
get_mount_info() {
    mount_point=$1
    mount_uuid=$2

    echo "===== mount point $mount_point (uuid $mount_uuid) ======"
    echo

    lsof_output=$(lsof $mount_point 2>/dev/null)
    echo "INFO lsof ${mount_point}:"
    echo "$lsof_output"
    echo

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
            echo "INFO lfs quota -u $uid ${mount_point}:"
            lfs quota -u $uid $mount_point
            echo "$quota"
        fi
    done  <<< "$lsof_output"

    echo "INFO lfs check all for ${mount_point}:"
    lfs check all | grep $mount_uuid
    echo

    echo "INFO lfs df ${mount_point}:"
    lfs df -h $mount_point
    echo

    echo "INFO lctl dl for ${mount_point}:"
    lctl dl | grep $mount_uuid
    echo

    nid=$(lctl list_nids $mount_point)
    echo "INFO lctl ping $nid ${mount_point}:"
    lctl ping $nid $mount_point
    echo

    # tar /proc/fs/lustre/... in place to avoid warning "removing leading slash"
    tar_file_full_path=$(realpath $tar_file)
    pushd /proc/fs > /dev/null
    file_list=()
    proc_fs_lustre_files=$(find lustre/ -type f | grep $mount_uuid)
    IFS=$'\n' read -d '' -a file_list <<< "$proc_fs_lustre_files"
    echo "INFO tar following files user /proc/fs:"
    echo "$proc_fs_lustre_files"
    echo
    for file in "${file_list[@]}"; do
        tar rf $tar_file_full_path $file
    done
    popd > /dev/null
}

main "$@"
exit
