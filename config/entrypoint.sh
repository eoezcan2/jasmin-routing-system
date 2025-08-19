#!/bin/bash
set -e

echo "Starting Jasmin with custom configs..."
exec /usr/bin/jasmin.py -u jcli -c /etc/jasmin/jasmin.cfg
