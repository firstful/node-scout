FROM alpine:3.20
RUN apk add --no-cache bash curl jq util-linux nftables
COPY scout.sh /scout.sh
COPY gatekeeper.sh /gatekeeper.sh
RUN chmod +x /scout.sh /gatekeeper.sh
ENTRYPOINT ["/scout.sh"]
