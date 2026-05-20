# =============================================================================
# Bifrost - Caddy Configuration for Server A (China / Domestic)
#
# This Caddyfile configures Caddy as a reverse proxy on the domestic server:
#   1. Reverse proxy to New API gateway (Docker container)
#   2. Serve a decoy/camouflage website for non-API traffic
#   3. Automatic TLS certificate management for domains, explicit Cloudflare
#      Origin CA files, or Certbot-managed certificate files for IP HTTPS mode
#   4. Security headers and access logging
#
# Contract note:
#   This template is a parity fixture checked by tests/test-in-docker.sh.
#   Runtime deployment may still render branch-specific inline Caddyfiles in
#   scripts/server-a.sh, so salient routes/headers here must stay in sync.
#
# Template variables:
#   {{DOMAIN}}               - Your domain name (e.g., gateway.example.com)
#   {{NEW_API_PORT}}         - New API container port (default: 3000)
#   {{ADMIN_ALLOWED_RANGES}} - VPN/private/admin CIDR allowlist for vpn-first
#   {{ACME_WEBROOT}}         - Webroot for Let's Encrypt HTTP-01 renewal in IP mode
#   {{TLS_CERT_FILE}}        - IP certificate fullchain path in IP mode
#   {{TLS_KEY_FILE}}         - IP certificate private key path in IP mode
#   {{CLOUDFLARE_ORIGIN_CERT_FILE}} - Cloudflare Origin CA certificate path
#   {{CLOUDFLARE_ORIGIN_KEY_FILE}}  - Cloudflare Origin CA private key path
#   {{BIND_ADDRESS}}         - Optional wg0 bind address for vpn-first (10.8.0.1)
#
# Place the rendered file at: /etc/caddy/Caddyfile
# =============================================================================

# Global options
{
	# Email for ACME TLS certificate notifications
	email admin@{{DOMAIN}}

	# Use HTTP/2 and HTTP/3 (QUIC) for better performance
	servers {
		protocols h1 h2 h2c h3
	}

	# Logging configuration
	log {
		output file /var/log/caddy/caddy.log {
			roll_size 100MiB
			roll_keep 5
			roll_keep_for 720h
		}
		level INFO
	}
}

# =============================================================================
# Main site: API Gateway + Decoy Website
# =============================================================================
{{DOMAIN}} {
	# vpn-first runtime rendering adds: bind 10.8.0.1
	# --------------------------------------------------
	# TLS Configuration
	# --------------------------------------------------
	tls {
		protocols tls1.2 tls1.3
		ciphers TLS_ECDHE_ECDSA_WITH_AES_256_GCM_SHA384 TLS_ECDHE_RSA_WITH_AES_256_GCM_SHA384 TLS_ECDHE_ECDSA_WITH_CHACHA20_POLY1305_SHA256 TLS_ECDHE_RSA_WITH_CHACHA20_POLY1305_SHA256
	}
	# IP HTTPS mode uses Certbot 5.4+ and Let's Encrypt short-lived IP certs:
	# tls {{TLS_CERT_FILE}} {{TLS_KEY_FILE}} {
	# 	protocols tls1.2 tls1.3
	# 	ciphers TLS_ECDHE_ECDSA_WITH_AES_256_GCM_SHA384 TLS_ECDHE_RSA_WITH_AES_256_GCM_SHA384 TLS_ECDHE_ECDSA_WITH_CHACHA20_POLY1305_SHA256 TLS_ECDHE_RSA_WITH_CHACHA20_POLY1305_SHA256
	# }
	# Cloudflare Origin CA mode requires Cloudflare DNS proxy + Full (strict):
	# tls {{CLOUDFLARE_ORIGIN_CERT_FILE}} {{CLOUDFLARE_ORIGIN_KEY_FILE}} {
	# 	protocols tls1.2 tls1.3
	# 	ciphers TLS_ECDHE_ECDSA_WITH_AES_256_GCM_SHA384 TLS_ECDHE_RSA_WITH_AES_256_GCM_SHA384 TLS_ECDHE_ECDSA_WITH_CHACHA20_POLY1305_SHA256 TLS_ECDHE_RSA_WITH_CHACHA20_POLY1305_SHA256
	# }
	# Internal CA mode (BIFROST_SERVER_A_TLS_MODE=internal, vpn-first recommended):
	# tls internal {
	# 	protocols tls1.2 tls1.3
	# }

	# --------------------------------------------------
	# Security Headers
	# Applied to all responses
	# --------------------------------------------------
	header {
		# Prevent MIME type sniffing
		X-Content-Type-Options nosniff
		# Prevent clickjacking
		X-Frame-Options DENY
		# Enable XSS protection
		X-XSS-Protection "1; mode=block"
		# Referrer policy - send origin only on cross-origin requests
		Referrer-Policy strict-origin-when-cross-origin
		# Permissions policy - restrict browser features
		Permissions-Policy "camera=(), microphone=(), geolocation=(), payment=()"
		# HSTS - enforce HTTPS for 1 year including subdomains
		Strict-Transport-Security "max-age=31536000; includeSubDomains; preload"
		# Remove server identification header
		-Server
		-X-Powered-By
	}

	# --------------------------------------------------
	# Access Logging
	# Structured JSON logs for fail2ban integration
	# --------------------------------------------------
	log {
		output file /var/log/caddy/access.log {
			roll_size 50MiB
			roll_keep 10
			roll_keep_for 720h
		}
		format json
	}

	# --------------------------------------------------
	# API Routes - Reverse Proxy to New API
	# vpn-first fixture: public /v1/* and /api/status only; management is allowlisted.
	# --------------------------------------------------

	# OpenAI-compatible API endpoints
	handle /v1/* {
		reverse_proxy localhost:{{NEW_API_PORT}} {
			# Pass original client IP
			header_up X-Real-IP {remote_host}
			header_up X-Forwarded-For {remote_host}
			header_up X-Forwarded-Proto {scheme}
			header_up Host {host}

			# Timeouts for long-running AI requests (streaming responses)
			transport http {
				dial_timeout 30s
				response_header_timeout 300s
				read_timeout 600s
				write_timeout 600s
			}

			# Health check for upstream
			health_uri /api/status
			health_interval 30s
			health_timeout 10s
		}
	}

	# Public readiness endpoint
	handle /api/status {
		reverse_proxy localhost:{{NEW_API_PORT}} {
			header_up X-Real-IP {remote_host}
			header_up X-Forwarded-For {remote_host}
			header_up X-Forwarded-Proto {scheme}
			header_up Host {host}

			transport http {
				dial_timeout 10s
				response_header_timeout 60s
			}
		}
	}

	# New API management interface and dashboard (VPN/private/admin allowlist only)
	@newapi_private {
		path /api/* /static/* /logo.png /dashboard /dashboard/* /login /panel /token /user/* /admin/*
		remote_ip {{ADMIN_ALLOWED_RANGES}}
	}
	handle @newapi_private {
		reverse_proxy localhost:{{NEW_API_PORT}} {
			header_up X-Real-IP {remote_host}
			header_up X-Forwarded-For {remote_host}
			header_up X-Forwarded-Proto {scheme}
			header_up Host {host}
		}
	}
	handle /api/* {
		respond "Bifrost admin API requires VPN/private access in vpn-first profile" 403
	}
	handle /static/* {
		respond "New API static assets require VPN/private access in vpn-first profile" 403
	}
	handle /logo.png {
		respond "New API static assets require VPN/private access in vpn-first profile" 403
	}
	handle /dashboard {
		respond "New API dashboard requires VPN/private access in vpn-first profile" 403
	}
	handle /dashboard/* {
		respond "New API dashboard requires VPN/private access in vpn-first profile" 403
	}
	handle /login {
		respond "New API login requires VPN/private access in vpn-first profile" 403
	}

	# --------------------------------------------------
	# Bifrost Management API
	# Proxies /manage/* to the Bifrost API service (port 8000).
	# vpn-first requires VPN/private/admin allowlist access.
	# --------------------------------------------------
	@manage_private_root {
		path /manage
		remote_ip {{ADMIN_ALLOWED_RANGES}}
	}
	handle @manage_private_root {
		redir /manage/ 308
	}
	@manage_private {
		path /manage/*
		remote_ip {{ADMIN_ALLOWED_RANGES}}
	}
	handle @manage_private {
		uri strip_prefix /manage
		reverse_proxy 127.0.0.1:8000 {
			header_up Host {host}
			header_up X-Real-IP {remote_host}
			header_up X-Forwarded-For {remote_host}
			header_up X-Forwarded-Proto {scheme}
			header_up X-Forwarded-Prefix /manage

			transport http {
				dial_timeout 10s
				response_header_timeout 60s
			}
		}
	}
	handle /manage {
		respond "Bifrost management requires VPN/private access in vpn-first profile" 403
	}
	handle /manage/* {
		respond "Bifrost management requires VPN/private access in vpn-first profile" 403
	}

	# --------------------------------------------------
	# Decoy Website - Static files for camouflage
	# Serves a legitimate-looking company website for
	# any path not matched by the API routes above.
	# --------------------------------------------------
	handle {
		root * /var/www/html
		file_server {
			# Enable directory listing only if index.html exists
			index index.html
		}

		# Cache static assets for the decoy site
		@static path *.css *.js *.png *.jpg *.jpeg *.gif *.svg *.ico *.woff *.woff2
		header @static Cache-Control "public, max-age=86400"
	}

	# --------------------------------------------------
	# Error handling
	# --------------------------------------------------
	handle_errors {
		respond "{err.status_code} {err.status_text}" {err.status_code}
	}
}

# =============================================================================
# Server B private distribution endpoints
# =============================================================================
(server_b_proxy) {
	reverse_proxy {args[0]} {
		header_up Host {host}
		header_up X-Forwarded-Proto https
		header_up X-Real-IP {client_ip}
		lb_try_duration 2s
		fail_duration 30s
	}
}

api.{{DOMAIN}} {
	tls {{TLS_CERT_FILE}} {{TLS_KEY_FILE}}
	encode gzip
	import server_b_proxy http://10.8.0.2:3000
}

npm.{{DOMAIN}} {
	tls {{TLS_CERT_FILE}} {{TLS_KEY_FILE}}
	encode gzip
	handle {
		request_body {
			max_size 100MB
		}
		import server_b_proxy http://10.8.0.2:4873
	}
}

files.{{DOMAIN}} {
	tls {{TLS_CERT_FILE}} {{TLS_KEY_FILE}}
	encode gzip
	@git path /git/*
	handle @git {
		import server_b_proxy http://10.8.0.2:8082
	}
	handle {
		import server_b_proxy http://10.8.0.2:8081
	}
}

panel.{{DOMAIN}} {
	tls {{TLS_CERT_FILE}} {{TLS_KEY_FILE}}
	encode gzip

	@panel_private {
		remote_ip {{ADMIN_ALLOWED_RANGES}}
	}
	@panel_public {
		not remote_ip {{ADMIN_ALLOWED_RANGES}}
	}
	handle @panel_public {
		respond "Bifrost marketplace panel requires VPN/private access in vpn-first profile" 403
	}
	handle @panel_private {
		@api_or_marketplace path /api/* /marketplace/*
		handle @api_or_marketplace {
			reverse_proxy 127.0.0.1:8000 {
				header_up X-Real-IP {remote_host}
				header_up X-Forwarded-For {remote_host}
				header_up X-Forwarded-Proto {scheme}
				header_up Host {host}
				transport http {
					dial_timeout 5s
					response_header_timeout 30s
				}
			}
		}
		handle {
			root * /var/www/bifrost-api-web/dist
			try_files {path} /index.html
			file_server
			@assets path /assets/*
			header @assets Cache-Control "public, max-age=31536000, immutable"
		}
	}
}

# =============================================================================
# HTTP to HTTPS redirect (automatic with Caddy, but explicit for clarity)
# =============================================================================
http://{{DOMAIN}} {
	handle /.well-known/acme-challenge/* {
		root * {{ACME_WEBROOT}}
		file_server
	}
	handle {
		redir https://{{DOMAIN}}{uri} permanent
	}
}
