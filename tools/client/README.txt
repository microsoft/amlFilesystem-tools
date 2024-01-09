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

Another tool for collecint information from a lustre client.
* 