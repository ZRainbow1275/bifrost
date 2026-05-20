#!/usr/sbin/nft -f
# ==============================================================================
# Bifrost - Server A strict nftables template for vpn-first profile.
# Rendered by scripts/security.sh:_setup_firewall_nftables to /etc/nftables.conf.
# ==============================================================================

flush ruleset

table inet bifrost {
    set ssh_admin_allow {
        type ipv4_addr
        flags interval
        elements = { {{ADMIN_RANGES}} }
    }

    chain input {
        type filter hook input priority filter; policy drop;

        iif "lo" accept
        ct state established,related accept
        ct state invalid drop counter

        ip protocol icmp limit rate 10/second accept
        ip6 nexthdr ipv6-icmp limit rate 10/second accept

        iifname "eth0" udp dport {{WG_PORT}} accept
        iifname "eth0" tcp dport {{SSH_PORT}} ip saddr @ssh_admin_allow \
            meter ssh_meter size 1024 { ip saddr limit rate 3/minute burst 3 packets } \
            accept

        iifname "wg0" accept
        counter log prefix "FW-DROP: " level warn limit rate 5/minute drop
    }

    chain forward {
        type filter hook forward priority filter; policy drop;
        iifname "wg0" ct state new,established,related accept
        oifname "wg0" ct state established,related accept
        counter drop
    }

    chain output {
        type filter hook output priority filter; policy accept;
    }

    chain postrouting {
        type nat hook postrouting priority srcnat;
        ip saddr 10.8.0.0/24 oifname "eth0" masquerade
    }
}
