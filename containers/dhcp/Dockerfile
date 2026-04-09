FROM alpine:3.19

RUN apk add --no-cache dnsmasq

COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

VOLUME ["/var/lib/misc"]

ENTRYPOINT ["/entrypoint.sh"]
