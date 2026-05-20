{
    admin off
    auto_https off
    servers {
        protocols h1 h2
    }
}

{{SERVER_B_WG_IP}}:8081 {
    # spec.md §3.3: cache-friendly handler for marketplace status sidecar files.
    # marketplace.json itself is NEVER served from /var/lib/dist (C1 fix — clients
    # consume it from inside the bare git tree via :8082 smart-HTTP). Only the
    # render state.json and emergency LICENSE.md / NOTICE.md copies live here.
    @plugins_status path /plugins/state.json /plugins/LICENSE.md /plugins/NOTICE.md
    handle @plugins_status {
        root * /var/lib/dist
        file_server
        header Cache-Control "no-cache, must-revalidate"
        header ETag "{file.modtime_unix}-{file.size}"
    }

    root * /var/lib/dist
    file_server browse
    encode gzip
    log {
        output file /var/log/caddy/files.log {
            roll_size 50mb
            roll_keep 7
        }
    }
}

{{SERVER_B_WG_IP}}:8082 {
    @receive_pack {
        method POST
        path */git-receive-pack
    }
    handle @receive_pack {
        respond "git push disabled on mirror" 403
    }

    handle_path /git/* {
        reverse_proxy unix//run/fcgiwrap.socket {
            transport fastcgi {
                env GIT_HTTP_EXPORT_ALL true
                env GIT_PROJECT_ROOT /var/lib/git-mirrors
                env PATH_INFO {http.request.uri.path}
                env SCRIPT_NAME ""
                env SCRIPT_FILENAME /usr/lib/git-core/git-http-backend
                env QUERY_STRING {http.request.uri.query}
                env CONTENT_TYPE {http.request.header.Content-Type}
                env CONTENT_LENGTH {http.request.header.Content-Length}
                env REMOTE_ADDR {client_ip}
            }
        }
    }
}
