This directory contains tools for troubleshooting Lustre on a client.

=== collect.bash usage:

For basic info collection:
* collect.bash (without arguments) gathers info for each Lustre mount point
* -m <mount_point without trailing "/"> (can be multiple) default to all Lustre mount points
* -l <log dir> default to "."
* -s <directory> (can be multiple) gets stripe information for each specified directory
* -d dump debug logs

For info collection via debug daemon:
* -D <debug log file> starts debug daemon
* -Q <debug log file> stops debug daemon with debug log file previously set with -D
* -M <debug mask> optional. examples: "+net", "-net", or "-1" for "start debug_daemon"
* -Z <size> debug log file size, default to unlimited for "start debug_daemon"

== gsi-client.sh usage:

Tool for collecintg information from a non-k8s lustre clients
* gsi-client.sh (without arguments) gathers info from each lustre client the script is run on.
* -l <log dir> defaults to "."
* -h display help info
*
* Information is gathered into a tarball file in the format: client-gsi-YYYY-MM-DDTHH-MM-SS.tgz

== aks-node-ssh.sh usage:

Tool to allow ease of access when using ssh to connect to an aks/k8s node
* Running the script will display a numbered list of the nodes - created from the output of kubectl get nodes
* Enter the number next to the aks node to initiate an ssh session
* Prompt reminds to enter "chroot /host /bin/bash" once connected to a node