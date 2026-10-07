# Session 13: Storage, HPA and Probes

**Pratyush Mishra · Roll No. 10486**

Went through the session folders in order: plain volumes (`emptyDir`, `hostPath`), static PV/PVC binding, dynamic provisioning through a StorageClass, a CPU-based HorizontalPodAutoscaler under real load, and the three probe types. Then did the mini-project, which puts all three together in one namespace. Everything below is copied straight from my terminal. I hit one real bug in the instructor manifests (the static PVC never binds to its PV) and fixed it, see section 3.

**Setup:** Ubuntu 26.04 on WSL2, Minikube v1.39.0 with the Docker driver, Kubernetes v1.37.0, `metrics-server` addon enabled.

> I used my own namespaces (`s13-storage`, `s13-hpa`, `s13-probes`) and added `-n` to every command instead of using `default`. The mini-project hard-codes `production-webapp`, so that one runs in its own namespace as written. `kubectl exec -it ... -- bash` from the md files is replaced with one-shot `kubectl exec ... -- sh -c "..."` so the output could be captured.

---

## 1. emptyDir: storage that lives as long as the Pod

`01-volumes/emptydir-pod.yaml` mounts an empty directory at `/data` in an nginx container.

```bash
$ kubectl create namespace s13-storage
namespace/s13-storage created
$ kubectl apply -n s13-storage -f emptydir-pod.yaml
pod/emptydir-demo created
$ kubectl get pods -n s13-storage
NAME            READY   STATUS    RESTARTS   AGE
emptydir-demo   1/1     Running   0          79s
$ kubectl exec -n s13-storage emptydir-demo -- sh -c "echo Hello Kubernetes > /data/message.txt && cat /data/message.txt"
Hello Kubernetes
$ kubectl delete pod -n s13-storage emptydir-demo
pod "emptydir-demo" deleted from s13-storage namespace
$ kubectl apply -n s13-storage -f emptydir-pod.yaml
pod/emptydir-demo created
$ kubectl exec -n s13-storage emptydir-demo -- cat /data/message.txt
cat: /data/message.txt: No such file or directory
command terminated with exit code 1
```

Delete the Pod and the `emptyDir` goes with it. The md file stops there, but the more interesting half is what happens on a **container** restart, so I killed PID 1 inside the container:

```bash
$ kubectl exec -n s13-storage emptydir-demo -- sh -c "echo survives-a-container-restart > /data/message.txt"
$ kubectl exec -n s13-storage emptydir-demo -- sh -c "kill 1"
$ kubectl get pod -n s13-storage emptydir-demo
NAME            READY   STATUS    RESTARTS     AGE
emptydir-demo   1/1     Running   1 (9s ago)   15s
$ kubectl exec -n s13-storage emptydir-demo -- cat /data/message.txt
survives-a-container-restart
```

`RESTARTS` went to 1 and the file was still there. The `emptyDir` belongs to the Pod, not the container, so it survives crashes and liveness restarts but not a Pod delete or reschedule. That makes it right for scratch space and for sharing files between sidecars in the same Pod, and wrong for anything you care about.

📸 `screenshots/01-emptydir.png`

---

## 2. hostPath: a directory on the node

`01-volumes/hostpath-pod.yaml` mounts `/tmp/hostpath-data` from the node (`DirectoryOrCreate`).

```bash
$ kubectl apply -n s13-storage -f hostpath-pod.yaml
pod/hostpath-demo created
$ kubectl exec -n s13-storage hostpath-demo -- sh -c "echo written-by-pod-at-$(date +%H:%M:%S) > /data/note.txt"
$ minikube ssh "cat /tmp/hostpath-data/note.txt"
written-by-pod-at-16:42:46
$ kubectl delete pod -n s13-storage hostpath-demo
pod "hostpath-demo" deleted from s13-storage namespace
$ kubectl apply -n s13-storage -f hostpath-pod.yaml
pod/hostpath-demo created
$ kubectl exec -n s13-storage hostpath-demo -- cat /data/note.txt
written-by-pod-at-16:42:46
```

The file is visible from the node itself with `minikube ssh`, and it survives a Pod delete. The catch is that the data is tied to that one node: on a multi-node cluster a rescheduled Pod can land somewhere else and see an empty directory. It also gives the Pod direct access to the node's filesystem, which is why it is fine for a minikube lab and a security problem in a shared cluster.

---

## 3. PV + PVC, and a binding bug in the manifests

`02-persistent-storage/` has a 1Gi `hostPath` PV called `student-pv`, a 500Mi PVC called `student-pvc`, and a Pod that mounts the claim. The readme expects the PVC to bind to `student-pv`. It did not:

```bash
$ kubectl apply -f pv.yaml
persistentvolume/student-pv created
$ kubectl apply -n s13-storage -f pvc.yaml
persistentvolumeclaim/student-pvc created
$ kubectl get pv
NAME                                       CAPACITY   ACCESS MODES   RECLAIM POLICY   STATUS      CLAIM                     STORAGECLASS   VOLUMEATTRIBUTESCLASS   REASON   AGE
pvc-1d2d9ccd-d431-470d-abab-8585a22a0439   500Mi      RWO            Delete           Bound       s13-storage/student-pvc   standard       <unset>                          5s
student-pv                                 1Gi        RWO            Retain           Available                                            <unset>                          5s
$ kubectl get pvc -n s13-storage
NAME          STATUS   VOLUME                                     CAPACITY   ACCESS MODES   STORAGECLASS   VOLUMEATTRIBUTESCLASS   AGE
student-pvc   Bound    pvc-1d2d9ccd-d431-470d-abab-8585a22a0439   500Mi      RWO            standard       <unset>                 5s
$ kubectl describe pvc -n s13-storage student-pvc | grep -E "StorageClass|Volume:|Events" -A0
StorageClass:  standard
--
Volume:        pvc-1d2d9ccd-d431-470d-abab-8585a22a0439
--
Events:
```

The PVC shows `Bound`, so at first glance it looks right, but it is bound to a brand-new `pvc-1d2d...` volume and `student-pv` is still sitting there `Available`.

**Root cause:** the PVC has no `storageClassName`. Minikube has a default StorageClass (`standard`), and the `DefaultStorageClass` admission plugin fills that in when the field is missing. `student-pv` has no class at all, so the two can never match, and the `standard` provisioner just creates a new volume to satisfy the claim. The fix is one line in `pvc.yaml`: `storageClassName: ""`, which explicitly means "no class, static binding only".

```bash
$ kubectl delete pvc -n s13-storage student-pvc
persistentvolumeclaim "student-pvc" deleted from s13-storage namespace
$ kubectl apply -n s13-storage -f pvc.yaml
persistentvolumeclaim/student-pvc created
$ kubectl get pv student-pv
NAME         CAPACITY   ACCESS MODES   RECLAIM POLICY   STATUS   CLAIM                     STORAGECLASS   VOLUMEATTRIBUTESCLASS   REASON   AGE
student-pv   1Gi        RWO            Retain           Bound    s13-storage/student-pvc                  <unset>                          15s
$ kubectl get pvc -n s13-storage
NAME          STATUS   VOLUME       CAPACITY   ACCESS MODES   STORAGECLASS   VOLUMEATTRIBUTESCLASS   AGE
student-pvc   Bound    student-pv   1Gi        RWO                           <unset>                 3s
```

Now it binds to `student-pv`. Note the claim asked for 500Mi but shows `1Gi`: binding is all-or-nothing, the claim gets the whole PV. The accidental dynamic PV had reclaim policy `Delete`, so deleting the PVC cleaned it up as well (checked below).

Then the actual persistence test with `pod.yaml`:

```bash
$ kubectl apply -n s13-storage -f pod.yaml
pod/storage-demo created
$ kubectl exec -n s13-storage storage-demo -- sh -c "echo Kubernetes Storage > /data/message.txt && cat /data/message.txt"
Kubernetes Storage
$ kubectl delete pod -n s13-storage storage-demo
pod "storage-demo" deleted from s13-storage namespace
$ kubectl apply -n s13-storage -f pod.yaml
pod/storage-demo created
$ kubectl exec -n s13-storage storage-demo -- cat /data/message.txt
Kubernetes Storage
$ minikube ssh "ls -l /tmp/student-data"
total 4
-rw-r--r-- 1 root root 19 Oct  7 16:43 message.txt
$ kubectl get pv | grep -c pvc-1d2d9ccd || echo dynamic PV from the first attempt is gone
0
dynamic PV from the first attempt is gone
```

The data outlives the Pod because the Pod only references the claim, and the claim's lifecycle is separate from the Pod's. Because `student-pv` is `Retain`, even deleting the PVC would leave the data on disk and the PV in `Released`, waiting for an admin.

📸 `screenshots/02-pv-pvc-binding.png`

---

## 4. StorageClass and dynamic provisioning

`03-storageclass/pvc.yaml` asks for 500Mi from `standard` explicitly.

```bash
$ kubectl get storageclass
NAME                 PROVISIONER                RECLAIMPOLICY   VOLUMEBINDINGMODE   ALLOWVOLUMEEXPANSION   AGE
standard (default)   k8s.io/minikube-hostpath   Delete          Immediate           false                  18d
$ kubectl apply -n s13-storage -f pvc.yaml
persistentvolumeclaim/dynamic-pvc created
$ kubectl get pvc -n s13-storage dynamic-pvc
NAME          STATUS   VOLUME                                     CAPACITY   ACCESS MODES   STORAGECLASS   VOLUMEATTRIBUTESCLASS   AGE
dynamic-pvc   Bound    pvc-fc927b87-d4b2-4e95-beba-df4d1b63989d   500Mi      RWO            standard       <unset>                 3s
$ kubectl describe pvc -n s13-storage dynamic-pvc | tail -6
Events:
  Type    Reason                 Age   From                                                                    Message
  ----    ------                 ----  ----                                                                    -------
  Normal  Provisioning           8s    k8s.io/minikube-hostpath_minikube_50e5cffc-...  External provisioner is provisioning volume for claim "s13-storage/dynamic-pvc"
  Normal  ExternalProvisioning   8s    persistentvolume-controller                     Waiting for a volume to be created either by the external provisioner 'k8s.io/minikube-hostpath' ...
  Normal  ProvisioningSucceeded  8s    k8s.io/minikube-hostpath_minikube_50e5cffc-...  Successfully provisioned volume pvc-fc927b87-d4b2-4e95-beba-df4d1b63989d
$ minikube ssh "ls /tmp/hostpath-provisioner/s13-storage/"
dynamic-pvc
$ kubectl delete pvc -n s13-storage dynamic-pvc
persistentvolumeclaim "dynamic-pvc" deleted from s13-storage namespace
$ kubectl get pv | grep -c dynamic-pvc
0
```

No PV was written by hand. The class is the default, uses the `k8s.io/minikube-hostpath` provisioner, `Delete` reclaim and `Immediate` binding. The events show the chain: PVC created, the controller hands it to the external provisioner named in the class, the provisioner makes a directory under `/tmp/hostpath-provisioner/<namespace>/<pvc>` and creates the PV object. On EKS or AKS the same flow creates an EBS volume or Azure Disk instead.

`ReclaimPolicy: Delete` is why the PV vanished as soon as I deleted the claim. That is the default for most dynamic classes, so deleting a PVC in production deletes the disk. `VolumeBindingMode: Immediate` provisions as soon as the claim exists; cloud classes usually use `WaitForFirstConsumer` so the disk is created in the same zone as the Pod that will use it.

---

## 5. HPA: scaling on CPU under real load

`04-hpa/` has an nginx Deployment with `requests.cpu: 100m` / `limits.cpu: 200m`, a ClusterIP Service and an HPA targeting 50% CPU, 1 to 5 replicas.

```bash
$ kubectl create namespace s13-hpa
namespace/s13-hpa created
$ kubectl apply -n s13-hpa -f deployment.yaml -f service.yaml -f hpa.yaml
deployment.apps/hpa-demo created
service/hpa-demo-service created
horizontalpodautoscaler.autoscaling/hpa-demo created
$ kubectl get deploy,svc,hpa -n s13-hpa
NAME                       READY   UP-TO-DATE   AVAILABLE   AGE
deployment.apps/hpa-demo   1/1     1            1           46s
...
NAME                                           REFERENCE             TARGETS              MINPODS   MAXPODS   REPLICAS   AGE
horizontalpodautoscaler.autoscaling/hpa-demo   Deployment/hpa-demo   cpu: <unknown>/50%   1         5         1          46s
$ kubectl top pods -n s13-hpa
NAME                        CPU(cores)   MEMORY(bytes)
hpa-demo-5d6676989b-g4l92   5m           18Mi
```

`<unknown>` for the first minute is normal, not broken. metrics-server scrapes every ~60s and the HPA has nothing to divide until the first sample for the new Pod arrives. The HPA's events later showed exactly that (`no metrics returned from resource metrics API`, then `did not receive metrics for targeted pods`). It only stays `<unknown>` if metrics-server is missing or the container has no CPU request, because utilization is measured as a percentage of the request.

Then the load generator from the readme, a busybox Pod looping `wget` against the Service:

```bash
$ kubectl run load-generator -n s13-hpa --image=busybox:1.36 --restart=Never -- /bin/sh -c "while true; do wget -q -O- http://hpa-demo-service; done"
pod/load-generator created
$ timeout 240 kubectl get hpa -n s13-hpa -w
NAME       REFERENCE             TARGETS              MINPODS   MAXPODS   REPLICAS   AGE
hpa-demo   Deployment/hpa-demo   cpu: <unknown>/50%   1         5         1          52s
hpa-demo   Deployment/hpa-demo   cpu: 38%/50%         1         5         1          90s
hpa-demo   Deployment/hpa-demo   cpu: 72%/50%         1         5         1          2m30s
hpa-demo   Deployment/hpa-demo   cpu: 72%/50%         1         5         2          2m45s
hpa-demo   Deployment/hpa-demo   cpu: 39%/50%         1         5         2          3m30s
hpa-demo   Deployment/hpa-demo   cpu: 37%/50%         1         5         2          4m30s
```

One generator took it from 1 to 2 replicas and then it settled at ~37%, under target. The scale-up maths is `desired = ceil(current * currentUtil / target)`, so `ceil(1 * 72 / 50) = 2`, and once the same load is spread over two Pods it drops below 50% and stops. To see it hit the ceiling I added three more generators:

```bash
$ for i in 2 3 4; do kubectl run load-generator-$i -n s13-hpa --image=busybox:1.36 --restart=Never -- /bin/sh -c "while true; do wget -q -O- http://hpa-demo-service; done"; done
pod/load-generator-2 created
pod/load-generator-3 created
pod/load-generator-4 created
$ timeout 210 kubectl get hpa -n s13-hpa -w
NAME       REFERENCE             TARGETS        MINPODS   MAXPODS   REPLICAS   AGE
hpa-demo   Deployment/hpa-demo   cpu: 37%/50%   1         5         2          4m57s
hpa-demo   Deployment/hpa-demo   cpu: 85%/50%   1         5         2          5m30s
hpa-demo   Deployment/hpa-demo   cpu: 85%/50%   1         5         4          5m45s
hpa-demo   Deployment/hpa-demo   cpu: 103%/50%   1         5         4          6m30s
hpa-demo   Deployment/hpa-demo   cpu: 78%/50%    1         5         4          7m30s
hpa-demo   Deployment/hpa-demo   cpu: 78%/50%    1         5         5          7m46s
$ kubectl describe hpa -n s13-hpa hpa-demo | tail -12
  ScalingLimited  True    TooManyReplicas   the desired replica count is more than the maximum replica count
...
  Normal   SuccessfulRescale             5m58s                  horizontal-pod-autoscaler  New size: 2; reason: cpu resource utilization (percentage of request) above target
  Normal   SuccessfulRescale             2m58s                  horizontal-pod-autoscaler  New size: 4; reason: cpu resource utilization (percentage of request) above target
  Normal   SuccessfulRescale             58s                    horizontal-pod-autoscaler  New size: 5; reason: cpu resource utilization (percentage of request) above target
```

2 → 4 → 5, and at 5 it is still at 78% but `ScalingLimited: TooManyReplicas` says it wants more and `maxReplicas` is stopping it. In a real cluster that condition is the one to alert on.

📸 `screenshots/03-hpa-scale-up.png`

**Scale down.** Deleted all four generators and kept watching:

```bash
$ kubectl delete pod -n s13-hpa load-generator load-generator-2 load-generator-3 load-generator-4
$ timeout 480 kubectl get hpa -n s13-hpa -w
NAME       REFERENCE             TARGETS        MINPODS   MAXPODS   REPLICAS   AGE
hpa-demo   Deployment/hpa-demo   cpu: 69%/50%   1         5         5          9m5s
hpa-demo   Deployment/hpa-demo   cpu: 57%/50%   1         5         5          9m31s
hpa-demo   Deployment/hpa-demo   cpu: 0%/50%    1         5         5          10m
hpa-demo   Deployment/hpa-demo   cpu: 0%/50%    1         5         5          15m
hpa-demo   Deployment/hpa-demo   cpu: 0%/50%    1         5         1          15m
```

CPU was 0% from the 10 minute mark, but replicas stayed at 5 for another five minutes and then dropped straight to 1 (`SuccessfulRescale ... New size: 1; reason: All metrics below target`). That is the default scale-down stabilization window of 300 seconds: the HPA uses the highest recommendation from the last 5 minutes, so a short dip in traffic does not kill Pods you will need again a minute later. Scale-up has no such window by default, which is why it reacted within ~15 seconds. Both are tunable under `spec.behavior`.

---

## 6. Liveness probe: failing it restarts the container

`05-probes/liveness.yaml` checks `GET /` on port 80 every 5s, 3 failures allowed.

```bash
$ kubectl create namespace s13-probes
namespace/s13-probes created
$ kubectl apply -n s13-probes -f liveness.yaml
pod/liveness-demo created
$ kubectl get pod -n s13-probes liveness-demo
NAME            READY   STATUS    RESTARTS   AGE
liveness-demo   1/1     Running   0          21s
$ kubectl describe pod -n s13-probes liveness-demo | grep Liveness
    Liveness:       http-get http://:80/ delay=5s timeout=2s period=5s #success=1 #failure=3
```

Then the "break liveness" step from `probes.md`. Pod specs are immutable, so it has to be deleted and recreated; I used `sed` to swap the path without editing the file:

```bash
$ kubectl delete pod -n s13-probes liveness-demo
$ sed "s#path: /#path: /wrong-path#" liveness.yaml | kubectl apply -n s13-probes -f -
pod/liveness-demo created
$ kubectl get pod -n s13-probes liveness-demo
NAME            READY   STATUS             RESTARTS     AGE
liveness-demo   0/1     CrashLoopBackOff   3 (5s ago)   75s
$ kubectl describe pod -n s13-probes liveness-demo | tail -n 12
...
  Warning  Unhealthy  9s (x12 over 69s)  kubelet            Liveness probe failed: HTTP probe failed with statuscode: 404
  Normal   Killing    9s (x4 over 59s)   kubelet            Container nginx failed liveness probe, will be restarted
  Warning  BackOff    8s (x2 over 9s)    kubelet            Back-off restarting failed container nginx in pod liveness-demo_s13-probes(...)
$ kubectl logs -n s13-probes liveness-demo | grep kube-probe | tail -n 3
10.244.0.1 - - [07/Oct/2026:16:53:47 +0000] "GET /wrong-path HTTP/1.1" 404 153 "-" "kube-probe/1.37" "-"
10.244.0.1 - - [07/Oct/2026:16:53:52 +0000] "GET /wrong-path HTTP/1.1" 404 153 "-" "kube-probe/1.37" "-"
10.244.0.1 - - [07/Oct/2026:16:53:57 +0000] "GET /wrong-path HTTP/1.1" 404 153 "-" "kube-probe/1.37" "-"
```

Four restarts in 75 seconds, roughly one every 15s (5s period x 3 failures), and after a few of those the kubelet adds back-off and the status turns into `CrashLoopBackOff`. That surprised me: nginx itself is perfectly healthy, but a wrong probe makes it look exactly like a crashing app. The nginx access log is the giveaway, you can see `kube-probe/1.37` asking for `/wrong-path` and getting 404. Afterwards I recreated the pod from the original file.

📸 `screenshots/04-liveness-restarts.png`

---

## 7. Readiness probe: failing it removes the Pod from the Service

`05-probes/readiness.yaml` has only a readiness probe. Instead of recreating the Pod with a bad path, I broke the app **live** by moving nginx's `index.html` away, so the same container goes from ready to not-ready and back:

```bash
$ kubectl apply -n s13-probes -f readiness.yaml
pod/readiness-demo created
$ kubectl expose pod readiness-demo -n s13-probes --name=readiness-service --port=80
service/readiness-service exposed
$ kubectl get endpoints -n s13-probes readiness-service
NAME                ENDPOINTS        AGE
readiness-service   10.244.0.50:80   3s

$ kubectl exec -n s13-probes readiness-demo -- mv /usr/share/nginx/html/index.html /tmp/
$ kubectl get pod -n s13-probes readiness-demo
NAME             READY   STATUS    RESTARTS   AGE
readiness-demo   0/1     Running   0          35s
$ kubectl get endpoints -n s13-probes readiness-service
NAME                ENDPOINTS   AGE
readiness-service               19s
$ kubectl describe pod -n s13-probes readiness-demo | grep -E "Unhealthy|Ready:"
    Ready:          False
  Warning  Unhealthy  3s (x4 over 13s)  kubelet            Readiness probe failed: HTTP probe failed with statuscode: 403

$ kubectl exec -n s13-probes readiness-demo -- mv /tmp/index.html /usr/share/nginx/html/
$ kubectl get pod -n s13-probes readiness-demo
NAME             READY   STATUS    RESTARTS   AGE
readiness-demo   1/1     Running   0          46s
$ kubectl get endpoints -n s13-probes readiness-service
NAME                ENDPOINTS        AGE
readiness-service   10.244.0.50:80   30s
```

(Each `get endpoints` also printed `Warning: v1 Endpoints is deprecated in v1.33+; use discovery.k8s.io/v1 EndpointSlice`. I trimmed that line here; `kubectl get endpointslices` is the replacement.)

This is the key difference from liveness: `STATUS` stays `Running`, `RESTARTS` stays `0`, but `READY` goes `0/1` and the Pod IP disappears from the Service's endpoints, so no traffic is sent to it. When the file came back the IP was re-added on its own. With no `index.html`, nginx falls back to a directory listing, which is off, hence 403 instead of 404.

📸 `screenshots/05-readiness-endpoints.png`

---

## 8. Startup probe: protecting a slow starter

`05-probes/startup.yaml` has all three probes. nginx starts in under a second, so the startup probe passes on the first try and there is nothing to see. I added `startup-slow.yaml`, the same probes but with nginx sleeping 20s before it starts:

```bash
$ kubectl apply -n s13-probes -f startup.yaml -f startup-slow.yaml
pod/startup-demo created
pod/startup-slow-demo created
$ kubectl get pods -n s13-probes startup-demo startup-slow-demo
NAME                READY   STATUS    RESTARTS   AGE
startup-demo        1/1     Running   0          10s
startup-slow-demo   0/1     Running   0          10s
$ kubectl describe pod -n s13-probes startup-demo | grep -E "Startup|Liveness|Readiness"
    Liveness:       http-get http://:80/ delay=0s timeout=1s period=5s #success=1 #failure=3
    Readiness:      http-get http://:80/ delay=0s timeout=1s period=5s #success=1 #failure=3
    Startup:        http-get http://:80/ delay=0s timeout=1s period=2s #success=1 #failure=30
$ kubectl get pods -n s13-probes startup-demo startup-slow-demo
NAME                READY   STATUS    RESTARTS   AGE
startup-demo        1/1     Running   0          36s
startup-slow-demo   1/1     Running   0          36s
$ kubectl events -n s13-probes --for pod/startup-slow-demo
LAST SEEN            TYPE      REASON      OBJECT                  MESSAGE
...
16s (x10 over 34s)   Warning   Unhealthy   Pod/startup-slow-demo   Startup probe failed: Get "http://10.244.0.59:80/": dial tcp 10.244.0.59:80: connect: connection refused
```

The startup probe failed 10 times while nginx was "warming up" and the container was never restarted, because liveness and readiness do not run at all until startup succeeds. The budget is `failureThreshold x periodSeconds = 30 x 2s = 60s`. The liveness probe on its own would only allow 3 x 5s = 15s, which is less than the 20s this container needs, so without the startup probe this Pod would be killed before it ever came up.

---

## 9. Mini-project: storage + HPA + probes together

`mini-project/` deploys a 2-replica nginx Deployment with all three probes, a 500Mi PVC from the default class mounted at `/data`, a Service and an HPA (2 to 5, 50% CPU), in the `production-webapp` namespace.

```bash
$ kubectl apply -f namespace.yaml
namespace/production-webapp created
$ kubectl apply -f pvc.yaml
persistentvolumeclaim/web-data created
$ kubectl get pvc -n production-webapp
NAME       STATUS   VOLUME                                     CAPACITY   ACCESS MODES   STORAGECLASS   VOLUMEATTRIBUTESCLASS   AGE
web-data   Bound    pvc-1760bbb6-4517-4a48-9d21-cdb606050014   500Mi      RWO            standard       <unset>                 3s
$ kubectl apply -f deployment.yaml -f service.yaml
deployment.apps/web-app created
service/web-service created
$ kubectl apply -f hpa.yaml
horizontalpodautoscaler.autoscaling/web-app-hpa created
```

### Task 1: storage persistence

```bash
$ POD_NAME=web-app-d45775485-5vmm8; kubectl exec -n production-webapp $POD_NAME -- sh -c "echo Student: Pratyush Mishra, Roll 10486 > /data/student.txt"
$ kubectl exec -n production-webapp web-app-d45775485-5vmm8 -- cat /data/student.txt
Student: Pratyush Mishra, Roll 10486
$ kubectl delete pod -n production-webapp web-app-d45775485-5vmm8
pod "web-app-d45775485-5vmm8" deleted from production-webapp namespace
$ kubectl get pods -n production-webapp -l app=web-app
NAME                      READY   STATUS    RESTARTS   AGE
web-app-d45775485-f98ss   1/1     Running   0          13s
web-app-d45775485-r7xvh   1/1     Running   0          89s
$ for p in $(kubectl get pods -n production-webapp -l app=web-app -o name); do echo $p; kubectl exec -n production-webapp $p -- cat /data/student.txt; done
pod/web-app-d45775485-f98ss
Student: Pratyush Mishra, Roll 10486
pod/web-app-d45775485-r7xvh
Student: Pratyush Mishra, Roll 10486
```

The replacement Pod has the file, and so does the other replica, because both mount the same claim. Worth flagging: the PVC is `ReadWriteOnce`, which means one **node**, not one Pod. On single-node minikube every replica lands on the same node so they can all share it. On a multi-node cluster, replicas scheduled to a second node would fail to attach the volume. The Deployment uses `strategy: Recreate` for the same reason.

### Task 2: Service

```bash
$ kubectl port-forward -n production-webapp svc/web-service 18080:80 &
Forwarding from 127.0.0.1:18080 -> 80
Forwarding from [::1]:18080 -> 80
$ curl -s http://localhost:18080 | head -n 8
<!DOCTYPE html>
<html>
<head>
<title>Welcome to nginx!</title>
...
```

I used local port 18080 instead of the readme's 8080 to stay clear of other things running on this machine.

📸 `screenshots/06-mini-persistence-service.png`

### Task 3: HPA

The readme's single load generator did **not** scale this one:

```bash
$ kubectl run load-generator -n production-webapp --image=busybox:1.36 --restart=Never -- /bin/sh -c "while true; do wget -q -O- http://web-service; done"
$ timeout 240 kubectl get hpa -n production-webapp -w
NAME          REFERENCE            TARGETS              MINPODS   MAXPODS   REPLICAS   AGE
web-app-hpa   Deployment/web-app   cpu: <unknown>/50%   2         5         2          110s
web-app-hpa   Deployment/web-app   cpu: 1%/50%          2         5         2          2m
web-app-hpa   Deployment/web-app   cpu: 33%/50%         2         5         2          3m
web-app-hpa   Deployment/web-app   cpu: 36%/50%         2         5         2          4m
web-app-hpa   Deployment/web-app   cpu: 35%/50%         2         5         2          5m
```

One client split across two replicas only reached ~35%, under the 50% target, so nothing happened (the readme's "expected" 110% is not what my machine produced). Added three more:

```bash
$ for i in 2 3 4; do kubectl run load-generator-$i -n production-webapp --image=busybox:1.36 --restart=Never -- /bin/sh -c "while true; do wget -q -O- http://web-service; done"; done
$ timeout 240 kubectl get hpa -n production-webapp -w
NAME          REFERENCE            TARGETS        MINPODS   MAXPODS   REPLICAS   AGE
web-app-hpa   Deployment/web-app   cpu: 35%/50%   2         5         2          5m56s
web-app-hpa   Deployment/web-app   cpu: 37%/50%   2         5         2          6m
web-app-hpa   Deployment/web-app   cpu: 152%/50%   2         5         2          7m
web-app-hpa   Deployment/web-app   cpu: 152%/50%   2         5         4          7m15s
web-app-hpa   Deployment/web-app   cpu: 152%/50%   2         5         5          7m30s
web-app-hpa   Deployment/web-app   cpu: 97%/50%    2         5         5          8m1s
web-app-hpa   Deployment/web-app   cpu: 65%/50%    2         5         5          9m1s
$ kubectl top pods -n production-webapp
NAME                      CPU(cores)   MEMORY(bytes)
load-generator            850m         12Mi
load-generator-2          840m         9Mi
load-generator-3          851m         10Mi
load-generator-4          844m         9Mi
web-app-d45775485-f98ss   66m          21Mi
web-app-d45775485-mwgbc   63m          20Mi
web-app-d45775485-r7xvh   65m          21Mi
web-app-d45775485-rr7rb   63m          21Mi
web-app-d45775485-vzbfj   64m          21Mi
$ kubectl exec -n production-webapp web-app-d45775485-mwgbc -- cat /data/student.txt
Student: Pratyush Mishra, Roll 10486
```

2 → 4 → 5 in 30 seconds. The `top` output is the interesting part: each busybox generator burns ~850m while each nginx Pod only uses ~65m. Serving a static page is cheap, so the bottleneck is the client, which is why one generator was not enough. Also, a Pod created by the HPA (`mwgbc`) already sees `student.txt`, so scaled-out replicas share the volume too.

📸 `screenshots/07-mini-hpa.png`

Then stopped the load and watched it come back down:

```bash
$ kubectl delete pod -n production-webapp load-generator load-generator-2 load-generator-3 load-generator-4
$ timeout 450 kubectl get hpa -n production-webapp -w
NAME          REFERENCE            TARGETS        MINPODS   MAXPODS   REPLICAS   AGE
web-app-hpa   Deployment/web-app   cpu: 64%/50%   2         5         5          10m
web-app-hpa   Deployment/web-app   cpu: 56%/50%   2         5         5          11m
web-app-hpa   Deployment/web-app   cpu: 1%/50%    2         5         5          12m
web-app-hpa   Deployment/web-app   cpu: 1%/50%    2         5         5          16m
web-app-hpa   Deployment/web-app   cpu: 1%/50%    2         5         2          17m
```

Same pattern as section 5: about five minutes at 1% with 5 replicas, then straight down to `minReplicas: 2`, never below it. All load generators were deleted at the end.

---

## Manifest index

| Path | What it is |
| --- | --- |
| `01-volumes/emptydir-pod.yaml` | nginx Pod with an `emptyDir` at `/data` |
| `01-volumes/hostpath-pod.yaml` | nginx Pod with `hostPath: /tmp/hostpath-data` |
| `02-persistent-storage/pv.yaml` | Static 1Gi `hostPath` PV, `Retain` |
| `02-persistent-storage/pvc.yaml` | 500Mi claim. **Fixed:** added `storageClassName: ""` so it binds to `student-pv` instead of getting a dynamic volume |
| `02-persistent-storage/pod.yaml` | Pod mounting `student-pvc` |
| `03-storageclass/pvc.yaml` | Claim against the `standard` class (dynamic provisioning) |
| `04-hpa/deployment.yaml`, `service.yaml`, `hpa.yaml` | nginx with CPU request, Service, HPA 1 to 5 at 50% |
| `04-hpa/demo-chart/` | Helm chart version of the same idea (not used here) |
| `hpa/` | HPA + Service + curl load script for the yatri-backend app from session 12 (not used; that Deployment is not in this folder) |
| `05-probes/liveness.yaml`, `readiness.yaml`, `startup.yaml` | One Pod per probe type |
| `05-probes/startup-slow.yaml` | **Added:** nginx with a 20s startup delay, to show the startup probe holding off liveness |
| `mini-project/` | Namespace, PVC, Deployment with all probes, Service, HPA |
| `screenshots/` | 7 terminal captures referenced above |

---

## Resources

- <https://kubernetes.io/docs/concepts/storage/volumes/>
- <https://kubernetes.io/docs/concepts/storage/persistent-volumes/#class-1> (why `storageClassName: ""` matters)
- <https://kubernetes.io/docs/concepts/storage/storage-classes/>
- <https://kubernetes.io/docs/concepts/workloads/autoscaling/horizontal-pod-autoscale/#stabilization-window>
- <https://kubernetes.io/docs/tasks/configure-pod-container/configure-liveness-readiness-startup-probes/>
