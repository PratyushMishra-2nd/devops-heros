# Session 14: Kubernetes Troubleshooting

**Pratyush Mishra · Roll No. 10486**

Worked through the five basic tools (`get`, `describe`, `logs`, `exec`, events), then the three classic broken-pod folders (CrashLoopBackOff, ImagePullBackOff, Pending), the Service/DNS folder, the five-pod "triage gauntlet" in `scenarios/`, and the mini-project. For every broken thing I applied it, looked at the symptom, found the root cause, fixed it and checked it was healthy. Two of the "working" manifests in `09-service-dns-troubleshooting/` were actually broken too, which turned out to be the best practice of the lot. Everything below is copied straight from my terminal.

**Setup:** Ubuntu 26.04 on WSL2, Minikube v1.39.0 with the Docker driver, Kubernetes v1.37.0.

> Namespaces used: `s14-lab` (folders 01 to 09), `s14-scenarios` (gauntlet) and `s14-mini` (mini-project). `triage_all.sh` has no `-n` flags, so I ran it with a private copy of my kubeconfig whose default namespace is `s14-scenarios` instead of changing the shared context.

---

## 1. `kubectl get` and `kubectl describe`

```bash
$ kubectl create namespace s14-lab
namespace/s14-lab created
$ kubectl apply -n s14-lab -f 01-kubectl-get/pod.yaml
pod/get-demo created
$ kubectl apply -n s14-lab -f 02-kubectl-describe/pod.yaml
error: the path "02-kubectl-describe/pod.yaml" does not exist
$ kubectl apply -n s14-lab -f 02-kubectl-describe/demo-pod.yaml
pod/describe-demo created
```

First small bug: the folder README says `kubectl apply -f pod.yaml`, but the file is called `demo-pod.yaml`.

```bash
$ kubectl get pods -n s14-lab -o wide
NAME            READY   STATUS    RESTARTS   AGE   IP            NODE       NOMINATED NODE   READINESS GATES
describe-demo   1/1     Running   0          1s    10.244.0.98   minikube   <none>           <none>
get-demo        1/1     Running   0          2s    10.244.0.97   minikube   <none>           <none>
$ kubectl describe pod -n s14-lab describe-demo | grep -E "^(Name|Namespace|Status|IP):|Image:|State:|Ready:|Restart Count"
Name:             describe-demo
Namespace:        s14-lab
Status:           Running
IP:               10.244.0.98
    Image:          nginx:1.27
    State:          Running
    Ready:          True
    Restart Count:  0
```

`get` is one row per object: the columns to read are `READY`, `STATUS` and `RESTARTS`. `describe` is the long form, and the part I always scroll to is `Events` at the bottom, because that is where Kubernetes says what it tried.

---

## 2. Watching, logs and exec

```bash
$ kubectl get pods -n s14-lab -w    # and in another terminal: kubectl delete pod -n s14-lab get-demo
NAME            READY   STATUS    RESTARTS   AGE
describe-demo   1/1     Running   0          47s
get-demo        1/1     Running   0          48s
get-demo        1/1     Terminating   0          50s
get-demo        1/1     Terminating   0          50s
get-demo        0/1     Completed     0          50s
get-demo        0/1     Completed     0          51s
get-demo        0/1     Completed     0          51s
$ kubectl apply -n s14-lab -f 03-kubectl-logs/pod.yaml -f 04-kubectl-exec/pod.yaml
pod/logs-demo created
pod/exec-demo created
$ kubectl logs -n s14-lab logs-demo
Application started
Connecting to database...
Database connection successful
Application is running
Application is healthy
Application is healthy
Application is healthy
$ kubectl exec -n s14-lab exec-demo -- hostname
exec-demo
$ kubectl exec -n s14-lab exec-demo -- curl -s localhost | grep title
<title>Welcome to nginx!</title>
```

`curl localhost` from inside the container is the most useful one here. If that works, the app is fine and the problem is somewhere between the client and the Pod (Service, DNS, port, network policy), which halves the search.

---

## 3. Events

```bash
$ kubectl apply -n s14-lab -f 05-events/pod.yaml
pod/events-demo created
$ kubectl get events -n s14-lab --sort-by=.lastTimestamp | tail -n 8
...
5s          Normal   Started     pod/events-demo     Container started
5s          Normal   Created     pod/events-demo     Container created
5s          Normal   Pulled      pod/events-demo     Container image "nginx:1.27" already present on machine and can be accessed by the pod
$ kubectl events -n s14-lab --for pod/events-demo
LAST SEEN   TYPE     REASON      OBJECT            MESSAGE
6s          Normal   Scheduled   Pod/events-demo   Successfully assigned s14-lab/events-demo to minikube
6s          Normal   Pulled      Pod/events-demo   Container image "nginx:1.27" already present on machine and can be accessed by the pod
6s          Normal   Created     Pod/events-demo   Container created
6s          Normal   Started     Pod/events-demo   Container started
$ kubectl get events -n s14-lab --field-selector type=Warning
No resources found in s14-lab namespace.
```

A gotcha I noticed: with `get events --sort-by=.lastTimestamp` the `Scheduled` event for `events-demo` is missing from the tail and the rest come out in the wrong order. Scheduler events only fill in `eventTime`, not `lastTimestamp`, so they sort to the top. The newer `kubectl events --for` sorts them properly and filters to one object, so that is what I use now. `--field-selector type=Warning` is the quick "anything wrong?" check, and empty is the answer you want.

---

## 4. CrashLoopBackOff (`06-crashloopbackoff/`)

`broken-pod.yaml` prints two lines and `exit 1`.

```bash
$ kubectl apply -n s14-lab -f broken-pod.yaml
pod/crash-demo created
$ timeout 60 kubectl get pod -n s14-lab crash-demo -w
NAME         READY   STATUS              RESTARTS   AGE
crash-demo   0/1     ContainerCreating   0          0s
crash-demo   1/1     Running             0          0s
crash-demo   0/1     Error               0          0s
crash-demo   1/1     Running             1 (1s ago)   1s
crash-demo   0/1     Error               1 (1s ago)   1s
crash-demo   0/1     CrashLoopBackOff    1 (14s ago)   15s
crash-demo   1/1     Running             2 (14s ago)   15s
crash-demo   0/1     Error               2 (15s ago)   16s
crash-demo   0/1     CrashLoopBackOff    2 (21s ago)   36s
crash-demo   1/1     Running             3 (21s ago)   36s
crash-demo   0/1     Error               3 (22s ago)   37s
$ kubectl logs -n s14-lab crash-demo
Application starting...
Something went wrong!
$ kubectl describe pod -n s14-lab crash-demo | grep -E "Restart Count|BackOff"
    Restart Count:  3
  Warning  BackOff    3s (x3 over 43s)  kubelet            Back-off restarting failed container app in pod crash-demo_s14-lab(...)
$ kubectl get pod -n s14-lab crash-demo -o jsonpath="{.status.containerStatuses[0].lastState.terminated}"
{"containerID":"containerd://3110658a...","exitCode":1,"finishedAt":"2026-10-07T17:09:18Z","reason":"Error","startedAt":"2026-10-07T17:09:18Z"}
```

The watch shows what the status really is: `Running` → `Error` → `CrashLoopBackOff` (waiting) over and over, with the gaps getting longer (14s, then 21s...) because the kubelet doubles the back-off each time, up to 5 minutes. `CrashLoopBackOff` is the waiting state, not the error. The error is `exitCode: 1`, and the logs say why.

**`--previous` did not work for me:**

```bash
$ kubectl logs -n s14-lab crash-demo --previous
unable to retrieve container logs for containerd://3110658a320e18209b3766b8f7031b18e44a26968d300836da1c6907f44cde17
```

I hit this twice. The container dies in under a second, so most of the time the "current" container is already the dead one, and plain `kubectl logs` shows its output (as above). `--previous` asks for the one before that, which the kubelet has already garbage collected. `--previous` is the right tool when the container has restarted and is currently running again, like an app that crashes after an hour.

**Fix:** `fixed-pod.yaml` replaces `exit 1` with `sleep 3600`.

```bash
$ kubectl delete pod -n s14-lab crash-demo
$ kubectl apply -n s14-lab -f fixed-pod.yaml
pod/crash-demo created
$ kubectl get pod -n s14-lab crash-demo
NAME         READY   STATUS    RESTARTS   AGE
crash-demo   1/1     Running   0          8s
$ kubectl logs -n s14-lab crash-demo
Application starting...
Application is healthy
```

📸 `screenshots/01-crashloopbackoff.png`

---

## 5. ImagePullBackOff (`07-imagepullbackoff/`)

```bash
$ kubectl apply -n s14-lab -f broken-pod.yaml
pod/image-demo created
$ kubectl get pod -n s14-lab image-demo
NAME         READY   STATUS             RESTARTS   AGE
image-demo   0/1     ImagePullBackOff   0          25s
$ kubectl describe pod -n s14-lab image-demo | tail -n 8
...
  Warning  Failed     15s               kubelet            Failed to pull image "nginx:this-image-does-not-exist": rpc error: code = NotFound desc = failed to pull and unpack image "docker.io/library/nginx:this-image-does-not-exist": failed to resolve reference "docker.io/library/nginx:this-image-does-not-exist": docker.io/library/nginx:this-image-does-not-exist: not found
  Warning  Failed     15s               kubelet            Error: ErrImagePull
  Normal   BackOff    15s               kubelet            Back-off pulling image "nginx:this-image-does-not-exist"
  Warning  Failed     15s               kubelet            Error: ImagePullBackOff
```

`RESTARTS` stays 0 because the container never existed. After deleting it and applying `fixed-pod.yaml` (`nginx:1.27`) it was `1/1 Running` in 6 seconds. The message has the answer: `docker.io/library/nginx:...: not found` means the repo exists but the tag does not. Compare with scenario 2 below, where the repo itself does not exist, and the mini-project, where the same symptom was caused by a DNS failure reaching Docker Hub.

---

## 6. Pending (`08-pending-pods/`)

```bash
$ kubectl apply -n s14-lab -f broken-pod.yaml
pod/pending-demo created
$ kubectl get pod -n s14-lab pending-demo -o wide
NAME           READY   STATUS    RESTARTS   AGE   IP       NODE     NOMINATED NODE   READINESS GATES
pending-demo   0/1     Pending   0          6s    <none>   <none>   <none>           <none>
$ kubectl describe pod -n s14-lab pending-demo | grep FailedScheduling
  Warning  FailedScheduling  6s    default-scheduler  0/1 nodes are available: 1 node(s) didn't match Pod's node affinity/selector. preemption: 0/1 nodes are available: 1 Preemption is not helpful for scheduling.
$ kubectl get nodes --show-labels | tr , "\n" | grep hostname
kubernetes.io/hostname=minikube
$ kubectl delete pod -n s14-lab pending-demo
$ kubectl apply -n s14-lab -f fixed-pod.yaml
pod/pending-demo created
$ kubectl get pod -n s14-lab pending-demo -o wide
NAME           READY   STATUS    RESTARTS   AGE   IP             NODE       NOMINATED NODE   READINESS GATES
pending-demo   1/1     Running   0          6s    10.244.0.108   minikube   <none>           <none>
```

`NODE: <none>` is the tell: Pending with no node means the scheduler has not placed it, so there are no logs and nothing to exec into. Only events help. The Pod asks for `kubernetes.io/hostname: node-that-does-not-exist` and the only node is labelled `minikube`.

📸 `screenshots/02-pending.png`

---

## 7. Service and DNS (`09-service-dns-troubleshooting/`), where the "good" manifests were broken

The README says apply `deployment.yaml`, `service.yaml`, `dns-test-pod.yaml` and everything works, and only `broken-service.yaml` is broken. Not what happened:

```bash
$ kubectl apply -n s14-lab -f deployment.yaml -f service.yaml -f dns-test-pod.yaml
deployment.apps/web created
service/web-service created
pod/dns-test created
$ kubectl get pods -n s14-lab -l app=web --show-labels
NAME                   READY   STATUS    RESTARTS   AGE    LABELS
web-557577df75-nr67g   1/1     Running   0          3m1s   app=web,pod-template-hash=557577df75
web-557577df75-zht5l   1/1     Running   0          3m1s   app=web,pod-template-hash=557577df75
$ kubectl get endpoints -n s14-lab web-service
NAME          ENDPOINTS   AGE
web-service   <none>      3m1s
$ kubectl describe service -n s14-lab web-service | grep -E "Selector|TargetPort|Endpoints"
Selector:                 app=web-ahsgdf
TargetPort:               80/TCP
Endpoints:
$ kubectl get pod -n s14-lab dns-test
NAME       READY   STATUS             RESTARTS   AGE
dns-test   0/1     ImagePullBackOff   0          4m2s
$ kubectl describe pod -n s14-lab dns-test | grep -m1 "Failed to pull"
  Warning  Failed     53s (x5 over 4m)     kubelet            Failed to pull image "registry.k8s.io/e2e-test-images/dnsutils:1.3": rpc error: code = NotFound desc = ... registry.k8s.io/e2e-test-images/dnsutils:1.3: not found
```

**Bug 1, `service.yaml`:** selector is `app: web-ahsgdf` (looks like a keyboard slip), Pods are `app=web`, so endpoints are `<none>`. Fixed the selector to `app: web`.

**Bug 2, `dns-test-pod.yaml`:** `registry.k8s.io/e2e-test-images/dnsutils:1.3` does not exist. The image the Kubernetes DNS debugging docs use is `jessie-dnsutils:1.3`. Fixed that too.

Before fixing the Service I used the working DNS pod to prove that **DNS was not the problem**:

```bash
$ kubectl apply -n s14-lab -f dns-test-pod.yaml
pod/dns-test created
$ kubectl exec -n s14-lab dns-test -- nslookup web-service
Server:		10.96.0.10
Address:	10.96.0.10#53

Name:	web-service.s14-lab.svc.cluster.local
Address: 10.101.118.224

$ kubectl exec -n s14-lab dns-test -- wget -qO- -T 3 http://web-service
error: Internal error occurred: ... exec: "wget": executable file not found in $PATH
$ kubectl run -n s14-lab http-test --rm -i --restart=Never --image=busybox:1.36 -- wget -qO- -T 3 http://web-service
All commands and output from this session will be recorded in container logs, including credentials and sensitive information passed through the command prompt.
If you don't see a command prompt, try pressing enter.
wget: can't connect to remote host (10.101.118.224): Connection refused
pod "http-test" deleted from s14-lab namespace
pod s14-lab/http-test terminated (Error)
```

The name resolves to the ClusterIP even with zero endpoints, because a Service gets its DNS record and IP as soon as it exists. The HTTP request then fails with `Connection refused`, which is kube-proxy rejecting traffic to a Service with no backends. That is the README's "do not immediately blame DNS" point, reproduced for real. (`jessie-dnsutils` has no `wget` or `curl`, only `nslookup`/`dig`, so the HTTP test went through a throwaway busybox Pod.)

After the selector fix:

```bash
$ kubectl apply -n s14-lab -f service.yaml
service/web-service configured
$ kubectl get endpointslices -n s14-lab -l kubernetes.io/service-name=web-service
NAME                ADDRESSTYPE   PORTS   ENDPOINTS                   AGE
web-service-fr5sh   IPv4          80      10.244.0.109,10.244.0.111   4m35s
$ kubectl run -n s14-lab http-test --rm -i --restart=Never --image=busybox:1.36 -- wget -qO- -T 3 http://web-service 2>/dev/null | grep title
<title>Welcome to nginx!</title>
$ kubectl exec -n s14-lab dns-test -- cat /etc/resolv.conf
search s14-lab.svc.cluster.local svc.cluster.local cluster.local
nameserver 10.96.0.10
options ndots:5
$ kubectl get pods -n kube-system -l k8s-app=kube-dns
NAME                       READY   STATUS    RESTARTS      AGE
coredns-559f6c778d-cnqtt   1/1     Running   3 (40m ago)   18d
$ kubectl logs -n kube-system -l k8s-app=kube-dns --tail=5
[INFO] 10.244.0.119:50199 - 51752 "A IN web-service.s14-lab.svc.cluster.local.svc.cluster.local. udp 73 false 512" NXDOMAIN qr,aa,rd 166 0.000089491s
[INFO] 10.244.0.119:36663 - 63252 "A IN web-service.s14-lab.svc.cluster.local.cluster.local. udp 69 false 512" NXDOMAIN qr,aa,rd 162 0.000072137s
[INFO] 10.244.0.119:55703 - 38091 "A IN web-service.s14-lab.svc.cluster.local. udp 55 false 512" NOERROR qr,aa,rd 108 0.000288479s
...
```

The CoreDNS log shows `ndots:5` in action: the full name only has 4 dots, so the resolver first tries it with each search suffix appended (two NXDOMAINs) before trying it as-is and getting `NOERROR`. Harmless here, but it is why apps doing lots of external lookups add a trailing dot or lower `ndots`.

Then the intended exercise, `broken-service.yaml`:

```bash
$ kubectl apply -n s14-lab -f broken-service.yaml
service/broken-service created
$ kubectl get endpoints -n s14-lab broken-service web-service
NAME             ENDPOINTS                         AGE
broken-service   <none>                            0s
web-service      10.244.0.109:80,10.244.0.111:80   4m42s
$ kubectl get pods -n s14-lab -l app=does-not-exist
No resources found in s14-lab namespace.
$ kubectl delete service -n s14-lab broken-service
service "broken-service" deleted from s14-lab namespace
```

Running `get pods -l <the service's selector>` is the quickest way to see what a Service would match. Empty list, empty endpoints.

📸 `screenshots/03-service-dns.png`

---

## 8. The triage gauntlet (`scenarios/`)

```bash
$ export KUBECONFIG=~/hwtools/s14.kubeconfig   # private copy, default namespace = s14-scenarios
$ bash triage_all.sh
...
pod/fail-1-crashloop-pod created
pod/fail-2-imagepull-pod created
pod/fail-3-pending-pod created
pod/fail-4-dns-failure-pod created
pod/fail-5-oomkilled-pod created
...
$ kubectl get pods -l tier=triage-gauntlet
NAME                     READY   STATUS             RESTARTS      AGE
fail-1-crashloop-pod     0/1     Error              2 (36s ago)   46s
fail-2-imagepull-pod     0/1     ImagePullBackOff   0             46s
fail-3-pending-pod       0/1     Pending            0             46s
fail-4-dns-failure-pod   1/1     Running            0             45s
fail-5-oomkilled-pod     0/1     OOMKilled          2 (26s ago)   45s
```

Four of them look broken. The scariest one is #4, which says `1/1 Running`. There were no fixed manifests in this folder, so I wrote a `fixed.yaml` in each scenario directory.

**Diagnosis:**

```bash
$ kubectl logs fail-1-crashloop-pod
[FATAL ERROR]: DATABASE_URL environment variable is MISSING!
$ kubectl describe pod fail-2-imagepull-pod | grep -m1 "Failed to pull"
  Warning  Failed     19s (x2 over 44s)  kubelet            Failed to pull image "yatri-api-service:v999-invalid-tag-does-not-exist": ... pull access denied, repository does not exist or may require authorization: server message: insufficient_scope: authorization failed
$ kubectl describe pod fail-3-pending-pod | grep FailedScheduling | head -n1
  Warning  FailedScheduling  54s   default-scheduler  0/1 nodes are available: 1 Insufficient cpu, 1 Insufficient memory. preemption: 0/1 nodes are available: 1 Preemption is not helpful for scheduling.
$ kubectl logs fail-4-dns-failure-pod
Attempting connection to internal database...
Process sleeping...
$ kubectl exec fail-4-dns-failure-pod -- nslookup postgres-db-wrong-name.production.svc.cluster.local
...
** server can't find postgres-db-wrong-name.production.svc.cluster.local: NXDOMAIN
command terminated with exit code 1
$ kubectl describe pod fail-5-oomkilled-pod | grep -A5 "Last State"
    Last State:     Terminated
      Reason:       OOMKilled
      Exit Code:    137
      Started:      Wed, 07 Oct 2026 17:16:27 +0000
      Finished:     Wed, 07 Oct 2026 17:16:27 +0000
$ kubectl get pod fail-5-oomkilled-pod -o jsonpath="{.spec.containers[0].resources}"; echo
{"limits":{"memory":"20Mi"},"requests":{"memory":"20Mi"}}
```

📸 `screenshots/04-triage-gauntlet.png`

| # | Symptom | Found with | Root cause | Fix (`fixed.yaml`) |
| --- | --- | --- | --- | --- |
| 1 | `Error` / CrashLoopBackOff, restarts climbing | `logs` | `DATABASE_URL` not set, app does `sys.exit(1)` | Add the env var **and** keep the process running (see below) |
| 2 | `ImagePullBackOff` | `describe` events | `docker.io/library/yatri-api-service` does not exist at all ("repository does not exist") | No public image exists, so `nginx:1.27` stands in |
| 3 | `Pending`, `NODE <none>` | `describe` events + `describe node` | Requests 500 CPU / 1000Gi; `describe node` shows Allocatable 24 CPU / 7978676Ki (~7.6Gi) | Request `100m` / `64Mi` |
| 4 | `Running`, but does nothing useful | `logs` (suspiciously quiet) + `exec nslookup` | Hostname is NXDOMAIN, no `production` namespace or postgres here, and `curl -s ... \|\| true` swallowed the error | Real `postgres-db` Deployment + Service in this namespace, client points to it, errors not hidden |
| 5 | `OOMKilled`, exit 137 | `describe` Last State | Script allocates 100 x 10MiB = ~1000MiB with a 20Mi limit (the manifest comment says 200MB, which is wrong) | Limit 1200Mi, request 1100Mi |

**Fixing them:**

```bash
$ kubectl delete pod fail-1-crashloop-pod --grace-period=1
$ kubectl apply -f scenario-1-crashloop/fixed.yaml      # first version: env var only
pod/fail-1-crashloop-pod created
$ kubectl get pod fail-1-crashloop-pod
NAME                   READY   STATUS      RESTARTS      AGE
fail-1-crashloop-pod   0/1     Completed   2 (29s ago)   30s
$ kubectl logs fail-1-crashloop-pod
Application started successfully!
```

The first fix was not enough. With the env var set the app succeeds, prints its line and exits 0, and because a Pod's `restartPolicy` is `Always`, it gets restarted forever anyway (`Completed` with restarts going up). A Pod is meant to run a long-lived process, so I changed `fixed.yaml` to keep the process running after start-up:

```bash
$ kubectl apply -f scenario-1-crashloop/fixed.yaml      # second version: env var + stays running
pod/fail-1-crashloop-pod created
$ kubectl get pod fail-1-crashloop-pod
NAME                   READY   STATUS    RESTARTS   AGE
fail-1-crashloop-pod   1/1     Running   0          25s

$ kubectl set image pod/fail-2-imagepull-pod web-app=nginx:1.27
pod/fail-2-imagepull-pod image updated
$ kubectl get pod fail-2-imagepull-pod
NAME                   READY   STATUS    RESTARTS   AGE
fail-2-imagepull-pod   1/1     Running   0          3m11s
```

For #2 I tried a live fix first: `image` is one of the few fields you can change on a running Pod, so `kubectl set image` fixed it in place without a delete. I still recreated it from `fixed.yaml` afterwards so the file matches the cluster. Resource requests are **not** mutable on a Pod, so #3 had to be deleted and recreated.

```bash
$ kubectl apply -f scenario-4-dns-failure/fixed.yaml
deployment.apps/postgres-db created
service/postgres-db created
pod/fail-4-dns-failure-pod created
$ kubectl exec fail-4-dns-failure-pod -- nslookup postgres-db.s14-scenarios.svc.cluster.local
...
Name:	postgres-db.s14-scenarios.svc.cluster.local
Address: 10.109.241.217
$ kubectl logs fail-4-dns-failure-pod
Attempting connection to internal database...
postgres-db:5432 not reachable yet, retrying in 3s
Connected: postgres-db.s14-scenarios.svc.cluster.local:5432 is reachable
Process sleeping...

$ kubectl apply -f scenario-5-oomkilled/fixed.yaml
pod/fail-5-oomkilled-pod created
$ kubectl logs fail-5-oomkilled-pod
Allocating memory rapidly...
Allocated 1000 MiB without being killed
$ kubectl top pod fail-5-oomkilled-pod
NAME                   CPU(cores)   MEMORY(bytes)
fail-5-oomkilled-pod   0m           1005Mi

$ kubectl get pods -l tier=triage-gauntlet
NAME                     READY   STATUS    RESTARTS   AGE
fail-1-crashloop-pod     1/1     Running   0          103s
fail-2-imagepull-pod     1/1     Running   0          63s
fail-3-pending-pod       1/1     Running   0          58s
fail-4-dns-failure-pod   1/1     Running   0          39s
fail-5-oomkilled-pod     1/1     Running   0          21s
```

All five healthy. For #4 the "production" namespace was out of scope on this shared cluster, so the fix creates the database the client expects in its own namespace. The retry loop also shows the client waiting for postgres to come up instead of silently giving up. For #5 `top` confirms it really uses ~1005Mi, so raising the limit was right here. With a real memory leak the answer would be to fix the leak, not keep raising the limit. I deleted the #5 pod afterwards since it holds 1.2Gi on a shared node.

---

## 9. Mini-project: troubleshooting challenge

```bash
$ kubectl create namespace s14-mini
$ kubectl apply -n s14-mini -f deployment.yaml -f service.yaml
deployment.apps/troubleshooting-app created
service/troubleshooting-service created
$ kubectl get pods,svc -n s14-mini -o wide
NAME                                       READY   STATUS    RESTARTS   AGE   IP             NODE       NOMINATED NODE   READINESS GATES
pod/troubleshooting-app-59d4957864-nggh9   1/1     Running   0          1s    10.244.0.134   minikube   <none>           <none>
pod/troubleshooting-app-59d4957864-ngzx4   1/1     Running   0          1s    10.244.0.135   minikube   <none>           <none>

NAME                              TYPE        CLUSTER-IP       EXTERNAL-IP   PORT(S)   AGE   SELECTOR
service/troubleshooting-service   ClusterIP   10.109.134.165   <none>        80/TCP    1s    app=troubleshooting-app
$ kubectl exec -n s14-mini troubleshooting-app-59d4957864-nggh9 -- curl -s localhost | grep title
<title>Welcome to nginx!</title>
$ kubectl get endpoints -n s14-mini troubleshooting-service
NAME                      ENDPOINTS                         AGE
troubleshooting-service   10.244.0.134:80,10.244.0.135:80   2s
```

Baseline healthy. Then the broken Pod:

```bash
$ kubectl apply -n s14-mini -f broken-pod.yaml
pod/project-broken-pod created
$ kubectl get pod -n s14-mini project-broken-pod
NAME                 READY   STATUS             RESTARTS   AGE
project-broken-pod   0/1     ImagePullBackOff   0          26s
$ kubectl events -n s14-mini --for pod/project-broken-pod --types=Warning
LAST SEEN   TYPE      REASON   OBJECT                   MESSAGE
49s         Warning   Failed   Pod/project-broken-pod   Failed to pull image "nginx:this-tag-does-not-exist": ... failed to authorize: failed to fetch anonymous token: Get "https://auth.docker.io/token?...": dial tcp: lookup auth.docker.io on 192.168.65.254:53: server misbehaving
49s         Warning   Failed   Pod/project-broken-pod   Error: ErrImagePull
48s         Warning   Failed   Pod/project-broken-pod   Error: ImagePullBackOff
19s         Warning   Failed   Pod/project-broken-pod   Failed to pull image "nginx:this-tag-does-not-exist": rpc error: code = NotFound desc = ... docker.io/library/nginx:this-tag-does-not-exist: not found
19s         Warning   Failed   Pod/project-broken-pod   Error: ErrImagePull
18s         Warning   Failed   Pod/project-broken-pod   Error: ImagePullBackOff
```

This was a lucky accident. The first pull attempt (from my first apply of this Pod) failed because the node briefly could not resolve `auth.docker.io`, a network problem. The second attempt reached Docker Hub and got the real answer, `not found`. Same `ImagePullBackOff` status, two completely different root causes, and only the message tells them apart. A network error would mean fixing the node's DNS or proxy, while `not found` means fixing the tag. You have to read the message, not just the status.

```bash
$ kubectl delete pod -n s14-mini project-broken-pod --grace-period=1 && kubectl apply -n s14-mini -f fixed-pod.yaml
pod "project-broken-pod" deleted from s14-mini namespace
pod/project-broken-pod created
$ kubectl get pod -n s14-mini project-broken-pod
NAME                 READY   STATUS    RESTARTS   AGE
project-broken-pod   1/1     Running   0          5s
```

**Service selector challenge.** Instead of editing the file I changed the live selector:

```bash
$ kubectl set selector service -n s14-mini troubleshooting-service app=wrong-app
service/troubleshooting-service selector updated
$ kubectl get endpoints -n s14-mini troubleshooting-service
NAME                      ENDPOINTS   AGE
troubleshooting-service   <none>      2m4s
$ kubectl run -n s14-mini http-test --rm -i --restart=Never --image=busybox:1.36 -- wget -qO- -T 3 http://troubleshooting-service 2>&1 | grep -v -e "^All commands" -e "^If you"
wget: can't connect to remote host (10.109.134.165): Connection refused
pod "http-test" deleted from s14-mini namespace
pod s14-mini/http-test terminated (Error)
$ kubectl get pods -n s14-mini --show-labels
NAME                                   READY   STATUS    RESTARTS   AGE    LABELS
project-broken-pod                     1/1     Running   0          9s     <none>
troubleshooting-app-59d4957864-nggh9   1/1     Running   0          2m7s   app=troubleshooting-app,pod-template-hash=59d4957864
troubleshooting-app-59d4957864-ngzx4   1/1     Running   0          2m7s   app=troubleshooting-app,pod-template-hash=59d4957864
$ kubectl describe service -n s14-mini troubleshooting-service | grep Selector
Selector:                 app=wrong-app
$ kubectl apply -n s14-mini -f service.yaml
service/troubleshooting-service configured
$ kubectl get endpoints -n s14-mini troubleshooting-service
NAME                      ENDPOINTS                         AGE
troubleshooting-service   10.244.0.134:80,10.244.0.135:80   2m10s
$ kubectl run -n s14-mini http-test --rm -i --restart=Never --image=busybox:1.36 -- wget -qO- -T 3 http://troubleshooting-service 2>&1 | grep title
<title>Welcome to nginx!</title>
```

📸 `screenshots/05-mini-project.png`

### Answers to section 7 (broken Pod)

1. **Status:** `ErrImagePull`, then `ImagePullBackOff`, `READY 0/1`, `RESTARTS 0`.
2. **Actual error:** `docker.io/library/nginx:this-tag-does-not-exist: not found` (plus one earlier transient `lookup auth.docker.io ... server misbehaving`).
3. **Command:** `kubectl describe pod` / `kubectl events --for pod/project-broken-pod`, the Events part.
4. **What is wrong with the image:** the `nginx` repository is fine, the tag `this-tag-does-not-exist` is not published.
5. **Fix:** use a real tag (`nginx:1.27`, in `fixed-pod.yaml`), delete and recreate the Pod (or `kubectl set image` it live).

### Troubleshooting table

| Problem | What I saw | Command I used | Root cause | Fix |
| :--- | :--- | :--- | :--- | :--- |
| **Broken Pod** | `ImagePullBackOff`, 0 restarts | `describe` / `events --for` | Tag does not exist on Docker Hub | `fixed-pod.yaml` with `nginx:1.27` |
| **Service Problem** | Endpoints `<none>`, `Connection refused` from inside the cluster | `get endpoints`, `get pods --show-labels`, `describe service` | Selector `app=wrong-app` vs Pod label `app=troubleshooting-app` | Re-applied `service.yaml` (selector `app: troubleshooting-app`) |
| **Image Problem** | Same status, two different messages | `events --types=Warning` | One transient DNS failure to `auth.docker.io`, then the real `not found` | Fix the tag. The network one would have needed no YAML change |

### README questions, in my words

1. **What does `kubectl get` tell us?** The current state at a glance: is it running, is it ready, how often has it restarted. It says *what*, never *why*.
2. **`get` vs `describe`?** `get` is one line per object. `describe` is everything about one object, including conditions and the recent events, which is where the *why* usually is.
3. **Why `kubectl logs`?** It is what the app itself printed. Kubernetes can tell you the container exited 1, only the app can tell you it was a missing env var.
4. **When `kubectl exec`?** When the container is running but something is off, to test from the inside: `curl localhost`, check files and env, `nslookup`. Useless for Pending or crash-looping Pods since there is nothing stable to enter.
5. **CrashLoopBackOff?** The container keeps starting and exiting, and the kubelet is waiting longer and longer between restarts. It is a symptom; the cause is in the logs or the exit code (1 = app error, 137 = killed, often OOM).
6. **ImagePullBackOff?** The kubelet could not get the image and is backing off between retries. The event message says whether it is a bad tag, a missing repo, auth, or the network.
7. **Why Pending?** The scheduler cannot place it: not enough CPU/memory requests left, nodeSelector/affinity matches nothing, a taint with no toleration, or an unbound PVC. `NODE <none>` + `FailedScheduling` event.
8. **Why can a Service have no endpoints?** Its selector matches no Pods (typo, wrong label), or the matching Pods are not Ready (failing readiness probe).
9. **Selector vs labels?** The Service's selector is a label query. Every Ready Pod whose labels contain all the selector's key/values becomes an endpoint. That is the only link between them, there is no reference by name.
10. **What is Kubernetes DNS?** CoreDNS running in `kube-system`, which gives every Service a name `<svc>.<ns>.svc.cluster.local` pointing at its ClusterIP. Pods use it through the `nameserver 10.96.0.10` and search domains in their `/etc/resolv.conf`.

---

## 10. My golden troubleshooting flow

What I actually do now, after breaking things for a whole session:

1. **`kubectl get pods -o wide`** and read three columns. `STATUS` tells me which branch I am in, `RESTARTS` going up means it starts and dies, `NODE <none>` means it never got scheduled.
2. **`kubectl describe` / `kubectl events --for pod/<name>`**, scroll to the Warnings, and read the **whole message**. `ImagePullBackOff` can be a bad tag or a DNS outage; only the message says which.
3. **Not scheduled (Pending)?** Stop there: compare the `FailedScheduling` reason with `describe node` (Allocatable, labels, taints). No logs exist.
4. **Started and died?** `kubectl logs`, and the exit code from `lastState.terminated`. 1 means the app gave up (read its logs), 137 with `OOMKilled` means memory limit. Use `--previous` only once a new container is running.
5. **Running but "not working"?** Do not trust `Running`. `exec` in and `curl localhost`. If that works, move outwards one hop at a time: Pod IP → `get endpoints` / `--show-labels` vs selector → `nslookup` the Service name → call the Service from a throwaway Pod.
6. **Separate DNS from routing.** If `nslookup` gives an IP but the request gets `Connection refused`, DNS is fine and the Service has no backends. If it is `NXDOMAIN`, the name or namespace is wrong.
7. **Fix the manifest, not just the cluster.** A live `set image` / `set selector` is fine to confirm the theory, then put the same change in the YAML and re-apply, so the next deploy does not bring the bug back.
8. **Verify the fix completely.** `1/1 Running` with `RESTARTS 0` a minute later, endpoints populated, and a real request getting a real response. My first scenario-1 fix "worked" and was still restarting.

---

## Manifest index

| Path | What it is |
| --- | --- |
| `01-kubectl-get/pod.yaml` | nginx Pod for `get` / `get -w` |
| `02-kubectl-describe/demo-pod.yaml` | nginx Pod for `describe` (the folder README calls it `pod.yaml`) |
| `03-kubectl-logs/pod.yaml` | busybox that prints startup lines then a heartbeat |
| `04-kubectl-exec/pod.yaml`, `05-events/pod.yaml` | Plain nginx Pods |
| `06-crashloopbackoff/` | `broken-pod.yaml` (`exit 1`) and `fixed-pod.yaml` |
| `07-imagepullbackoff/` | Bad tag vs `nginx:1.27` |
| `08-pending-pods/` | nodeSelector for a non-existent node vs none |
| `09-service-dns-troubleshooting/service.yaml` | **Fixed:** selector `app: web-ahsgdf` → `app: web` |
| `09-service-dns-troubleshooting/dns-test-pod.yaml` | **Fixed:** image `dnsutils:1.3` (does not exist) → `jessie-dnsutils:1.3` |
| `09-service-dns-troubleshooting/broken-service.yaml`, `deployment.yaml` | Intentionally wrong selector; 2-replica `web` Deployment |
| `scenarios/scenario-*/broken.yaml`, `triage_all.sh` | The five gauntlet Pods and the script that applies them |
| `scenarios/scenario-*/fixed.yaml` | **Added:** my fix for each scenario |
| `mini-project/` | Deployment, Service, `broken-pod.yaml`, plus **added** `fixed-pod.yaml` |
| `screenshots/` | 5 terminal captures referenced above |

---

## Resources

- Original session README: <https://github.com/Nency-Ravaliya/devops-heros/blob/main/session-14-kubernetes-troubleshooting/README.md>
- <https://kubernetes.io/docs/tasks/debug/debug-application/debug-pods/>
- <https://kubernetes.io/docs/tasks/debug/debug-application/debug-service/>
- <https://kubernetes.io/docs/tasks/administer-cluster/dns-debugging-resolution/>
- <https://kubernetes.io/docs/concepts/workloads/pods/pod-lifecycle/#container-restarts>
