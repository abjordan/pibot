#!/bin/sh
set -eu

: "${PI_BASE_URL:?PI_BASE_URL is not set}"

# We run as the unprivileged `squid` user (see Dockerfile), so the generated ACL
# files go somewhere we can actually write -- not /etc/squid.
ACL_DIR=/var/lib/squid/acl

# http://192.168.1.50:8080/v1  ->  192.168.1.50
host="${PI_BASE_URL#*://}"   # strip scheme
host="${host%%/*}"           # strip path
host="${host##*@}"           # strip any user:pass@
host="${host%%:*}"           # strip port

# Placeholders keep both acl files non-empty; squid treats an empty acl as fatal.
# 127.0.0.255 and .invalid are guaranteed never to match real traffic.
echo "127.0.0.255/32" > "${ACL_DIR}/inference-ip.txt"
echo ".invalid"       > "${ACL_DIR}/inference-dom.txt"

case "${host}" in
    *[!0-9.]*)
        # Contains something other than digits and dots: treat it as a hostname.
        echo "${host}" > "${ACL_DIR}/inference-dom.txt"
        echo "proxy: allowing inference host by name: ${host}" >&2
        ;;
    *)
        echo "${host}/32" > "${ACL_DIR}/inference-ip.txt"
        echo "proxy: allowing inference host by address: ${host}" >&2
        ;;
esac

squid -k parse -f /etc/squid/squid.conf

# -N keeps squid in the foreground. It is also load-bearing for logging: without
# it squid daemonizes and there is no stdout left to write to.
exec squid -N -f /etc/squid/squid.conf
