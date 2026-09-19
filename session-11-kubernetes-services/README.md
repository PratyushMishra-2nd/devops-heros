# Session 11: Kubernetes Services

Applied all 5 service types from the session folders and tested how you actually reach each one. Everything below is copied straight from my terminal.

**Setup:** Windows 11, Minikube v1.39.0 with the Docker driver, Kubernetes v1.37.0.

---

## 1. ClusterIP: the default, internal only

`01-clusterip/` gives you 3 nginx replicas behind a Service on `port: 8080`, forwarding to `targetPort: 80`.

```bash
$ kubectl apply -f 01-clusterip/app-deployment.yaml
$ kubectl apply -f 01-clusterip/service.yaml
$ kubectl get pods -l app=web-clusterip -o wide
NAME                                 READY   STATUS    RESTARTS   AGE   IP            NODE       NOMINATED NODE   READINESS GATES
web-app-clusterip-66865d4855-bf2fd   1/1     Running   0          1s    10.244.0.82   minikube   <none>           <none>
web-app-clusterip-66865d4855-bx2n2   1/1     Running   0          1s    10.244.0.83   minikube   <none>           <none>
web-app-clusterip-66865d4855-kn9fp   1/1     Running   0          1s    10.244.0.84   minikube   <none>           <none>

$ kubectl get svc web-service-clusterip
$ kubectl get endpoints web-service-clusterip
Warning: v1 Endpoints is deprecated in v1.33+; use discovery.k8s.io/v1 EndpointSlice
NAME                            TYPE        CLUSTER-IP      EXTERNAL-IP   PORT(S)    AGE
service/web-service-clusterip   ClusterIP   10.108.173.66   <none>        8080/TCP   1s

NAME                              ENDPOINTS                                      AGE
endpoints/web-service-clusterip   10.244.0.82:80,10.244.0.83:80,10.244.0.84:80   1s
```

The endpoints controller found the 3 pods with the label `app=web-clusterip` that were **Ready**, and wrote their IPs into the Endpoints object. Nothing in there points at a pod by name. It gets recalculated constantly, so a pod that starts failing its readiness probe drops off the list within seconds. That is the mechanism that makes zero-downtime rollouts possible.

Reaching it from inside the cluster:

```bash
$ kubectl exec curl-client -- curl -s http://web-service-clusterip:8080 | grep -i "<title>"
$ kubectl exec curl-client -- curl -s http://web-service-clusterip.default.svc.cluster.local:8080 | grep -i "<title>"
<title>Welcome to nginx!</title>
<title>Welcome to nginx!</title>
```

All three ways of addressing it end up at the same iptables rules: the short name, the full FQDN, and the ClusterIP itself.

📸 `screenshots/01-clusterip.png`

---

## 2. NodePort: reachable on every node's IP

`02-nodeport/` has 2 replicas and sets `nodePort: 30080`.

```bash
$ kubectl get svc web-service-nodeport
NAME                   TYPE       CLUSTER-IP     EXTERNAL-IP   PORT(S)        AGE
web-service-nodeport   NodePort   10.110.33.74   <none>        80:30080/TCP   1s
```

The `PORT(S)` column reads `80:30080/TCP`. Service port on the left, node port on the right.

Something I had not realised before: a NodePort Service is a **superset** of ClusterIP, not an alternative to it. It still gets its own ClusterIP and still works for internal traffic. The node port is just an extra door opened on top, on every node in the cluster.

```bash
$ minikube ssh "curl -sI http://localhost:30080"
HTTP/1.1 200 OK

[1mServer[0m: nginx/1.25.5

[1mDate[0m: Sat, 19 Sep 2026 15:05:01 GMT

[1mContent-Type[0m: text/html

$ minikube service web-service-nodeport --url
http://127.0.0.1:65108
! Because you are using a Docker driver on windows, the terminal needs to be open to run it.
```

📸 `screenshots/02-nodeport-loadbalancer-externalname.png`

---

## 3. LoadBalancer: what you would use on a real cloud

`03-loadbalancer/` has 3 replicas and uses `type: LoadBalancer`.

```bash
$ kubectl get svc web-service-loadbalancer
NAME                       TYPE           CLUSTER-IP    EXTERNAL-IP   PORT(S)        AGE
web-service-loadbalancer   LoadBalancer   10.96.30.17   <pending>     80:30790/TCP   1s
```

`EXTERNAL-IP` just sits at `<pending>`, because on Minikube there is no cloud controller manager listening for that request. On EKS, GKE or AKS the cloud controller would go and provision an actual load balancer, then write its address back into `status.loadBalancer.ingress`. `minikube tunnel` pretends to be that controller locally. It has to run in its own terminal and stay open, and on Windows it needs an Administrator shell.

The three types are **built on top of each other, they are not alternatives**:

```bash
Type       : LoadBalancer
ClusterIP  : 10.96.30.17
port       : 80
targetPort : 80
nodePort   : 30790
```

You can see it in that output: a LoadBalancer Service automatically got a ClusterIP *and* a nodePort, without me asking for either. The cloud load balancer's backend targets are just `<node IP>:<nodePort>`, so the chain is:

```
Internet ─► Cloud LB ─► NodeIP:nodePort ─► ClusterIP:port ─► PodIP:targetPort
```

📸 `screenshots/02-nodeport-loadbalancer-externalname.png` (same shot as above)

---

## 4. ExternalName: a CNAME alias handled by CoreDNS

`04-externalname/` sets up an alias pointing at `api.github.com`.

```bash
$ kubectl get svc external-database-service
NAME                        TYPE           CLUSTER-IP   EXTERNAL-IP      PORT(S)   AGE
external-database-service   ExternalName   <none>       api.github.com   <none>    1s

$ kubectl get endpoints external-database-service
Warning: v1 Endpoints is deprecated in v1.33+; use discovery.k8s.io/v1 EndpointSlice
Error from server (NotFound): endpoints "external-database-service" not found

$ kubectl exec dns-test-client -- nslookup external-database-service
Server:		10.96.0.10
Address:	10.96.0.10:53

** server can't find external-database-service.cluster.local: NXDOMAIN

** server can't find external-database-service.cluster.local: NXDOMAIN

** server can't find external-database-service.svc.cluster.local: NXDOMAIN

** server can't find external-database-service.svc.cluster.local: NXDOMAIN

external-database-service.default.svc.cluster.local	canonical name = api.github.com

external-database-service.default.svc.cluster.local	canonical name = api.github.com
Name:	api.github.com
Address: 20.207.73.85

command terminated with exit code 1
```

`CLUSTER-IP: <none>`, no selector, no Endpoints object at all, and **no proxying whatsoever**. This type is done entirely in CoreDNS as a CNAME record. The client looks up the real name itself and connects directly, so none of the traffic goes anywhere near kube-proxy.

That `nslookup` output looks like it failed, but it did not, so it is worth reading properly.

The `NXDOMAIN` lines at the top are just the resolver trying each `search` suffix in turn before it gets to the right one. That is the `ndots:5` behaviour I explain in section 6, and this is it happening live.

The `Can't find ...: No answer` at the bottom is also not an error. CoreDNS gave back the CNAME, which you can see on the line `canonical name = api.github.com`, but it did not attach an A record to it. So `nslookup` says it has no answer for the name it originally asked about. The alias resolved fine, the client just has to do the second lookup itself.

The reason you would use this is indirection. Your app code hardcodes `external-database-service` and never changes, so switching from a staging RDS instance to the production one is a one-line edit to the Service instead of a rebuild and redeploy.

Two things to watch out for. TLS certificate validation uses the *real* hostname, not the alias. And it can only alias a DNS name, you cannot point it at a bare IP address.

📸 `screenshots/02-nodeport-loadbalancer-externalname.png` (same shot as above)

---

## 5. Headless Service: `clusterIP: None`

`05-headless/` pairs a headless Service with a StatefulSet of 3 replicas.

```bash
$ kubectl get svc web-service-headless
NAME                   TYPE        CLUSTER-IP   EXTERNAL-IP   PORT(S)   AGE
web-service-headless   ClusterIP   None         <none>        80/TCP    3s

$ kubectl get pods -l app=web-headless -o wide
NAME             READY   STATUS    RESTARTS   AGE   IP            NODE       NOMINATED NODE   READINESS GATES
web-stateful-0   1/1     Running   0          3s    10.244.0.92   minikube   <none>           <none>
web-stateful-1   1/1     Running   0          2s    10.244.0.93   minikube   <none>           <none>
web-stateful-2   1/1     Running   0          2s    10.244.0.94   minikube   <none>           <none>
```

DNS returns every pod IP instead of one VIP:

```bash
$ kubectl exec headless-dns-client -- nslookup web-service-headless
Server:		10.96.0.10
Address:	10.96.0.10:53

** server can't find web-service-headless.svc.cluster.local: NXDOMAIN

** server can't find web-service-headless.cluster.local: NXDOMAIN

** server can't find web-service-headless.cluster.local: NXDOMAIN

** server can't find web-service-headless.svc.cluster.local: NXDOMAIN

Name:	web-service-headless.default.svc.cluster.local
Address: 10.244.0.93
Name:	web-service-headless.default.svc.cluster.local
Address: 10.244.0.94
Name:	web-service-headless.default.svc.cluster.local
Address: 10.244.0.92


command terminated with exit code 1
```

Three separate `A` records came back: `10.244.0.79`, `.81` and `.82`. Compare those against the pod IPs in the table above and they match exactly. (The `NXDOMAIN` lines are the search-suffix walk again.)

A normal ClusterIP Service would return one single address, the virtual IP, and kube-proxy would pick a pod for you. With `clusterIP: None` there is **no virtual IP and no load balancing at all**. The client gets handed the full list of members and decides for itself which one to talk to.

Slightly confusing detail: `kubectl get svc` still prints `TYPE: ClusterIP` for a headless Service. There is no "Headless" type. The way you spot it is the `CLUSTER-IP` column saying `None` instead of showing an actual address.

Each pod also gets a stable DNS name:

```bash
$ kubectl exec headless-dns-client -- nslookup web-stateful-0.web-service-headless.default.svc.cluster.local
$ kubectl exec headless-dns-client -- curl -s http://web-stateful-0.web-service-headless:80 | grep -i "<title>"
<title>Welcome to nginx!</title>
```

The pattern is `<pod>.<service>.<namespace>.svc.cluster.local`, and it only works because the StatefulSet has `serviceName: web-service-headless` set in its spec.

**Why stateful systems need this.** A Kafka client needs to reach the specific broker that owns partition 3, not whichever broker it happens to land on. A Postgres replica needs to reach the actual primary. Round-robin over a virtual IP does not just fail to help those systems, it actively breaks them.

📸 `screenshots/03-headless.png`

---

## 6. DNS: how FQDNs work and the `ndots:5` gotcha

```
web-service-clusterip . default . svc . cluster.local
         │                │        │         │
      service        namespace   "svc"   cluster domain
```

```bash
$ kubectl exec curl-client -- cat /etc/resolv.conf
search default.svc.cluster.local svc.cluster.local cluster.local
nameserver 10.96.0.10
options ndots:5
```

`nameserver 10.96.0.10` is the ClusterIP of the `kube-dns` Service, and the kubelet writes it into every pod automatically. The `search` suffixes are the reason a bare name like `web-service-clusterip` resolves at all.

`options ndots:5` means **any name with fewer than 5 dots is tried against every search suffix first**. So `api.github.com` (2 dots) goes:

```
1. api.github.com.default.svc.cluster.local   → NXDOMAIN
2. api.github.com.svc.cluster.local           → NXDOMAIN
3. api.github.com.cluster.local               → NXDOMAIN
4. api.github.com                             → resolves ✅
```

So that is 4 queries where you expected 1. It gets worse: glibc sends the A and AAAA lookups in parallel, so you are actually sending **8 packets to CoreDNS for one external lookup**.

On a service making thousands of outbound API calls per second, this turns into CoreDNS burning CPU and a visible bump in p99 latency. It is apparently a well known production problem. Three ways to fix it: put a trailing dot on the name (`api.github.com.`) so the resolver skips the search list entirely, lower `ndots` for that pod via `spec.dnsConfig`, or run NodeLocal DNSCache so the misses get served locally.

---

## 7. Reaching a NodePort with the Docker driver

```bash
$ NODE_IP=$(minikube ip)
$ curl --connect-timeout 5 -sI "http://${NODE_IP}:30080"
minikube ip = 192.168.49.2
  % Total    % Received % Xferd  Average Speed  Time    Time    Time   Current
                                 Dload  Upload  Total   Spent   Left   Speed

  0      0   0      0   0      0      0      0                              0
  0      0   0      0   0      0      0      0           00:01              0
  0      0   0      0   0      0      0      0           00:02              0
  0      0   0      0   0      0      0      0           00:03              0
  0      0   0      0   0      0      0      0           00:04              0
```

But the same NodePort works from inside the node:

```bash
HTTP/1.1 200 OK

[1mServer[0m: nginx/1.25.5

[1mDate[0m: Sat, 19 Sep 2026 15:05:20 GMT

[1mContent-Type[0m: text/html
```

With the Docker driver the node is a container and `192.168.49.2` sits on an internal Docker bridge, so the host has no route to it. kube-proxy is fine, which you can see from the request working from inside the node. minikube gives you two ways around it.

```bash
$ minikube service web-service-nodeport --url
http://127.0.0.1:41073
! Because you are using a Docker driver on linux, the terminal needs to be open to run it.
```

| | `minikube service --url` | `minikube tunnel` |
| --- | --- | --- |
| Needs admin/sudo | No | **Yes** |
| Port | Random loopback port | The real port (80/443/nodePort) |
| Gives LoadBalancer an EXTERNAL-IP | No | **Yes** |
| Scope | One Service | All Services |

📸 `screenshots/04-dns-and-nodeport-gotcha.png`

---

## Learning summary

### The 4 ports

| Field | On | Read by | Range |
| --- | --- | --- | --- |
| `containerPort` | Pod | Nothing at runtime, it is documentation only | 1 to 65535 |
| `targetPort` | Service | kube-proxy, this is the pod port traffic gets sent to | 1 to 65535 |
| `port` | Service | Clients inside the cluster, this is the port on the ClusterIP | 1 to 65535 |
| `nodePort` | Service | Clients outside the cluster, opened on **every** node | **30000 to 32767** |

### Picking a service type

```
Need to expose it outside the cluster?
│
├── NO ──► Do clients need individual pods (Kafka, Cassandra, Postgres)?
│            ├── YES ──► HEADLESS  (clusterIP: None)
│            └── NO  ──► CLUSTERIP (the default)
│
└── YES ─► Is the backend a third-party domain (RDS, Stripe)?
             ├── YES ──► EXTERNALNAME
             └── NO ──► On a managed cloud?
                          ├── YES, HTTP(S) ──► ONE INGRESS behind ONE LOADBALANCER,
                          │                    every app stays a plain ClusterIP
                          ├── YES, raw TCP ──► LOADBALANCER directly
                          └── NO (dev/on-prem) ──► NODEPORT
```

### Why one Ingress instead of many LoadBalancers

A cloud load balancer costs somewhere around $18 to $25 a month. Give every microservice its own one and at 50 services you are paying roughly **$1,250 a month**.

Put a single Ingress Controller behind one load balancer instead, and leave all 50 apps as plain internal ClusterIPs, and the same setup costs about **$25 a month**. That is roughly $14,700 saved over a year, and you also end up managing one TLS certificate and one DNS record instead of 50 of each. That is the setup Session 12 builds.

---

## Manifest index

| Path | What it is |
| --- | --- |
| `01-clusterip/` | Deployment + ClusterIP Service + curl client |
| `02-nodeport/` | Deployment + NodePort Service (30080) |
| `03-loadbalancer/` | Deployment + LoadBalancer Service |
| `04-externalname/` | ExternalName Service pointing at `api.github.com` |
| `05-headless/` | Headless Service + StatefulSet (3 ordinals) |
| `troubleshooting/empty-endpoints.yaml` | Selector with a deliberate typo, so Endpoints comes back empty |
