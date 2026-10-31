#!/usr/bin/env sh
# Run this on the k3s server, as root. It starts two small pods in the demo
# namespace, one outside it, and shows that traffic really goes through the
# mesh: both meshed pods get a sidecar, the client reaches the server, and
# with mutual TLS required a pod outside the mesh can't. Delete the namespaces
# afterwards if you want them gone: it reuses them when run again.
set -eu
k() { k3s kubectl "$@"; }
image=ghcr.io/stefanprodan/podinfo:6.17.0

k create namespace outside --dry-run=client -o yaml | k apply -f - >/dev/null
k apply -f - >/dev/null <<YAML
apiVersion: apps/v1
kind: Deployment
metadata: { name: server, namespace: demo }
spec:
  selector: { matchLabels: { app: server } }
  template:
    metadata: { labels: { app: server } }
    spec:
      containers:
        - { name: server, image: $image, ports: [{ containerPort: 9898 }] }
---
apiVersion: v1
kind: Service
metadata: { name: server, namespace: demo }
spec:
  selector: { app: server }
  ports: [{ name: http, port: 9898 }]
---
apiVersion: apps/v1
kind: Deployment
metadata: { name: client, namespace: demo }
spec:
  selector: { matchLabels: { app: client } }
  template:
    metadata: { labels: { app: client } }
    spec:
      containers:
        - { name: client, image: $image, command: [sleep, "86400"] }
---
apiVersion: apps/v1
kind: Deployment
metadata: { name: client, namespace: outside }
spec:
  selector: { matchLabels: { app: client } }
  template:
    metadata: { labels: { app: client } }
    spec:
      containers:
        - { name: client, image: $image, command: [sleep, "86400"] }
---
apiVersion: security.istio.io/v1
kind: PeerAuthentication
metadata: { name: default, namespace: demo }
spec:
  mtls: { mode: STRICT }
YAML
for d in demo/server demo/client outside/client; do
  k -n "${d%/*}" rollout status "deploy/${d#*/}" --timeout=5m >/dev/null
done

for d in server client; do
  # With native sidecars, istio-proxy is an init container, not a container.
  k -n demo get pod -l "app=$d" -o jsonpath='{.items[0].spec.containers[*].name} {.items[0].spec.initContainers[*].name}' | grep -qw istio-proxy \
    || { echo "demo/$d has no istio-proxy sidecar" >&2; exit 1; }
  echo "sidecar: demo/$d"
done

url=http://server.demo.svc.cluster.local:9898/
headers=
for _ in $(seq 30); do
  headers=$(k -n demo exec deploy/client -c client -- curl -s --max-time 5 -o /dev/null -D - "$url" || true)
  echo "$headers" | grep -q '^HTTP/1.1 200' && break
  sleep 5
done
echo "$headers" | grep -q '^HTTP/1.1 200' || { echo "demo/client got no 200 from the server: $headers" >&2; exit 1; }
# Envoy adds this header to a request it routed, and nothing else would.
echo "$headers" | grep -qi '^x-envoy-upstream-service-time' || { echo "The answer did not come through Envoy: $headers" >&2; exit 1; }
echo "meshed client to server: 200, through Envoy"

code=200
for _ in $(seq 12); do
  code=$(k -n outside exec deploy/client -- curl -s --max-time 5 -o /dev/null -w '%{http_code}' "$url" || true)
  [ "$code" != 200 ] && break
  sleep 5
done
[ "$code" != 200 ] || { echo "A pod outside the mesh still reached the server, so mutual TLS isn't in force" >&2; exit 1; }
echo "client outside the mesh: refused"
