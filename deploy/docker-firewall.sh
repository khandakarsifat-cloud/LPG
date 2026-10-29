#!/bin/sh
# Preserve the host ingress guard; permit only the Caddy host publications.
set -eu
test -d /sys/class/net/eth0
for firewall in iptables ip6tables; do
  "$firewall" -w -N DOCKER-USER 2>/dev/null || "$firewall" -w -S DOCKER-USER >/dev/null
  "$firewall" -w -C DOCKER-USER -i eth0 -m conntrack ! --ctstate ESTABLISHED,RELATED -m comment --comment lpg-block-public-container-ingress -j DROP 2>/dev/null || \
    "$firewall" -w -I DOCKER-USER 1 -i eth0 -m conntrack ! --ctstate ESTABLISHED,RELATED -m comment --comment lpg-block-public-container-ingress -j DROP
  if [ "$firewall" = iptables ]; then
    for port in 80 443; do
      "$firewall" -w -C DOCKER-USER -i eth0 -p tcp -m conntrack --ctorigdst 144.79.249.4 --ctorigdstport "$port" -m comment --comment lpg-caddy-public -j RETURN 2>/dev/null || \
        "$firewall" -w -I DOCKER-USER 1 -i eth0 -p tcp -m conntrack --ctorigdst 144.79.249.4 --ctorigdstport "$port" -m comment --comment lpg-caddy-public -j RETURN
    done
  fi
  "$firewall" -w -C FORWARD -j DOCKER-USER 2>/dev/null || "$firewall" -w -I FORWARD 1 -j DOCKER-USER
done
