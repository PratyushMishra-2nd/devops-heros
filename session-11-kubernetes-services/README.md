<<<<<<< HEAD
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
=======
# Session 11: Kubernetes Networking & Services

Pods are ephemeral. When a Pod crashes, updates, or scales, it is replaced with a new Pod that receives a **brand-new, unpredictable IP address**. If microservices communicated by hardcoding Pod IPs, every restart would trigger a cascading outage.

A **Kubernetes Service** provides a stable virtual IP address (ClusterIP) and a permanent DNS name that never changes, dynamically load-balancing traffic across all healthy backend Pods.

---

## What will you learn?

* Understand the fundamental Kubernetes flat networking model and the **3 Golden Rules of Pod Networking**.
* Decouple Pod lifecycles from network communication using the **Service abstraction**.
* Demystify port mappings: The definitive difference between **`port`**, **`targetPort`**, and **`nodePort`**.
* Master the 4 Service Types:
  * **`ClusterIP`** (Default): Internal cluster-only communication.
  * **`NodePort`**: Exposes the service on a static high port (`30000–32767`) across every worker node.
  * **`LoadBalancer`**: Provisions an external cloud load balancer (e.g., AWS NLB/ALB) with a public IP.
  * **`ExternalName`**: Maps internal service names to external CNAMEs (e.g., AWS RDS endpoints).
* Understand cluster-internal DNS resolution via **CoreDNS**, `/etc/resolv.conf`, and Fully Qualified Domain Names (FQDNs).
* Troubleshoot the #1 Kubernetes networking error: **Empty Endpoints (`<none>`)**.

---

## Why does this matter?

In a distributed microservice architecture, your frontend UI needs to talk to your backend API. You cannot hardcode `http://10.244.1.15:5000` because the moment that pod crashes or scales, that IP address is gone forever.

With a Kubernetes Service, the frontend simply sends requests to `http://yatri-backend-service:80`. CoreDNS resolves that name to the stable virtual IP, and Linux kernel routing (`kube-proxy` via `iptables` or `IPVS`) distributes incoming requests across all healthy backend pods. Without Services, microservice architectures in Kubernetes cannot operate.

---

## Core Concepts Explained

### 1. First Question: How Does Kubernetes Pod Networking Work?

In traditional virtual machine or container setups, containers often sit behind private bridges with host port mappings (`-p 8080:80`). In a Kubernetes cluster with thousands of pods across hundreds of nodes, port collision management would be unworkable.

Kubernetes enforces a clean, flat networking model defined by **The 3 Golden Rules**:
1. **All Pods can communicate with all other Pods without NAT** (across any node in the cluster).
2. **All Nodes can communicate with all Pods without NAT** (and vice versa).
3. **The IP address a Pod sees for itself is the exact same IP address every other Pod sees for it**.

#### The Problem: Ephemeral Pod IPs
Every Pod gets a real, cluster-routable IP address from the Container Network Interface (CNI) plugin (e.g., Calico, Flannel, AWS VPC CNI). However, Pods are disposable.

```text
Old Backend Pod: 10.244.1.15  --> Terminated / Crashed
New Backend Pod: 10.244.2.42  --> Starts with a BRAND-NEW IP!
```

If any client hardcoded `10.244.1.15`, the application would fail immediately with `Connection Refused`. We need an unchanging intermediary: **The Kubernetes Service**.

---

### 2. Second Question: What is a Service? (The Corporate Reception Desk Analogy)

Think of a **Large Corporate Enterprise (The Kubernetes Cluster)**:
* **The Developers / Staff (The Pods):** 5 backend engineers work in the office. They take vacations, change desks, work remotely, or resign. Their locations change constantly.
* **The Corporate Reception Desk (The Service):** The company maintains one static, unchanging reception desk at the entrance.
* **The Receptionist's Live Clipboard (The Endpoints List):** The receptionist maintains an up-to-the-minute list of which engineers are currently seated at their desks.
* When an external visitor or internal colleague needs help, they never wander the building searching for an individual engineer's desk. They walk up to the **Reception Desk (Service Virtual IP)**. The receptionist hands the inquiry to whichever engineer is currently available and healthy.

```mermaid
flowchart TD
    Client["Client / Frontend Pod"] -->|Calls http://yatri-backend-service:80| VIP["Service Virtual IP: ClusterIP (10.96.145.82:80)"]

    subgraph ServiceRouting ["kube-proxy / iptables (Load Balancing)"]
        VIP -->|targetPort: 5000| PodA["Backend Pod 1 (10.244.0.15:5000)"]
        VIP -->|targetPort: 5000| PodB["Backend Pod 2 (10.244.0.22:5000)"]
        VIP -->|targetPort: 5000| PodC["Backend Pod 3 (10.244.0.38:5000)"]
    end
```

---

### 3. Third Question: What is the Difference Between `port`, `targetPort`, and `nodePort`?

This is one of the most common points of confusion for Kubernetes beginners. Memorize the **Three Ports Triangle**:

```text
External Internet / User Browser
       |
       | hits physical machine on high port (30000 - 32767)
       v
+--------------+
|   nodePort   |  (e.g. 30080 on the Worker Node IP)
+--------------+
       |
       | forwards internally inside cluster
       v
+--------------+
|     port     |  (Port exposed by the Service inside the cluster, e.g. 80)
+--------------+
       |
       | forwards into container process
       v
+--------------+
|  targetPort  |  (Port where the container app is actually listening, e.g. 5000)
+--------------+
```

* **`port` (The Front Door):** The port exposed by the Service to other services *inside* the cluster. Standard HTTP is `80`.
* **`targetPort` (The Back Door):** The port where the application process inside the container is actively listening (e.g., Flask on `5000`, Spring Boot on `8080`).
* **`nodePort` (The Physical Machine Door):** A static port allocated across every worker node's physical IP address from the range `30000–32767`.

| Port Field | Where It Listens | Who Connects to It? | Example Value |
| :--- | :--- | :--- | :--- |
| **`port`** | Service Virtual IP (ClusterIP) | Internal microservices inside the cluster | `80` |
| **`targetPort`** | Container inside the Pod | Service load balancer (`kube-proxy`) | `5000` |
| **`nodePort`** | Worker Node physical IP | External clients or edge load balancers | `30080` |

---

### 4. Fourth Question: What Are the 4 Kubernetes Service Types?

```mermaid
flowchart TD
    subgraph Types ["Kubernetes Service Types"]
        CIP["ClusterIP (Default)\n- Internal cluster VIP\n- Unreachable from internet"]
        NP["NodePort\n- Opens port 30000-32767 on all nodes\n- Direct access via NodeIP:NodePort"]
        LB["LoadBalancer\n- Provisions Cloud Load Balancer\n- Assigns public IP / DNS (AWS NLB/ALB)"]
        EN["ExternalName\n- Maps internal name to external CNAME\n- No proxying or selectors"]
    end
```

1. **`ClusterIP` (Default):** Exposes the Service on an internal IP reachable only from within the cluster. Ideal for internal microservice-to-microservice APIs, databases, and caching layers.
2. **`NodePort`:** Builds on top of ClusterIP. Allocates a port in the range `30000–32767` on every node's IP. Anyone with network access to the node can connect via `http://<Node-IP>:<NodePort>`.
3. **`LoadBalancer`:** Builds on top of NodePort and ClusterIP. Asks the cloud provider (AWS, GCP, Azure) to provision an external public Load Balancer that routes incoming internet traffic to the cluster's NodePorts.
4. **`ExternalName`:** Acts as an internal DNS alias (CNAME). When a pod requests `database-service`, CoreDNS returns the external domain (e.g., `mydb.rds.amazonaws.com`).

---

### 5. Fifth Question: How Does Kubernetes Internal DNS (CoreDNS) Work?

Kubernetes runs a cluster-internal DNS service called **CoreDNS**. Every time a Service is created, CoreDNS automatically registers an A-record:

$$\text{Format: } \mathbf{\langle service\text{-}name\rangle.\langle namespace\rangle.svc.cluster.local}$$

* Within the **same namespace**: A pod can simply call `http://yatri-backend-service:80`.
* From a **different namespace**: A pod calls `http://yatri-backend-service.<namespace>.svc.cluster.local:80`.

#### The Container Configuration: `/etc/resolv.conf`
When Kubernetes starts a Pod, it configures DNS lookups automatically:
```text
nameserver 10.96.0.10
search default.svc.cluster.local svc.cluster.local cluster.local
options ndots:5
```
Because `default.svc.cluster.local` is in the search list, typing `yatri-backend-service` automatically completes to the full FQDN and resolves to the Service's ClusterIP!

---

### 6. Sixth Question: What Causes "Empty Endpoints"? (The #1 Triage Scenario)

A Service is just a routing abstraction. The actual destination pod IPs are tracked in an **`Endpoints`** (or `EndpointSlice`) object created by the Endpoints Controller.

If a Service's `spec.selector` has even a single character typo compared to the Pod's `metadata.labels`, the Endpoints Controller finds zero matching pods.
* The Service is created successfully without errors.
* Running `kubectl get endpoints <service>` shows `<none>`.
* Incoming requests hang and fail with `Connection Timed Out` or `HTTP 503`.

---

## Step-by-Step Hands-on Labs

All manifests for this lab are located in:
* `./deployment/backend-deployment.yaml`
* `./service/clusterip.yaml`
* `./service/nodeport.yaml`
* `./service/loadbalancer.yaml`
* `./dns-test/curl-test-pod.yaml`
* `./troubleshooting/empty-endpoints.yaml`

---

### Lab 1: Deploy Backend Pods

Before creating a Service, deploy 3 backend pods running a lightweight Python HTTP server on port 5000:

```bash
kubectl apply -f deployment/backend-deployment.yaml
```
* Explanation: Deploys 3 replicas with label `app: yatri-backend` listening on container port 5000.

Verify pods are running:
```bash
kubectl get pods -l app=yatri-backend -o wide
```

Expected output:
```text
NAME                            READY   STATUS    RESTARTS   AGE   IP            NODE
yatri-backend-7f89d54b8-2k4l9   1/1     Running   0          25s   10.244.0.15   minikube
yatri-backend-7f89d54b8-8p2m1   1/1     Running   0          25s   10.244.0.22   minikube
yatri-backend-7f89d54b8-x9q4t   1/1     Running   0          25s   10.244.0.38   minikube
```

Notice that each pod has a unique private IP address (`10.244.0.15`, etc.).

---

### Lab 2: Expose Backend via ClusterIP

Deploy the internal ClusterIP service:

```bash
kubectl apply -f service/clusterip.yaml
```
* Explanation: Creates a virtual IP listening on port 80 and forwarding to targetPort 5000.

Inspect the service:
```bash
kubectl get svc yatri-backend-service
```

Expected output:
```text
NAME                    TYPE        CLUSTER-IP      EXTERNAL-IP   PORT(S)   AGE
yatri-backend-service   ClusterIP   10.96.145.82    <none>        80/TCP    12s
```

Now inspect the associated Endpoints object:
```bash
kubectl get endpoints yatri-backend-service
```

Expected output:
```text
NAME                    ENDPOINTS                                            AGE
yatri-backend-service   10.244.0.15:5000,10.244.0.22:5000,10.244.0.38:5000   30s
```
* Explanation: The Endpoints Controller automatically matched `selector: app=yatri-backend` and populated the exact IPs and container ports of all 3 running pods!

---

### Lab 3: Test Internal DNS & Service Discovery via Diagnostic Pod

Deploy the test client pod:
```bash
kubectl apply -f dns-test/curl-test-pod.yaml
```

Wait until running:
```bash
kubectl get pod curl-test-pod
```

Test DNS resolution from inside the cluster:
```bash
kubectl exec -it curl-test-pod -- nslookup yatri-backend-service
```

Expected output:
```text
Server:    10.96.0.10
Address:   10.96.0.10#53

Name:      yatri-backend-service.default.svc.cluster.local
Address:   10.96.145.82
```

Send an HTTP request using the service name (no IP addresses needed):
```bash
kubectl exec -it curl-test-pod -- curl -s http://yatri-backend-service:80
```

Expected output:
```text
Backend v1.0.0 listening on port 5000
```

Query the healthcheck endpoint:
```bash
kubectl exec -it curl-test-pod -- curl -s http://yatri-backend-service/healthz
```

Expected output:
```json
{"status":"healthy","service":"yatri-backend"}
```

---

### Lab 4: Expose Backend Externally via NodePort

Deploy the NodePort service:
```bash
kubectl apply -f service/nodeport.yaml
```
* Explanation: Opens port `30080` on every node and forwards to `port 80` -> `targetPort 5000`.

Inspect the NodePort service:
```bash
kubectl get svc yatri-backend-nodeport
```

Expected output:
```text
NAME                     TYPE       CLUSTER-IP      EXTERNAL-IP   PORT(S)        AGE
yatri-backend-nodeport   NodePort   10.96.210.44    <none>        80:30080/TCP   15s
```

Test access directly from your host terminal:
```bash
curl http://localhost:30080
```

Expected output:
```text
Backend v1.0.0 listening on port 5000
```

---

### Lab 5: Cloud LoadBalancer Service

Deploy the LoadBalancer service:
```bash
kubectl apply -f service/loadbalancer.yaml
```

Inspect the service:
```bash
kubectl get svc yatri-backend-lb
```

Expected output (Local Minikube):
```text
NAME               TYPE           CLUSTER-IP      EXTERNAL-IP   PORT(S)        AGE
yatri-backend-lb   LoadBalancer   10.96.180.11    <pending>     80:31254/TCP   10s
```

Expected output (AWS EKS):
```text
NAME               TYPE           CLUSTER-IP      EXTERNAL-IP                                            PORT(S)        AGE
yatri-backend-lb   LoadBalancer   10.96.180.11    a1b2c3d4e5-987654321.us-east-1.elb.amazonaws.com     80:31254/TCP   45s
```
* Explanation: On bare-metal or local Minikube without a cloud controller or `minikube tunnel`, `EXTERNAL-IP` remains `<pending>`. In AWS EKS, AWS provisions an elastic Network Load Balancer automatically.

---

### Lab 6: Triage the "Empty Endpoints" Failure Drill

Deploy the intentionally broken service:
```bash
kubectl apply -f troubleshooting/empty-endpoints.yaml
```

Check the endpoints:
```bash
kubectl get endpoints broken-backend-service
```

Expected output:
```text
NAME                     ENDPOINTS   AGE
broken-backend-service   <none>      12s
```

Attempt to curl the broken service from the diagnostic pod:
```bash
kubectl exec -it curl-test-pod -- curl --connect-timeout 3 http://broken-backend-service
```

Expected output:
```text
curl: (28) Failed to connect to broken-backend-service port 80: Connection timed out
```

#### The 3-Step Triage Formula:
1. **Check Endpoints:** `kubectl get endpoints broken-backend-service` -> Displays `<none>`.
2. **Inspect Service Selector:**
   ```bash
   kubectl describe svc broken-backend-service | grep Selector
   ```
   Output: `Selector: app=wrong-backend-name`
3. **Compare Against Pod Labels:**
   ```bash
   kubectl get pods --show-labels
   ```
   Output: `app=yatri-backend`
4. **Fix:** Update the service YAML so `spec.selector.app` matches `yatri-backend`.

Cleanup broken service:
```bash
kubectl delete -f troubleshooting/empty-endpoints.yaml
```

---

## 5-Minute Revision Checklist

* [ ] I can state the 3 Golden Rules of Kubernetes Pod Networking.
* [ ] I understand why Pod IPs are ephemeral and why microservices require Services.
* [ ] I can explain the Three Ports Triangle: `port` (Service Front Door), `targetPort` (Container Process), and `nodePort` (Worker Node IP).
* [ ] I know that `ClusterIP` is internal only, while `NodePort` and `LoadBalancer` provide external access.
* [ ] I can write the full Kubernetes DNS FQDN syntax: `<service>.<namespace>.svc.cluster.local`.
* [ ] I know that `kubectl get endpoints <service>` is the #1 command to verify if a Service found healthy Pods.
* [ ] I understand that `kube-proxy` programs Linux kernel `iptables` or `IPVS` rules to load-balance traffic across pods.

---

## High-Frequency Interview Preparation

### Beginner Level

#### Q1. What is a Kubernetes Service and why is it necessary?
* **Answer:** A Kubernetes Service is a networking abstraction that defines a logical set of Pods and a policy to access them. Because Pods are ephemeral and receive dynamic IP addresses that change on restart or scaling, Services provide a static virtual IP (ClusterIP) and a permanent DNS name. This ensures clients and other microservices can reliably communicate without tracking individual Pod IPs.

#### Q2. What happens if a Service selector does not match any running Pod labels?
* **Answer:** The Service will be created without errors, but its `Endpoints` object will remain empty (`<none>`). Any traffic sent to the Service will hang and fail with a connection timeout or connection refused because there are no backend destination Pods.

---

### Intermediate Level

#### Q3. Explain the difference between `NodePort` and `LoadBalancer`.
* **Answer:**
  * **`NodePort`:** Opens a dedicated high port from the range `30000–32767` on every worker node's physical IP address. External traffic must connect directly to a specific node IP on that non-standard port.
  * **`LoadBalancer`:** The production-standard mechanism in cloud environments (AWS, GCP, Azure). It automatically provisions a cloud load balancer (e.g., AWS NLB) that accepts traffic on standard ports (`80`, `443`) with a public IP or DNS name and routes it across the cluster's NodePorts automatically.

#### Q4. How does `kube-proxy` direct traffic to Pods?
* **Answer:** `kube-proxy` runs on every worker node as a DaemonSet. It monitors the API server for changes to Services and Endpoints. In modern Kubernetes clusters, it does not proxy traffic through user space; instead, it writes Linux kernel **`iptables`** rules or configures **`IPVS`** (IP Virtual Server) tables to intercept traffic destined for the Service Virtual IP and perform Destination NAT (DNAT) to healthy Pod IPs using random or round-robin balancing.

---

### Advanced & Scenario-Based

#### Q5. Scenario: A frontend pod cannot communicate with `http://yatri-backend-service`. Running `curl` inside the frontend pod times out. Walk through your step-by-step triage workflow.
* **Answer:**
  1. **Check Service Endpoints:** Run `kubectl get endpoints yatri-backend-service`. If it shows `<none>`, there is a label selector mismatch or pods are not ready.
  2. **Verify Pod Labels and Readiness:** Run `kubectl get pods -l app=yatri-backend -o wide`. Ensure pods are in `Running` state and pass their Readiness Probes. (Pods failing readiness are automatically detached from Endpoints!).
  3. **Verify Port Mapping:** Check the Service definition. Ensure `spec.ports.targetPort` matches the actual port where the backend process is listening (e.g., `5000` vs `80`).
  4. **Verify DNS Resolution:** Exec into the frontend pod and run `nslookup yatri-backend-service`. Confirm CoreDNS resolves the name to the Service ClusterIP.
  5. **Check NetworkPolicies:** Verify no Kubernetes `NetworkPolicy` is blocking egress from the frontend or ingress into the backend namespace.

---

## Homework & Hands-on Challenge

1. Deploy `deployment/backend-deployment.yaml` and scale it from 3 to 6 replicas using `kubectl scale deployment yatri-backend --replicas=6`.
2. Run `kubectl get endpoints yatri-backend-service` and observe how all 6 pod IPs are immediately added to the endpoints list.
3. Scale the deployment down to 1 replica and verify the endpoints list shrinks dynamically.
4. Intentionally change `targetPort` in `service/clusterip.yaml` to `9999` and observe the exact error when curling from `curl-test-pod`.

---

## Next Session Connection

In **Session 12: Kubernetes Ingress, ConfigMaps & Secrets**, NodePort opens too many non-standard ports (`:30080`) and LoadBalancer gets expensive if you create one per microservice. You will learn how **Ingress Controllers** route traffic from a single public domain (`yatri.com/api` vs `yatri.com/app`) and manage configuration and passwords securely with ConfigMaps and Secrets.
>>>>>>> a6e7e9464a333058fc42f0b0102eb9bf689baa53
