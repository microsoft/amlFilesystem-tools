#!/bin/bash
#
# Copyright (c) Microsoft Corporation. All rights reserved.
#

main() {
    privilege_mode=0
    while getopts "p" arg; do
        case $arg in
            p)
                privilege_mode=1
                ;;
            *)
                exit
                ;;
        esac
    done
    kubectl_exists=$(which kubectl)
    if [ ! "$kubectl_exists" ]
    then
        echo "This tool requires the kubectl command.  Cannot find kubectl in path."
        exit
    fi
    if [ "$privilege_mode" = 0 ] # not privilege mode
    then
        readarray -t nodes_array <<< "$(kubectl get nodes |grep -Ev ^NAME |awk '{print $1}')"
    else
        readarray -t nodes_array <<< "$(kubectl get pods -o wide |grep -Ev ^NAME |grep -E ^privileged- |awk '{print $1, $7}')"
    fi
    if [ "${nodes_array[0]}" ]
    then
        node_number=99
        while [ "$node_number" -ne 0 ]; do
            clear
            menu_number=1
            for aks_node_name in "${nodes_array[@]}"
            do
                echo "$menu_number. $aks_node_name"
                ((menu_number += 1))
            done
            ((menu_number-=1))
            echo
            node_number=0
            read -r -p "Enter number next to node 1..$menu_number - 0 (zero) to exit: " node_number
            if [ -n "$node_number" ] && [ "$node_number" -eq "$node_number" ] 2>/dev/null
            then
                if [ "$node_number" -gt 0 ] 
                then
                    array_index=$((node_number - 1))
                    if [ "${nodes_array[$array_index]}" ]
                    then
                        aks_node="${nodes_array[$array_index]}"
                        if [ "$privilege_mode" = 0 ] # not privilege mode
                        then
                            kubectl debug node/"${aks_node}" --image=ubuntu -it -- chroot /host /bin/bash
                        else
                            aks_pod=$(echo "$aks_node" |awk '{print $1}')
                            kubectl exec -it pod/"${aks_pod}" -- chroot /host /bin/bash
                        fi
                    fi
                fi
            else
                # At this point the menu choice is not numeric.
                # if the response starts with e or q (lower or upper case) it has the same effect as 0 (exit)
                node_number="${node_number,,}" # converts to lower case
                if [[ "$node_number" =~ ^e ]] || [[ "$node_number" =~ ^q ]]
                then
                    node_number=0
                else
                    node_number=99
                fi
            fi
        done
    else
        if [ "$privilege_mode" = 0 ]
        then
            echo "No nodes listed with kubectl get nodes command.  Consider re-running the aks-node-ssh.sh script."
        else
            echo "Running in privilege mode.  No debug pods listed with kubectl get pods command."
            echo "Make sure you have properly executed the 'kubectl apply -f privileged.yaml' command."
        fi
    fi
}
main "$@"
exit
