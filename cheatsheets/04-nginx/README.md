# NGINX Cheat Sheet

Reverse proxy, TLS, rate limiting, caching, headers, tuning, ingress-nginx.

---

## 1. Where NGINX sits

In this platform NGINX is the **edge reverse proxy / ingress**: TLS termination,
host and path routing, security headers, crude per-IP rate limiting, request
size caps, and canary traffic splitting. It does **not** do authentication —
that belongs to the API gateway one layer in (see
[docs/13-edge-gateway.md](../../docs/13-edge-gateway.md)). Two layers both
validating JWTs will drift, and one will start accepting what the other rejects.

---

## 2. Operations

```bash
nginx -t                      # validate config — ALWAYS before reload
nginx -T                      # dump the FULL resolved config (all includes)
nginx -s reload               # graceful: new workers for new conns, old drain
nginx -s quit                 # graceful stop      (-s stop = immediate)
nginx -V 2>&1 | tr ' ' '\n' | grep -- --with   # compiled-in modules

systemctl reload nginx        # wraps nginx -s reload
journalctl -u nginx -f

# where is time going
tail -f /var/log/nginx/access.log | jq -r '"\(.status) \(.rt) \(.uri)"'
awk '{print $9}' access.log | sort | uniq -c | sort -rn      # status distribution
ss -ant | awk '{print $1}' | sort | uniq -c                  # conn states
```

**Reload is graceful; restart is not.** Reload forks new workers with the new
config and lets old ones finish in-flight requests. A restart drops connections.
Never edit config and restart "to be sure".

---

## 3. Config skeleton

```nginx
user  nginx;
worker_processes  auto;              # = number of cores
worker_rlimit_nofile 65535;

events {
    worker_connections 8192;         # max conns per worker (client + upstream!)
    multi_accept on;
}

http {
    include       /etc/nginx/mime.types;
    default_type  application/octet-stream;

    # ---- logging: JSON, so the log platform doesn't need a grok pattern ----
    log_format json escape=json '{'
      '"ts":"$time_iso8601","remote":"$remote_addr","xff":"$http_x_forwarded_for",'
      '"method":"$request_method","uri":"$uri","status":$status,'
      '"bytes":$body_bytes_sent,"rt":$request_time,"urt":"$upstream_response_time",'
      '"ua":"$http_user_agent","host":"$host","rid":"$request_id"}';
    access_log /var/log/nginx/access.log json;
    error_log  /var/log/nginx/error.log warn;

    # ---- performance ----
    sendfile on;  tcp_nopush on;  tcp_nodelay on;
    keepalive_timeout 65;
    server_tokens off;               # stop advertising the version

    # ---- limits: the cheap DoS protections ----
    client_max_body_size 10m;
    client_body_timeout 10s;
    client_header_timeout 10s;
    send_timeout 10s;
    large_client_header_buffers 4 16k;

    # ---- shared zones (define once, use per server) ----
    limit_req_zone  $binary_remote_addr zone=perip:10m  rate=20r/s;
    limit_conn_zone $binary_remote_addr zone=conns:10m;

    gzip on;
    gzip_types application/json application/javascript text/css text/plain;
    gzip_min_length 1024;
    # gzip_proxied any;  ← careful: compressing responses with secrets + reflection = BREACH

    include /etc/nginx/conf.d/*.conf;
}
```

### A server block worth copying

```nginx
upstream api_backend {
    zone api 64k;
    least_conn;                       # or default round-robin; ip_hash for stickiness
    server 10.20.1.11:8080 max_fails=3 fail_timeout=10s;
    server 10.20.1.12:8080 max_fails=3 fail_timeout=10s;
    server 10.20.1.13:8080 backup;
    keepalive 64;                     # ← upstream keepalive pool: big latency win
    keepalive_timeout 60s;
}

server { listen 80 default_server; return 444; }        # drop unknown Host

server {
    listen 80;
    server_name api.bank.internal;
    return 301 https://$host$request_uri;
}

server {
    listen 443 ssl;
    http2 on;
    server_name api.bank.internal;

    ssl_certificate     /etc/nginx/tls/api.crt;
    ssl_certificate_key /etc/nginx/tls/api.key;
    ssl_protocols       TLSv1.2 TLSv1.3;
    ssl_ciphers         ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-GCM-SHA384;
    ssl_prefer_server_ciphers off;      # TLS1.3: let the client choose
    ssl_session_cache   shared:SSL:10m;
    ssl_session_tickets off;            # tickets weaken forward secrecy unless rotated
    ssl_stapling on;  ssl_stapling_verify on;

    # ---- security headers ----
    add_header Strict-Transport-Security "max-age=63072000; includeSubDomains" always;
    add_header X-Content-Type-Options    "nosniff" always;
    add_header X-Frame-Options           "DENY" always;
    add_header Referrer-Policy           "strict-origin-when-cross-origin" always;
    add_header Content-Security-Policy   "default-src 'none'; frame-ancestors 'none'" always;

    limit_req  zone=perip burst=40 nodelay;
    limit_conn conns 50;

    location /healthz { access_log off; return 200 "ok\n"; }

    location / {
        proxy_pass http://api_backend;
        proxy_http_version 1.1;
        proxy_set_header Connection "";            # ← required for upstream keepalive
        proxy_set_header Host              $host;
        proxy_set_header X-Real-IP         $remote_addr;
        proxy_set_header X-Forwarded-For   $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_set_header X-Request-Id      $request_id;

        proxy_connect_timeout 3s;
        proxy_send_timeout    30s;
        proxy_read_timeout    30s;

        proxy_next_upstream error timeout http_502 http_503;
        proxy_next_upstream_tries 2;
        # For non-idempotent endpoints (payments) retries are UNSAFE:
        #   proxy_next_upstream off;
    }
}
```

---

## 4. The rules that matter

| Rule | Why |
|---|---|
| `nginx -t` before every reload, and `validate:` in Ansible | One bad line takes down every site on the box |
| `proxy_pass http://up;` vs `http://up/;` — the trailing slash | With a slash, the matched `location` prefix is **stripped**. `/api/v1/x` → `/v1/x`. The #1 NGINX routing bug |
| `add_header` in a `location` **replaces** all inherited headers | Repeat the security headers in any location that adds one, or use `include headers.conf` |
| Always `always` on security headers | Without it they're skipped on 4xx/5xx responses |
| `keepalive` + `proxy_http_version 1.1` + `Connection ""` | Otherwise every upstream request opens a new TCP+TLS connection |
| Trust `X-Forwarded-For` only from known proxies | Use `real_ip_module` with `set_real_ip_from`; otherwise clients spoof their IP and defeat your rate limit |
| Regex locations are evaluated in order; `=` and `^~` short-circuit | Match precedence: `=` → `^~` → regex (in file order) → longest prefix |
| Variables in `proxy_pass` force runtime DNS resolution | `resolver 10.0.0.10 valid=30s;` — this is how you avoid caching a dead pod IP forever |
| `if` is evil (in `location` context) | Only `return` and `rewrite … last` are safe inside `if`. Use `map` instead |

`map` is the idiomatic conditional:
```nginx
map $http_x_canary $upstream_pool {
    default  "api_stable";
    "true"   "api_canary";
}
```

---

## 5. Rate limiting, caching, canary

```nginx
# leaky bucket: rate is the drain, burst is the bucket, nodelay serves the burst now
limit_req_zone $binary_remote_addr zone=perip:10m rate=20r/s;
limit_req zone=perip burst=40 nodelay;
limit_req_status 429;
limit_req_log_level warn;

# by API key instead of IP (behind a CDN, IP is useless)
limit_req_zone $http_x_api_key zone=perkey:10m rate=100r/s;
```
10m of zone ≈ 160k IPv4 entries. When the zone is full, NGINX starts evicting —
and silently under-enforcing.

```nginx
proxy_cache_path /var/cache/nginx levels=1:2 keys_zone=api:100m
                 max_size=10g inactive=60m use_temp_path=off;

location /catalog/ {
    proxy_cache api;
    proxy_cache_key "$scheme$request_method$host$request_uri";
    proxy_cache_valid 200 5m;
    proxy_cache_valid 404 30s;
    proxy_cache_use_stale error timeout updating http_500 http_502 http_503;
    proxy_cache_background_update on;
    proxy_cache_lock on;                 # collapse a stampede into one origin request
    add_header X-Cache-Status $upstream_cache_status always;
    proxy_pass http://api_backend;
}
```
`use_stale` + `background_update` is how a cache turns an origin outage into
slightly stale data instead of a 502. Never cache authenticated responses without
including the identity in `proxy_cache_key` — that's how one user gets another
user's balance.

Weighted canary:
```nginx
split_clients "${request_id}" $pool {
    5%      api_canary;
    *       api_stable;
}
location / { proxy_pass http://$pool; }
```

---

## 6. ingress-nginx (Kubernetes)

```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: api
  annotations:
    nginx.ingress.kubernetes.io/proxy-body-size: "10m"
    nginx.ingress.kubernetes.io/limit-rps: "20"
    nginx.ingress.kubernetes.io/ssl-redirect: "true"
    nginx.ingress.kubernetes.io/backend-protocol: "HTTPS"   # re-encrypt to the pod
    nginx.ingress.kubernetes.io/canary: "true"              # on the canary Ingress
    nginx.ingress.kubernetes.io/canary-weight: "5"
spec:
  ingressClassName: nginx
  tls: [{ hosts: [api.bank.internal], secretName: api-tls }]
  rules:
    - host: api.bank.internal
      http:
        paths:
          - path: /
            pathType: Prefix
            backend: { service: { name: api, port: { number: 80 } } }
```

Notes:
- `allow-snippet-annotations: false` in the controller ConfigMap _(regulated)_ —
  arbitrary `configuration-snippet` from any namespace is remote config injection
  into your edge (CVE-2021-25742 family).
- Canary Ingress must be a **separate** Ingress object with the same host/path.
- The controller reloads NGINX on every change; heavy churn plus huge configs
  causes reload storms — watch `nginx_ingress_controller_config_last_reload_successful`.
- Gateway API is the successor. New clusters should prefer it; the annotation
  surface is exactly the portability problem it fixes.

---

## 7. Tuning and observability

```nginx
location = /stub_status { stub_status; allow 10.20.0.0/16; deny all; }
```
Feed it to Prometheus with `nginx-prometheus-exporter`, or use the
`vts`/`njs` modules for per-upstream metrics.

Golden signals from the access log: `status` (error rate), `request_time` (total
latency), `upstream_response_time` (backend latency). The gap between the last
two is *your* overhead — TLS handshakes, queuing, buffering to disk.

| Symptom | Look at |
|---|---|
| 502 Bad Gateway | Upstream refused/died. `error_log`, upstream health, wrong port |
| 504 Gateway Timeout | `proxy_read_timeout` < backend duration, or backend hung |
| 499 | *Client* closed the connection first — usually your latency, or an aggressive client timeout |
| 413 | `client_max_body_size` |
| 400 on big headers | `large_client_header_buffers` |
| "worker_connections are not enough" | Raise `worker_connections`; remember each proxied request uses **two** |
| `upstream_response_time` fine but `request_time` huge | Slow client, or response buffering to disk (`proxy_buffers`) |
| Random 502s under load | Upstream keepalive misconfigured, or ephemeral port exhaustion |

---

## 8. Best practices checklist

- [ ] Config in Git, rendered by Ansible with `validate: nginx -t -c %s`
- [ ] `nginx -T` output diffed in review — includes hide surprises
- [ ] TLS 1.2+ only, modern ciphers, HSTS with `always`, OCSP stapling
- [ ] Certificates from cert-manager/ACME or a Vault PKI role — never a manual file
- [ ] `server_tokens off`, default server returns 444 for unknown Host
- [ ] Body size, header size, and all four timeouts explicitly set
- [ ] Rate limit per IP at the edge; per-consumer limits live at the gateway
- [ ] `real_ip_module` configured so XFF is trusted only from the CDN/LB range
- [ ] Retries **off** for non-idempotent routes (payments)
- [ ] JSON access logs shipped to the log platform; PII/token fields excluded
- [ ] `stub_status` scraped; reload success and 5xx rate alerted on
- [ ] No auth logic here — it lives at the API gateway

➡ [Interview Q&A](interview-qna.md)
