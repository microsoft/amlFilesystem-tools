#!/bin/bash
#
# Copyright (c) Microsoft Corporation. All rights reserved.
#

main() {
    readarray -t nodes_array <<< "$(kubectl get nodes |grep -Ev ^NAME |awk '{print $1}')"
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
                        echo "Once connected to node $aks_node enter chroot /host /bin/bash"
                        kubectl debug node/"${aks_node}" --image=ubuntu -it
                    fi
                fi
            else
                # At this point the menu choice is not numeric.
                # if the response starts with e (lower or upper case) it has the same effect as 0 (exit)
                node_number="${node_number,,}" # converts to lower case
                if [[ "$node_number" =~ ^e ]]
                then
                    node_number=0
                else
                    node_number=99
                fi
            fi
        done
    else
        echo "No nodes listed with kubectl get nodes command.  Consider re-running the aks-node-ssh.sh script."
    fi
}
main "$@"
exit
