#!/usr/sbin/nft -f

table inet filter {
    set wg_clients_v4 {
        type ipv4_addr
        flags interval
        elements = { {{WG_CLIENTS_CIDR}} }
    }

    set ssh_pubnet_allow_v4 {
        type ipv4_addr
        flags interval
        elements = { {{SSH_PUBNET_ALLOW_CIDRS}} }
    }

    chain input {
        type filter hook input priority 0; policy drop;

        ct state established,related accept
        iif "lo" accept
        ip protocol icmp accept
        meta l4proto ipv6-icmp accept

        udp dport {{WG_PORT}} accept

        iifname "wg0" tcp dport 22 accept
        ip saddr @ssh_pubnet_allow_v4 tcp dport 22 accept

        iifname "wg0" tcp dport { 3000, 4873, 8081, 8082 } accept
        iifname != "wg0" tcp dport { 3000, 4873, 8081, 8082 } drop
    }
}
