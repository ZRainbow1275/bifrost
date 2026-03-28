# =============================================================================
# AI Gateway Bridge - Caddy Configuration for Server B (Overseas)
#
# This Caddyfile configures Caddy on the overseas server:
#   1. Reverse proxy to 3x-ui management panel
#   2. Serve a decoy/camouflage website for non-panel traffic
#   3. Automatic TLS certificate management
#   4. Security headers and access logging
#
# Template variables:
#   {{DOMAIN}}      - Your overseas domain name (e.g., panel.example.com)
#   {{PANEL_PORT}}  - 3x-ui panel port (default: 2053)
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
# Main site: 3x-ui Panel + Decoy Website
# =============================================================================
{{DOMAIN}} {
	# --------------------------------------------------
	# TLS Configuration
	# --------------------------------------------------
	tls {
		protocols tls1.2 tls1.3
		ciphers TLS_ECDHE_ECDSA_WITH_AES_256_GCM_SHA384 TLS_ECDHE_RSA_WITH_AES_256_GCM_SHA384 TLS_ECDHE_ECDSA_WITH_CHACHA20_POLY1305_SHA256 TLS_ECDHE_RSA_WITH_CHACHA20_POLY1305_SHA256
	}

	# --------------------------------------------------
	# Security Headers
	# --------------------------------------------------
	header {
		# Prevent MIME type sniffing
		X-Content-Type-Options nosniff
		# Prevent clickjacking
		X-Frame-Options SAMEORIGIN
		# Enable XSS protection
		X-XSS-Protection "1; mode=block"
		# Referrer policy
		Referrer-Policy strict-origin-when-cross-origin
		# Permissions policy
		Permissions-Policy "camera=(), microphone=(), geolocation=(), payment=()"
		# HSTS
		Strict-Transport-Security "max-age=31536000; includeSubDomains; preload"
		# Remove server identification
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
	# 3x-ui Panel - Reverse Proxy
	# The panel path is configurable in 3x-ui settings.
	# Default: accessible at root or /xui/
	# --------------------------------------------------

	# 3x-ui panel routes
	handle /xui-panel/* {
		# IP whitelist for panel access (restrict to admin IPs)
		# Uncomment and modify to restrict access:
		# @allowed remote_ip 你的管理IP/32
		# handle @allowed {
		reverse_proxy localhost:{{PANEL_PORT}} {
			header_up X-Real-IP {remote_host}
			header_up X-Forwarded-For {remote_host}
			header_up X-Forwarded-Proto {scheme}
			header_up Host {host}

			transport http {
				dial_timeout 10s
				response_header_timeout 30s
			}
		}
		# }
		# respond "404 Not Found" 404
	}

	# 3x-ui API endpoints
	handle /server/* {
		reverse_proxy localhost:{{PANEL_PORT}} {
			header_up X-Real-IP {remote_host}
			header_up X-Forwarded-For {remote_host}
			header_up X-Forwarded-Proto {scheme}
			header_up Host {host}
		}
	}

	# 3x-ui login page
	handle /login {
		reverse_proxy localhost:{{PANEL_PORT}} {
			header_up X-Real-IP {remote_host}
			header_up X-Forwarded-For {remote_host}
			header_up X-Forwarded-Proto {scheme}
			header_up Host {host}
		}
	}

	# 3x-ui WebSocket support (for real-time updates)
	handle /ws/* {
		reverse_proxy localhost:{{PANEL_PORT}} {
			header_up X-Real-IP {remote_host}
			header_up X-Forwarded-For {remote_host}
			header_up X-Forwarded-Proto {scheme}
			header_up Host {host}
			header_up Connection {>Connection}
			header_up Upgrade {>Upgrade}
		}
	}

	# 3x-ui static assets
	handle /assets/* {
		reverse_proxy localhost:{{PANEL_PORT}} {
			header_up X-Real-IP {remote_host}
			header_up X-Forwarded-For {remote_host}
			header_up X-Forwarded-Proto {scheme}
			header_up Host {host}
		}
	}

	# --------------------------------------------------
	# Decoy Website - Static files for camouflage
	# Serves a legitimate-looking website for any path
	# not matched by the panel routes above.
	# --------------------------------------------------
	handle {
		root * /var/www/html
		file_server {
			index index.html
		}

		# Cache static assets
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
# HTTP to HTTPS redirect
# =============================================================================
http://{{DOMAIN}} {
	redir https://{{DOMAIN}}{uri} permanent
}
