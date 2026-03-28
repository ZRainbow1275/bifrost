{
  "log": {
    "loglevel": "warning",
    "access": "none",
    "error": "/var/log/xray/error.log"
  },
  "api": {
    "tag": "api",
    "services": [
      "StatsService"
    ]
  },
  "stats": {},
  "policy": {
    "levels": {
      "0": {
        "statsUserUplink": true,
        "statsUserDownlink": true,
        "handshake": 4,
        "connIdle": 300,
        "uplinkOnly": 2,
        "downlinkOnly": 5,
        "bufferSize": 4
      }
    },
    "system": {
      "statsInboundUplink": true,
      "statsInboundDownlink": true,
      "statsOutboundUplink": true,
      "statsOutboundDownlink": true
    }
  },
  "inbounds": [
    {
      "tag": "vless-reality-in",
      "port": {{PORT}},
      "listen": "0.0.0.0",
      "protocol": "vless",
      "settings": {
        "clients": [
          {
            "id": "{{UUID}}",
            "flow": "xtls-rprx-vision",
            "level": 0,
            "email": "ai-gateway-user@bridge.local"
          }
        ],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "tcp",
        "security": "reality",
        "realitySettings": {
          "show": false,
          "dest": "{{DEST}}",
          "xver": 0,
          "serverNames": [
            "{{SNI}}"
          ],
          "privateKey": "{{PRIVATE_KEY}}",
          "shortIds": [
            "{{SHORT_ID}}"
          ]
        }
      },
      "sniffing": {
        "enabled": true,
        "destOverride": [
          "http",
          "tls",
          "quic"
        ],
        "routeOnly": false
      }
    },
    {
      "tag": "api-in",
      "port": 10085,
      "listen": "127.0.0.1",
      "protocol": "dokodemo-door",
      "settings": {
        "address": "127.0.0.1"
      }
    }
  ],
  "outbounds": [
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
        "inboundTag": [
          "api-in"
        ],
        "outboundTag": "api",
        "comment": "Internal stats API"
      },
      {
        "type": "field",
        "outboundTag": "block",
        "comment": "Block ads on server side",
        "domain": [
          "geosite:category-ads-all"
        ]
      },
      {
        "type": "field",
        "outboundTag": "block",
        "comment": "Block streaming - Netflix",
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
        "comment": "Block streaming - YouTube and video",
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
        "comment": "Block streaming - Disney+, HBO, Hulu, Amazon Video",
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
        "comment": "Block streaming - Music services",
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
        "comment": "Block social media",
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
        "comment": "Block torrent/P2P",
        "protocol": [
          "bittorrent"
        ]
      },
      {
        "type": "field",
        "outboundTag": "direct",
        "comment": "Allow AI Services - Anthropic (Claude)",
        "domain": [
          "domain:anthropic.com",
          "domain:claude.ai"
        ]
      },
      {
        "type": "field",
        "outboundTag": "direct",
        "comment": "Allow AI Services - OpenAI",
        "domain": [
          "domain:openai.com"
        ]
      },
      {
        "type": "field",
        "outboundTag": "direct",
        "comment": "Allow AI Services - Google Gemini",
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
        "outboundTag": "direct",
        "comment": "Allow AI Services - DeepSeek",
        "domain": [
          "domain:deepseek.com"
        ]
      },
      {
        "type": "field",
        "outboundTag": "direct",
        "comment": "Allow AI Services - Mistral",
        "domain": [
          "domain:mistral.ai"
        ]
      },
      {
        "type": "field",
        "outboundTag": "direct",
        "comment": "Allow AI Services - Groq",
        "domain": [
          "domain:groq.com"
        ]
      },
      {
        "type": "field",
        "outboundTag": "direct",
        "comment": "Allow AI Services - GitHub / Copilot",
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
        "outboundTag": "direct",
        "comment": "Allow AI Services - Hugging Face",
        "domain": [
          "domain:huggingface.co"
        ]
      },
      {
        "type": "field",
        "outboundTag": "direct",
        "comment": "Allow AI Services - Cohere",
        "domain": [
          "domain:cohere.ai",
          "domain:cohere.com"
        ]
      },
      {
        "type": "field",
        "outboundTag": "direct",
        "comment": "Allow AI Services - Perplexity",
        "domain": [
          "domain:perplexity.ai"
        ]
      },
      {
        "type": "field",
        "outboundTag": "direct",
        "comment": "Allow AI Services - Together AI",
        "domain": [
          "domain:together.xyz",
          "domain:together.ai"
        ]
      },
      {
        "type": "field",
        "outboundTag": "direct",
        "comment": "Allow Package Registries",
        "domain": [
          "domain:npmjs.org",
          "domain:pypi.org",
          "domain:pythonhosted.org",
          "domain:crates.io"
        ]
      },
      {
        "type": "field",
        "outboundTag": "direct",
        "comment": "Allow Container Registries",
        "domain": [
          "domain:docker.io",
          "domain:docker.com",
          "domain:ghcr.io"
        ]
      },
      {
        "type": "field",
        "outboundTag": "direct",
        "comment": "Allow Error Tracking / Telemetry",
        "domain": [
          "domain:sentry.io",
          "full:statsig.anthropic.com"
        ]
      },
      {
        "type": "field",
        "outboundTag": "block",
        "comment": "Block everything else - strict whitelist mode",
        "port": "0-65535"
      }
    ]
  }
}
