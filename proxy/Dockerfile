FROM alpine:3.20

RUN apk add --no-cache squid

COPY squid.conf /etc/squid/squid.conf
COPY entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh

# Squid reopens its log files by path *after* dropping privileges. On Linux,
# /dev/stdout is a symlink into /proc/self/fd, and the kernel denies a process
# access to its own /proc/self/fd once it has changed uid -- so a root-started
# squid can never reopen the container's stdout. chmod does not help.
#
# The way out is to never change uid: start the container as `squid`, so squid
# sees it is not root and skips the setuid entirely.
RUN mkdir -p /var/lib/squid/acl \
    && chown -R squid:squid /var/lib/squid

USER squid

EXPOSE 3128
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
