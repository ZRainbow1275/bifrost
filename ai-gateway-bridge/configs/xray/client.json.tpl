{
  "log": {
    "loglevel": "warning",
    "access": "none",
    "error": "/var/log/xray/error.log"
  },
  "dns": {
    "servers": [
      {
        "address": "https+local://1.1.1.1/dns-query",
        "domains": [
          "geosite:category-ads-all"
        ],
        "expectIPs": []
      },
      {
        "address": "223.5.5.5",
        "port": 53,
        "domains": [
          "geosite:cn",
          "geosite:private"
        ]
      },
      {
        "address": "https+local://8.8.8.8/dns-query",
        "domains": [
          "domain:anthropic.com",
          "domain:openai.com",
          "domain:googleapis.com",
          "domain:google.dev",
          "domain:deepseek.com",
          "domain:mistral.ai",
          "domain:groq.com",
          "domain:github.com",
          "domain:githubusercontent.com",
          "domain:huggingface.co",
          "domain:cohere.ai",
          "domain:cohere.com",
          "domain:perplexity.ai",
          "domain:together.xyz",
          "domain:together.ai",
          "domain:npmjs.org",
          "domain:pypi.org",
          "domain:pythonhosted.org",
          "domain:crates.io",
          "domain:docker.io",
          "domain:docker.com",
          "domain:ghcr.io",
          "domain:sentry.io"
        ]
      },
      "localhost"
    ],
    "queryStrategy": "UseIPv4"
  },
  "inbounds": [
    {
      "tag": "socks-in",
      "port": 10808,
      "listen": "127.0.0.1",
      "protocol": "socks",
      "settings": {
        "auth": "noauth",
        "udp": true,
        "ip": "127.0.0.1"
      },
      "sniffing": {
        "enabled": true,
        "destOverride": [
          "http",
          "tls",
          "quic"
        ],
        "routeOnly": true
      }
    },
    {
      "tag": "http-in",
      "port": 10809,
      "listen": "127.0.0.1",
      "protocol": "http",
      "settings": {
        "allowTransparent": false
      },
      "sniffing": {
        "enabled": true,
        "destOverride": [
          "http",
          "tls",
          "quic"
        ],
        "routeOnly": true
      }
    }
  ],
  "outbounds": [
    {
      "tag": "proxy",
      "protocol": "vless",
      "settings": {
        "vnext": [
          {
            "address": "{{SERVER_B_IP}}",
            "port": {{SERVER_B_PORT}},
            "users": [
              {
                "id": "{{SERVER_B_UUID}}",
                "encryption": "none",
                "flow": "xtls-rprx-vision"
              }
            ]
          }
        ]
      },
      "streamSettings": {
        "network": "tcp",
        "security": "reality",
        "realitySettings": {
          "show": false,
          "fingerprint": "chrome",
          "serverName": "{{SERVER_B_SNI}}",
          "publicKey": "{{SERVER_B_PUBKEY}}",
          "shortId": "{{SERVER_B_SHORT_ID}}",
          "spiderX": ""
        }
      }
    },
    {
      "tag": "direct",
      "protocol": "freedom",
      "settings": {
        "domainStrategy": "UseIPv4"
      }
    },
    {
      "tag": "block",
      "protocol": "blackhole",
      "settings": {
        "response": {
          "type": "http"
        }
      }
    }
  ],
  "routing": {
    "domainStrategy": "IPIfNonMatch",
    "domainMatcher": "hybrid",
    "rules": [
      {
        "type": "field",
        "inboundTag": ["socks-in"],
        "outboundTag": "proxy",
        "comment": "Trust Mihomo routing: all traffic from SOCKS5 inbound goes to proxy. Mihomo has already made the routing decision (AI -> proxy, CN -> direct, blocked -> reject). This rule MUST be first to prevent the catch-all block rule from dropping Mihomo-routed traffic for domains not explicitly listed in Xray routing."
      },
      {
        "type": "field",
        "outboundTag": "block",
        "comment": "Block ads",
        "domain": [
          "geosite:category-ads-all"
        ]
      },
      {
        "type": "field",
        "outboundTag": "block",
        "comment": "Block streaming services - Netflix",
        "domain": [
          "domain:netflix.com",
          "domain:netflix.net",
          "domain:nflxvideo.net",
          "domain:nflxso.net",
          "domain:nflxext.com",
          "domain:nflximg.net"
        ]
      },
      {
        "type": "field",
        "outboundTag": "block",
        "comment": "Block streaming services - YouTube and video platforms",
        "domain": [
          "domain:youtube.com",
          "domain:youtu.be",
          "domain:googlevideo.com",
          "domain:ytimg.com",
          "domain:yt3.ggpht.com",
          "domain:twitch.tv",
          "domain:ttvnw.net",
          "domain:jtvnw.net"
        ]
      },
      {
        "type": "field",
        "outboundTag": "block",
        "comment": "Block streaming services - Disney+, HBO, Hulu, Amazon Video",
        "domain": [
          "domain:disneyplus.com",
          "domain:disney-plus.net",
          "domain:bamgrid.com",
          "domain:dssott.com",
          "domain:hbo.com",
          "domain:hbonow.com",
          "domain:hbomax.com",
          "domain:hulu.com",
          "domain:hulustream.com",
          "domain:primevideo.com",
          "domain:amazonvideo.com"
        ]
      },
      {
        "type": "field",
        "outboundTag": "block",
        "comment": "Block streaming services - Spotify and music",
        "domain": [
          "domain:spotify.com",
          "domain:spotifycdn.com",
          "domain:scdn.co",
          "domain:tidal.com",
          "domain:tidalhifi.com"
        ]
      },
      {
        "type": "field",
        "outboundTag": "block",
        "comment": "Block social media and other non-work sites",
        "domain": [
          "domain:tiktok.com",
          "domain:tiktokv.com",
          "domain:musical.ly",
          "domain:instagram.com",
          "domain:cdninstagram.com",
          "domain:facebook.com",
          "domain:fbcdn.net",
          "domain:twitter.com",
          "domain:x.com",
          "domain:twimg.com",
          "domain:reddit.com",
          "domain:redd.it",
          "domain:redditstatic.com",
          "domain:pornhub.com",
          "domain:xvideos.com",
          "domain:xhamster.com"
        ]
      },
      {
        "type": "field",
        "outboundTag": "block",
        "comment": "Block torrent and P2P protocols",
        "protocol": [
          "bittorrent"
        ]
      },
      {
        "type": "field",
        "outboundTag": "proxy",
        "comment": "AI Services - Anthropic (Claude)",
        "domain": [
          "domain:anthropic.com",
          "domain:claude.ai"
        ]
      },
      {
        "type": "field",
        "outboundTag": "proxy",
        "comment": "AI Services - OpenAI",
        "domain": [
          "domain:openai.com"
        ]
      },
      {
        "type": "field",
        "outboundTag": "proxy",
        "comment": "AI Services - Google Gemini",
        "domain": [
          "full:generativelanguage.googleapis.com",
          "full:aistudio.google.com",
          "full:ai.google.dev",
          "full:alkalimakersuite-pa.clients6.google.com",
          "full:makersuite-pa.googleapis.com"
        ]
      },
      {
        "type": "field",
        "outboundTag": "proxy",
        "comment": "AI Services - DeepSeek",
        "domain": [
          "domain:deepseek.com"
        ]
      },
      {
        "type": "field",
        "outboundTag": "proxy",
        "comment": "AI Services - Mistral",
        "domain": [
          "domain:mistral.ai"
        ]
      },
      {
        "type": "field",
        "outboundTag": "proxy",
        "comment": "AI Services - Groq",
        "domain": [
          "domain:groq.com"
        ]
      },
      {
        "type": "field",
        "outboundTag": "proxy",
        "comment": "AI Services - GitHub / Copilot",
        "domain": [
          "domain:github.com",
          "domain:githubusercontent.com",
          "domain:githubcopilot.com",
          "full:copilot.github.com",
          "full:default.exp-tas.com"
        ]
      },
      {
        "type": "field",
        "outboundTag": "proxy",
        "comment": "AI Services - Hugging Face",
        "domain": [
          "domain:huggingface.co"
        ]
      },
      {
        "type": "field",
        "outboundTag": "proxy",
        "comment": "AI Services - Cohere",
        "domain": [
          "domain:cohere.ai",
          "domain:cohere.com"
        ]
      },
      {
        "type": "field",
        "outboundTag": "proxy",
        "comment": "AI Services - Perplexity",
        "domain": [
          "domain:perplexity.ai"
        ]
      },
      {
        "type": "field",
        "outboundTag": "proxy",
        "comment": "AI Services - Together AI",
        "domain": [
          "domain:together.xyz",
          "domain:together.ai"
        ]
      },
      {
        "type": "field",
        "outboundTag": "proxy",
        "comment": "Package Registries",
        "domain": [
          "domain:npmjs.org",
          "domain:pypi.org",
          "domain:pythonhosted.org",
          "domain:crates.io"
        ]
      },
      {
        "type": "field",
        "outboundTag": "proxy",
        "comment": "Container Registries",
        "domain": [
          "domain:docker.io",
          "domain:docker.com",
          "domain:ghcr.io"
        ]
      },
      {
        "type": "field",
        "outboundTag": "proxy",
        "comment": "Error Tracking / Telemetry for AI tools",
        "domain": [
          "domain:sentry.io",
          "domain:statsig.anthropic.com"
        ]
      },
      {
        "type": "field",
        "outboundTag": "direct",
        "comment": "Direct access for Chinese sites",
        "domain": [
          "geosite:cn",
          "geosite:private"
        ]
      },
      {
        "type": "field",
        "outboundTag": "direct",
        "comment": "Direct access for Chinese IPs",
        "ip": [
          "geoip:cn",
          "geoip:private"
        ]
      },
      {
        "type": "field",
        "outboundTag": "block",
        "comment": "Block everything else - whitelist mode",
        "port": "0-65535"
      }
    ]
  }
}
