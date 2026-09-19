# Session 10: Kubernetes Core Objects & Deployment Strategies

Worked through the core objects (Pod, ReplicaSet, Deployment) and the deployment strategies from the session folders. Everything below is copied straight from my terminal.

**Setup:** Windows 11, Minikube v1.39.0 with the Docker driver, Kubernetes v1.37.0, containerd.

> **Note:** with the Docker driver the host cannot reach `$(minikube ip):<nodePort>`, so the NodePort checks below are run from inside the node with `minikube ssh "curl -s http://localhost:<nodePort>"`. Same kube-proxy path. More on this in Session 11, section 7.

---

## 1. Cluster health

```bash
$ kubectl cluster-info
Kubernetes control plane is running at https://127.0.0.1:52672
CoreDNS is running at https://127.0.0.1:52672/api/v1/namespaces/kube-system/services/kube-dns:dns/proxy

To further debug and diagnose cluster problems, use 'kubectl cluster-info dump'.

$ kubectl get nodes -o wide
NAME       STATUS   ROLES           AGE   VERSION   INTERNAL-IP    EXTERNAL-IP   OS-IMAGE                         KERNEL-VERSION                              CONTAINER-RUNTIME
minikube   Ready    control-plane   57m   v1.37.0   192.168.49.2   <none>        Debian GNU/Linux 12 (bookworm)   6.18.33.1-microsoft-standard-WSL2 (amd64)   containerd://2.3.4
```

---

## 2. Pod: create, inspect, delete (`pod.yml`)

```bash
$ kubectl apply -f pod.yml
pod/nginx-pod created

$ kubectl get pods
NAME        READY   STATUS    RESTARTS   AGE
nginx-pod   1/1     Running   0          3s

$ kubectl get pods -o wide
NAME        READY   STATUS    RESTARTS   AGE   IP            NODE       NOMINATED NODE   READINESS GATES
nginx-pod   1/1     Running   0          4s    10.244.0.95   minikube   <none>           <none>

$ kubectl logs nginx-pod
10-listen-on-ipv6-by-default.sh: info: Getting the checksum of /etc/nginx/conf.d/default.conf
10-listen-on-ipv6-by-default.sh: info: Enabled listen on IPv6 in /etc/nginx/conf.d/default.conf
2026/09/19 15:07:34 [notice] 1#1: using the "epoll" event method
2026/09/19 15:07:34 [notice] 1#1: nginx/1.31.6
2026/09/19 15:07:34 [notice] 1#1: built by gcc 14.2.0 (Debian 14.2.0-19) 
2026/09/19 15:07:34 [notice] 1#1: OS: Linux 6.18.33.1-microsoft-standard-WSL2
2026/09/19 15:07:34 [notice] 1#1: getrlimit(RLIMIT_NOFILE): 1048576:1048576
2026/09/19 15:07:34 [notice] 1#1: start worker processes

$ kubectl delete -f pod.yml
pod "nginx-pod" deleted from default namespace
```

The pod got IP `10.244.0.3` from the CNI and was scheduled onto the `minikube` node. The four top-level fields you always need are `apiVersion`, `kind`, `metadata` and `spec`.

📸 `screenshots/01-pod-operations.png`

---

## 3. ImagePullBackOff: what happens with a bad image

Applied `pod-lifecycle/06-imagepullbackoff.yaml`, which points at a made-up image name, `jakwehrgkaejw:kahsdfgkhj`.

```bash
$ kubectl get pod lifecycle-image-error
pod/lifecycle-image-error created
NAME                    READY   STATUS         RESTARTS   AGE
lifecycle-image-error   0/1     ErrImagePull   0          10s

$ kubectl describe pod lifecycle-image-error | grep -A 10 Events:
Events:
  Type     Reason     Age   From               Message
  ----     ------     ----  ----               -------
  Normal   Scheduled  11s   default-scheduler  Successfully assigned default/lifecycle-image-error to minikube
  Normal   Pulling    11s   kubelet            Pulling image "jakwehrgkaejw:kahsdfgkhj"
  Warning  Failed     9s    kubelet            Failed to pull image "jakwehrgkaejw:kahsdfgkhj": failed to pull and unpack image "docker.io/library/jakwehrgkaejw:kahsdfgkhj": failed to resolve reference "docker.io/library/jakwehrgkaejw:kahsdfgkhj": pull access denied, repository does not exist or may require authorization: server message: insufficient_scope: authorization failed
  Warning  Failed     9s    kubelet            Error: ErrImagePull
  Normal   BackOff    9s    kubelet            Back-off pulling image "jakwehrgkaejw:kahsdfgkhj"
  Warning  Failed     9s    kubelet            Error: ImagePullBackOff
pod "lifecycle-image-error" deleted from default namespace
```

**So why did `apply` say "created" if the image does not exist?** Because `apply` only has to get past the API server, which checks authentication, authorisation, admission and the schema. None of those steps contact a registry. Once the object passes, it is written to etcd and you get `created` back.

The image pull happens later, on the node, done by the kubelet. When that fails there is no way to report it back to a command that already finished, so it shows up as status instead. First `ErrImagePull`, then `ImagePullBackOff` once the kubelet starts backing off between retries (10s, then 20s, then 40s, and so on up to 5 minutes).

📸 `screenshots/02-imagepullbackoff.png`

---

## 4. Pod lifecycle phases (`hello.yml`)

A busybox container with `restartPolicy: Never`. I polled it twice a second and used awk to print only the lines where STATUS changed:

```bash
$ kubectl apply -f hello.yml
$ for i in $(seq 1 40); do kubectl get pod hello-pod --no-headers; sleep 0.5; done | awk '!seen[$3]++'
pod/hello-pod created
hello-pod   0/1   ContainerCreating   0     0s
hello-pod   1/1   Running   0     2s
hello-pod   0/1   Completed   0     3s

$ kubectl logs hello-pod
Hello Kubernetes

Succeeded
pod "hello-pod" deleted from default namespace
```

Caught all three states: `ContainerCreating`, then `Running`, then `Completed`. The whole thing takes about 3 seconds, so polling twice a second is just fast enough. `Completed` is the container state that `kubectl get` prints, while the Pod phase stored in the API is `Succeeded`, which is what the second command shows.

---

## 5. Pending and CrashLoopBackOff

### Pending: nothing can schedule it

`pod-lifecycle/02-pending.yaml` requests 9Gi of memory:

```bash
pod/lifecycle-pending created
NAME                READY   STATUS    RESTARTS   AGE
lifecycle-pending   0/1     Pending   0          11s

Events:
  Type     Reason            Age   From               Message
  ----     ------            ----  ----               -------
  Warning  FailedScheduling  10s   default-scheduler  0/1 nodes are available: 1 Insufficient memory. preemption: 0/1 nodes are available: 1 Preemption is not helpful for scheduling.
pod "lifecycle-pending" deleted from default namespace
```

The Pod object does exist in etcd, but `spec.nodeName` never gets set. The scheduler's filter phase rules out the only node there is, so the pod just sits at `Pending` with a `FailedScheduling` event against it.

### CrashLoopBackOff: container keeps exiting with code 1

`pod-lifecycle/05-crashloopbackoff.yaml` prints a line, sleeps 3 seconds, then exits 1. I polled every 3 seconds to catch the state changes:

```bash
pod/lifecycle-crashloop created
NAME                  READY   STATUS   RESTARTS      AGE
lifecycle-crashloop   0/1     Error    3 (66s ago)   90s

Events:
  Type     Reason     Age                From               Message
  ----     ------     ----               ----               -------
  Normal   Scheduled  91s                default-scheduler  Successfully assigned default/lifecycle-crashloop to minikube
  Normal   Pulled     40s (x4 over 91s)  kubelet            Container image "busybox:1.36" already present on machine and can be accessed by the pod
  Normal   Created    40s (x4 over 91s)  kubelet            Container created
  Normal   Started    39s (x4 over 91s)  kubelet            Container started
  Warning  BackOff    36s (x3 over 83s)  kubelet            Back-off restarting failed container crashing-app in pod lifecycle-crashloop_default(3cdd2012-b2c6-48d6-a012-665593a1af9c)

--- container logs ---
Application started
Application crashed
pod "lifecycle-crashloop" deleted from default namespace
```

`Error` and `CrashLoopBackOff` alternate. `Error` is the moment the container exits, `CrashLoopBackOff` is the wait before the kubelet retries, so a poll can land on either. The `Back-off restarting failed container` event is the proof the loop is running, and `RESTARTS` climbing slowly shows the backoff stretching. It doubles each restart (10s, 20s, 40s) up to a 5 minute cap.

`kubectl logs` shows what the app printed before it died. `--previous` is the usual flag here since the current container is dead, but on this containerd setup the old log file is already gone by then.

📸 `screenshots/03-pending-crashloop.png`

---

## 6. ReplicaSet: self-healing (`replicaset.yml`)

```bash
$ kubectl apply -f replicaset.yml
$ kubectl get rs nginx-rs
$ kubectl get pods -l app=nginx
replicaset.apps/nginx-rs created
NAME       DESIRED   CURRENT   READY   AGE
nginx-rs   3         3         3       20s

NAME             READY   STATUS    RESTARTS   AGE
nginx-rs-5wwb4   1/1     Running   0          21s
nginx-rs-bs8p2   1/1     Running   0          21s
nginx-rs-dn9ks   1/1     Running   0          21s
```

Deleted one pod by hand to test the reconciliation loop:

```bash
Deleting pod: nginx-rs-5wwb4
pod "nginx-rs-5wwb4" deleted from default namespace

--- immediately after deletion ---
NAME             READY   STATUS              RESTARTS   AGE
nginx-rs-bs8p2   1/1     Running             0          23s
nginx-rs-dn9ks   1/1     Running             0          23s
nginx-rs-vcf9w   0/1     ContainerCreating   0          1s

--- 12s later, back to 3 ---
NAME             READY   STATUS    RESTARTS   AGE
nginx-rs-bs8p2   1/1     Running   0          35s
nginx-rs-dn9ks   1/1     Running   0          35s
nginx-rs-vcf9w   1/1     Running   0          13s
replicaset.apps "nginx-rs" deleted from default namespace
```

The ReplicaSet controller notices that the number of matching pods no longer equals `spec.replicas` and creates a replacement almost instantly. The replacement comes back with a **completely new random suffix**, which is the thing to notice here: with a ReplicaSet or Deployment, pod identity is throwaway. Session 11 covers StatefulSets, where it works the opposite way.

---

## 7. Rolling update and rollback (`01-rolling-update/`)

4 replicas, `maxSurge: 1`, `maxUnavailable: 0`.

```bash
$ kubectl apply -f 01-rolling-update/deployment-v1.yaml
$ kubectl apply -f 01-rolling-update/service.yaml
$ kubectl rollout status deployment/app-rolling
deployment.apps/app-rolling created
service/app-rolling-service created
Waiting for deployment "app-rolling" rollout to finish: 0 of 4 updated replicas are available...
Waiting for deployment "app-rolling" rollout to finish: 1 of 4 updated replicas are available...
Waiting for deployment "app-rolling" rollout to finish: 2 of 4 updated replicas are available...
Waiting for deployment "app-rolling" rollout to finish: 3 of 4 updated replicas are available...
deployment "app-rolling" successfully rolled out

NAME                           READY   STATUS    RESTARTS   AGE   LABELS
app-rolling-86d7d44d5b-7mz2t   1/1     Running   0          7s    app=app-rolling,pod-template-hash=86d7d44d5b,version=v1
app-rolling-86d7d44d5b-lb5hp   1/1     Running   0          7s    app=app-rolling,pod-template-hash=86d7d44d5b,version=v1
app-rolling-86d7d44d5b-zlzdf   1/1     Running   0          7s    app=app-rolling,pod-template-hash=86d7d44d5b,version=v1
app-rolling-86d7d44d5b-znwt6   1/1     Running   0          7s    app=app-rolling,pod-template-hash=86d7d44d5b,version=v1
```

```bash
$ kubectl apply -f 01-rolling-update/deployment-v2.yaml
$ kubectl rollout status deployment/app-rolling
deployment.apps/app-rolling configured
Waiting for deployment "app-rolling" rollout to finish: 1 out of 4 new replicas have been updated...
Waiting for deployment "app-rolling" rollout to finish: 1 out of 4 new replicas have been updated...
Waiting for deployment "app-rolling" rollout to finish: 1 out of 4 new replicas have been updated...
Waiting for deployment "app-rolling" rollout to finish: 2 out of 4 new replicas have been updated...
Waiting for deployment "app-rolling" rollout to finish: 2 out of 4 new replicas have been updated...
Waiting for deployment "app-rolling" rollout to finish: 2 out of 4 new replicas have been updated...
Waiting for deployment "app-rolling" rollout to finish: 2 out of 4 new replicas have been updated...
Waiting for deployment "app-rolling" rollout to finish: 3 out of 4 new replicas have been updated...
Waiting for deployment "app-rolling" rollout to finish: 3 out of 4 new replicas have been updated...
Waiting for deployment "app-rolling" rollout to finish: 3 out of 4 new replicas have been updated...
Waiting for deployment "app-rolling" rollout to finish: 3 out of 4 new replicas have been updated...
Waiting for deployment "app-rolling" rollout to finish: 1 old replicas are pending termination...
Waiting for deployment "app-rolling" rollout to finish: 1 old replicas are pending termination...
Waiting for deployment "app-rolling" rollout to finish: 1 old replicas are pending termination...
deployment "app-rolling" successfully rolled out

NAME                           READY   STATUS        RESTARTS   AGE   LABELS
app-rolling-56bff6d88c-46cnh   1/1     Running       0          26s   app=app-rolling,pod-template-hash=56bff6d88c,version=v2
app-rolling-56bff6d88c-5kf9q   1/1     Running       0          12s   app=app-rolling,pod-template-hash=56bff6d88c,version=v2
app-rolling-56bff6d88c-5wls6   1/1     Running       0          19s   app=app-rolling,pod-template-hash=56bff6d88c,version=v2
app-rolling-56bff6d88c-z7nln   1/1     Running       0          6s    app=app-rolling,pod-template-hash=56bff6d88c,version=v2
app-rolling-86d7d44d5b-lb5hp   1/1     Terminating   0          34s   app=app-rolling,pod-template-hash=86d7d44d5b,version=v1
```

```bash
$ kubectl rollout history deployment/app-rolling
deployment.apps/app-rolling 
REVISION  CHANGE-CAUSE
1         <none>
2         <none>

$ kubectl rollout undo deployment/app-rolling
deployment.apps/app-rolling rolled back
Waiting for deployment "app-rolling" rollout to finish: 1 out of 4 new replicas have been updated...
Waiting for deployment "app-rolling" rollout to finish: 1 out of 4 new replicas have been updated...
Waiting for deployment "app-rolling" rollout to finish: 1 out of 4 new replicas have been updated...
Waiting for deployment "app-rolling" rollout to finish: 2 out of 4 new replicas have been updated...
Waiting for deployment "app-rolling" rollout to finish: 2 out of 4 new replicas have been updated...
Waiting for deployment "app-rolling" rollout to finish: 2 out of 4 new replicas have been updated...
Waiting for deployment "app-rolling" rollout to finish: 2 out of 4 new replicas have been updated...
Waiting for deployment "app-rolling" rollout to finish: 3 out of 4 new replicas have been updated...
Waiting for deployment "app-rolling" rollout to finish: 3 out of 4 new replicas have been updated...
Waiting for deployment "app-rolling" rollout to finish: 3 out of 4 new replicas have been updated...
Waiting for deployment "app-rolling" rollout to finish: 3 out of 4 new replicas have been updated...
Waiting for deployment "app-rolling" rollout to finish: 1 old replicas are pending termination...
Waiting for deployment "app-rolling" rollout to finish: 1 old replicas are pending termination...
Waiting for deployment "app-rolling" rollout to finish: 1 old replicas are pending termination...
deployment "app-rolling" successfully rolled out
service "app-rolling-service" deleted from default namespace
deployment.apps "app-rolling" deleted from default namespace
```

`maxUnavailable: 0` means all 4 pods keep serving the whole time, and `maxSurge: 1` allows a temporary 5th pod while the swap happens. Behind the scenes the Deployment makes a **second ReplicaSet** for v2 and moves replicas across one at a time, only continuing once each new pod passes its readiness probe.

The rollback is basically instant, and the reason is that the old ReplicaSet was never deleted. It was only scaled down to 0, so `rollout undo` just scales it back up.

📸 `screenshots/04-rolling-update-rollback.png`

---

## 8. Blue-Green cutover (`02-blue-green/`)

Two complete environments running side by side: `app-blue` (v1) and `app-green` (v2), 3 replicas each, with a single Service on nodePort 30020 pointing at one of them.

```bash
$ kubectl apply -f 02-blue-green/deployment-blue.yaml
$ kubectl apply -f 02-blue-green/deployment-green.yaml
$ kubectl get pods -l app=myapp --show-labels
deployment.apps/app-blue created
deployment.apps/app-green created
Waiting for deployment "app-blue" rollout to finish: 0 of 3 updated replicas are available...
Waiting for deployment "app-blue" rollout to finish: 1 of 3 updated replicas are available...
Waiting for deployment "app-blue" rollout to finish: 2 of 3 updated replicas are available...
deployment "app-blue" successfully rolled out
deployment "app-green" successfully rolled out

NAME                        READY   STATUS    RESTARTS   AGE   LABELS
app-blue-5c69d7785c-9spjs   1/1     Running   0          7s    app=myapp,pod-template-hash=5c69d7785c,slot=blue,version=v1
app-blue-5c69d7785c-wsg7p   1/1     Running   0          7s    app=myapp,pod-template-hash=5c69d7785c,slot=blue,version=v1
app-blue-5c69d7785c-x9cmb   1/1     Running   0          7s    app=myapp,pod-template-hash=5c69d7785c,slot=blue,version=v1
app-green-84df7f978-6z5gt   1/1     Running   0          7s    app=myapp,pod-template-hash=84df7f978,slot=green,version=v2
app-green-84df7f978-nwt85   1/1     Running   0          7s    app=myapp,pod-template-hash=84df7f978,slot=green,version=v2
app-green-84df7f978-vvznf   1/1     Running   0          7s    app=myapp,pod-template-hash=84df7f978,slot=green,version=v2
```

Traffic on Blue:

```bash
service/myapp-service created
Selector:                 app=myapp,slot=blue
Warning: v1 Endpoints is deprecated in v1.33+; use discovery.k8s.io/v1 EndpointSlice
NAME            ENDPOINTS                                      AGE
myapp-service   10.244.0.75:80,10.244.0.76:80,10.244.0.77:80   4s
```

Now the actual switch. Apply the Service that has `slot: green`:

```bash
service/myapp-service configured
Selector:                 app=myapp,slot=green
Warning: v1 Endpoints is deprecated in v1.33+; use discovery.k8s.io/v1 EndpointSlice
NAME            ENDPOINTS                                      AGE
myapp-service   10.244.0.78:80,10.244.0.79:80,10.244.0.80:80   10s

GREEN ENVIRONMENT
```

Rollback, by flipping the selector back:

```bash
service/myapp-service configured
BLUE ENVIRONMENT
service "myapp-service" deleted from default namespace
deployment.apps "app-blue" deleted from default namespace
deployment.apps "app-green" deleted from default namespace
```

The only thing that changed in that Service file is the selector going from `slot: blue` to `slot: green`. You can see it in the output: the endpoint IPs are completely different before and after. The endpoints controller recalculates the Endpoints object, kube-proxy rewrites its rules, and all the traffic moves over.

What I find neat about this is that there is **no window where both versions are serving**. In a rolling update, v1 and v2 both take traffic for a few minutes while pods swap over. Here it is all one version, then all the other. The price you pay is running double the compute for the whole release.

📸 `screenshots/05-blue-green-cutover.png`

---

## Concepts writeup

### The 4 ports

```
Client ──► nodePort 30080 (every node's IP, range 30000-32767)
              └─► port 80 (Service ClusterIP, a virtual IP that is on no interface)
                    └─► targetPort 80 (Pod IP)
                          └─► containerPort 80 (the process)
```

`containerPort` is **documentation only**. It does not open a port and it does not firewall anything. The process inside the container listens whether or not you write that field.

### Labels vs Selectors

A **label** is a key/value pair stuck onto an object, like `app: myapp` or `slot: blue`. A **selector** is a query that matches against those labels.

The important bit is that Services and controllers never point at pods by name or UID. They just ask "which pods have these labels right now?" and the answer gets recalculated constantly. That indirection is the whole reason the blue-green switch above works the way it does.

### The 4 deployment strategies

| Strategy | How | Downtime | Extra capacity | Rollback |
| --- | --- | --- | --- | --- |
| **RollingUpdate** | Replace pods gradually, waiting on readiness | None | `maxSurge` | Fast, scale the old RS back up |
| **Recreate** | Kill all old pods, *then* start new ones | **Yes, deliberate** | None | Fast, but also with downtime |
| **Blue-Green** | Two full environments, flip the Service selector | None | **2x** | Instant, flip back |
| **Canary** | Small slice of v2 next to v1 behind one Service | None | about +10% | Instant, scale canary to 0 |

One thing that surprised me about Canary: there is no traffic-weighting setting anywhere. kube-proxy just spreads requests roughly evenly across the Endpoints list, so **the split is simply the ratio of pod counts**. 9 stable pods to 1 canary pod gives you about 90/10. If you want real weighted routing you need a Layer 7 proxy, either Ingress canary annotations or a service mesh.

### maxSurge vs maxUnavailable

For `replicas: 4, maxSurge: 1, maxUnavailable: 0`:
- Max pods at any instant: `4 + 1 = 5`
- Min available at any instant: `4 - 0 = 4`, so you keep 100% capacity the whole way through

When you use percentages they round in opposite directions on purpose, so neither guarantee can be broken: `maxSurge` rounds **up** and `maxUnavailable` rounds **down**. Also, you cannot set both to 0. That config can never make progress, so the API server rejects it.

### Requests vs Limits, GB vs GiB

| | Requests | Limits |
| --- | --- | --- |
| Read by | **kube-scheduler**, to place the pod | **kubelet / cgroups**, at runtime |
| Over CPU | Allowed, bursts into spare capacity | **Throttled**, never killed |
| Over memory | Allowed while the node has room | **OOMKilled**, because memory cannot be throttled |

A pod becomes unschedulable when no node has enough *unreserved requests* left, which is exactly what happened with `02-pending.yaml` earlier.

`1G` is 10^9 bytes. `1Gi` is 2^30, so 1,073,741,824 bytes, which is about 7.4% bigger. Stick to `Mi` and `Gi` for memory. Mixing them up causes OOMKills that only show up once the app is under real load, which is a horrible thing to debug. CPU is measured in cores, so `1` is one core and `500m` is half a core.

---

## Resources

- <https://github.com/Nency-Ravaliya/Kubernetes>
- core objects: <https://github.com/Nency-Ravaliya/Kubernetes/blob/main/core-objects.md>
- <https://kubernetes.io/docs/concepts/workloads/pods/pod-lifecycle/>
- <https://kubernetes.io/docs/concepts/workloads/controllers/deployment/>
