# Session 20: Monitoring, Observability and GitOps

**Pratyush Mishra · Roll No. 10486**

Two halves this session. First the observability side: what the three signals are, then Prometheus scraping a target and Grafana drawing it. Then GitOps: installed Argo CD in the cluster, pointed it at my fork of this repo, and watched it keep the cluster matching Git, including undoing changes I made by hand with kubectl. Everything below is copied straight from my terminal.

**Setup:** Ubuntu 26.04 on WSL2, Minikube v1.39.0 with the Docker driver, Kubernetes v1.37.0, Docker Compose for Prometheus v3.5.0 and Grafana 12.1.1, Argo CD v3.5.4 (server and CLI).

---

## 1. Monitoring vs observability

The way I understand it after reading `01-monitoring-vs-observability`:

| | Monitoring | Observability |
| --- | --- | --- |
| Question it answers | *Is* something wrong? | *Why* is it wrong? |
| Works for | Problems you already expected (known unknowns) | Problems nobody predicted (unknown unknowns) |
| Typical output | Dashboards and alerts on fixed thresholds | Being able to ask new questions of metrics, logs and traces without shipping new code |
| Example | "Error rate > 5%, page someone" | "Errors are only from users on one region hitting one pod after the 14:02 deploy" |

Monitoring is a subset of observability. You need monitoring to know you have a problem, and observability to get from "latency is 2s" to the actual cause. Section 2 has a small real example of the difference.

---

## 2. Metrics, logs and traces with the k8s demo

`02-metrics-logs-traces/k8s-demo` is a busybox Deployment that prints a log line every 10 seconds, plus a Service on port 8080. I applied it into my own namespace.

```bash
$ kubectl create namespace s20-demo
namespace/s20-demo created

$ kubectl apply -n s20-demo -f k8s-demo/
deployment.apps/session20-demo created
service/session20-demo created

$ kubectl get pods -n s20-demo -o wide
NAME                              READY   STATUS    RESTARTS   AGE     IP            NODE       NOMINATED NODE   READINESS GATES
session20-demo-6698db549f-v8v98   1/1     Running   0          2m23s   10.244.0.44   minikube   <none>           <none>
```

**Metrics**: numbers over time. `kubectl top` reads them from metrics-server:

```bash
$ kubectl top pod -n s20-demo; kubectl top node
NAME                              CPU(cores)   MEMORY(bytes)
session20-demo-6698db549f-v8v98   1m           0Mi
NAME       CPU(cores)   CPU(%)   MEMORY(bytes)   MEMORY(%)
minikube   5657m        23%      2180Mi          27%
```

**Logs**: individual events with a timestamp:

```bash
$ kubectl logs deployment/session20-demo -n s20-demo --timestamps | head -7
2026-10-07T16:49:30.848556741Z Session 20 observability demo started
2026-10-07T16:49:30.848578953Z Request received
2026-10-07T16:49:30.848580754Z Health check OK
2026-10-07T16:49:40.848805948Z Request received
2026-10-07T16:49:40.848837553Z Health check OK
2026-10-07T16:49:50.847575024Z Request received
2026-10-07T16:49:50.847618323Z Health check OK
```

**Traces** follow one request across several services (with a trace ID passed along in headers). A single busybox loop has nothing to trace, so this demo only covers the first two signals.

Then I actually tried to use the Service:

```bash
$ kubectl get endpoints session20-demo -n s20-demo; kubectl run curl-test -n s20-demo --rm -i --restart=Never --image=busybox:1.36 -- wget -qO- -T 3 http://session20-demo:8080
Warning: v1 Endpoints is deprecated in v1.33+; use discovery.k8s.io/v1 EndpointSlice
NAME             ENDPOINTS          AGE
session20-demo   10.244.0.44:8080   2m25s
...
wget: can't connect to remote host (10.103.166.179): Connection refused
pod "curl-test" deleted from s20-demo namespace
pod s20-demo/curl-test terminated (Error)

$ kubectl describe deployment session20-demo -n s20-demo | sed -n '/Conditions/,$p'
Conditions:
  Type           Status  Reason
  ----           ------  ------
  Available      True    MinimumReplicasAvailable
  Progressing    True    NewReplicaSetAvailable
```

This is the monitoring vs observability point from section 1 in a small real case. Every health signal is green: pod `Running`, Deployment `Available`, the Service has an endpoint, the log keeps printing "Health check OK". But a real request gets `Connection refused`, because the container is a shell loop that never listens on 8080. Nothing in the monitoring catches that, since there is no readiness probe and the "health check" is just an `echo`. You only find it by asking a new question (send a real request and see what happens), which is what observability is about.

📸 `screenshots/01-metrics-and-logs.png`

---

## 3. Prometheus

`03-prometheus` runs Prometheus in Docker with a config that scrapes itself every 5 seconds.

```bash
$ docker compose up -d
 Network 03-prometheus_default Creating
 Network 03-prometheus_default Created
 Container session20-prometheus Creating
 Container session20-prometheus Created
 Container session20-prometheus Starting
 Container session20-prometheus Started

$ docker compose ps
NAME                   IMAGE                    COMMAND                  SERVICE      CREATED                  STATUS                  PORTS
session20-prometheus   prom/prometheus:v3.5.0   "/bin/prometheus --c…"   prometheus   Less than a second ago   Up Less than a second   0.0.0.0:9090->9090/tcp, [::]:9090->9090/tcp

$ curl -s localhost:9090/-/ready; echo
Prometheus Server is Ready.

$ curl -s localhost:9090/api/v1/targets | python3 -c '...print job, scrapeUrl, health, lastScrapeDuration...'
prometheus http://prometheus:9090/metrics up 0.004060583
```

The target is `http://prometheus:9090/metrics`, not `localhost`. Inside the compose network, `prometheus` is the container's DNS name. Prometheus **pulls**: it goes to each target's `/metrics` on a timer, the app does not push anything.

The `up` metric is generated by Prometheus itself for every target: 1 if the last scrape worked, 0 if not.

```bash
$ curl -s 'localhost:9090/api/v1/query?query=up' | python3 -m json.tool
{
    "status": "success",
    "data": {
        "resultType": "vector",
        "result": [
            {
                "metric": {
                    "__name__": "up",
                    "instance": "prometheus:9090",
                    "job": "prometheus"
                },
                "value": [
                    1791391877.612,
                    "1"
                ]
            }
        ]
    }
}

$ curl -s localhost:9090/api/v1/query --data-urlencode 'query=sum by (handler) (rate(prometheus_http_requests_total[1m])) > 0' | python3 -c '...'
/metrics 0.017723333333333334
```

`prometheus_http_requests_total` is a counter, it only ever goes up, so on its own it is not very useful. `rate(...[1m])` turns it into "per second over the last minute". Here only `/metrics` has traffic, because the only client is Prometheus scraping itself. The number was still ramping up because the container was 15 seconds old; in Grafana below it settles at exactly 0.2/s, which is one scrape every 5 seconds.

📸 `screenshots/02-prometheus-targets.png` (Status > Target health page, the target is UP)

---

## 4. Grafana

`04-grafana` adds Grafana to the same compose file. The first attempt failed:

```bash
$ docker compose up -d
 ...
 Container session20-prometheus Started
 Container session20-grafana Starting
Error response from daemon: failed to set up container networking: driver failed programming external connectivity on endpoint session20-grafana (6a179d355c11...): Bind for 0.0.0.0:3000 failed: port is already allocated

$ docker compose down
 ...
$ docker ps --format '{{.Names}} {{.Ports}}' | grep ':3000->'
shelflife-frontend-1 0.0.0.0:3000->8080/tcp, [::]:3000->8080/tcp
```

Another project of mine already owns host port 3000. Rather than edit the instructor's compose file, I added `docker-compose.lab.yml` as an override. It remaps Grafana to 3001 (`ports: !override` replaces the list instead of appending to it), and turns on anonymous **Viewer** access so headless Chrome could screenshot the dashboard without logging in.

```bash
$ docker compose -f docker-compose.yml -f docker-compose.lab.yml up -d
 ...
 Container session20-grafana Started

$ docker compose -f docker-compose.yml -f docker-compose.lab.yml ps
NAME                   IMAGE                    COMMAND                  SERVICE      CREATED        STATUS                  PORTS
session20-grafana      grafana/grafana:12.1.1   "/run.sh"                grafana      1 second ago   Up Less than a second   0.0.0.0:3001->3000/tcp, [::]:3001->3000/tcp
session20-prometheus   prom/prometheus:v3.5.0   "/bin/prometheus --c…"   prometheus   1 second ago   Up Less than a second   0.0.0.0:9090->9090/tcp, [::]:9090->9090/tcp

$ curl -s localhost:3001/api/health
{
  "database": "ok",
  "version": "12.1.1",
  "commit": "df5de8219b41d1e639e003bf5f3a85913761d167"
}
```

Instead of clicking through the UI I added the data source and the dashboard through Grafana's HTTP API, as admin:

```bash
$ curl -s -u admin:admin -H 'Content-Type: application/json' -X POST localhost:3001/api/datasources -d '{"name":"Prometheus","uid":"prom","type":"prometheus","url":"http://prometheus:9090","access":"proxy","isDefault":true}' | python3 -m json.tool | head -8
{
    "datasource": {
        "id": 1,
        "uid": "prom",
        "orgId": 1,
        "name": "Prometheus",
        "type": "prometheus",
        "typeLogoUrl": "public/plugins/prometheus/img/prometheus_logo.svg",

$ curl -s -u admin:admin localhost:3001/api/datasources/uid/prom/health
{"details":{"application":"Prometheus","features":{"rulerApiEnabled":false}},"message":"Successfully queried the Prometheus API.","status":"OK"}

$ curl -s -u admin:admin -H 'Content-Type: application/json' -X POST localhost:3001/api/dashboards/db -d @dashboard-prometheus-self.json
{"folderUid":"","id":1,"slug":"session-20-prometheus-self-monitoring","status":"success","uid":"s20-prom-self","url":"/d/s20-prom-self/session-20-prometheus-self-monitoring","version":1}

$ curl -s -u admin:admin -H 'Content-Type: application/json' -X POST localhost:3001/api/ds/query -d '{...,"expr":"prometheus_tsdb_head_series","instant":true}]}' | python3 -c '...'
{'__name__': 'prometheus_tsdb_head_series', 'instance': 'prometheus:9090', 'job': 'prometheus'} [550]

$ curl -s -o /dev/null -w 'anonymous GET dashboard: %{http_code}\n' localhost:3001/api/dashboards/uid/s20-prom-self; curl -s -o /dev/null -w 'anonymous POST datasource: %{http_code}\n' -X POST -H 'Content-Type: application/json' localhost:3001/api/datasources -d '{}'
anonymous GET dashboard: 200
anonymous POST datasource: 403
```

The data source URL is `http://prometheus:9090`, not `localhost:9090`. With `access: proxy` the Grafana *server* makes the query, and inside the Grafana container `localhost` is Grafana itself. This is the most common reason people see "connection refused" when adding the data source. The last command checks that anonymous users can read the dashboard but get a 403 on writes.

The dashboard JSON is in `04-grafana/dashboard-prometheus-self.json`: targets up, active series, Prometheus memory, and HTTP request rate per handler. The red `/metrics` line sits flat at 0.2 req/s, which is the 5 second scrape interval. The spike on the left is me hitting the API with curl.

📸 `screenshots/03-grafana-dashboard.png`

I stopped the compose stack afterwards to give the RAM back to the cluster.

---

## 5. GitOps and Git as the source of truth

Notes from `05-introduction-to-gitops` and `06-git-as-source-of-truth`:

| | Push (classic CI/CD) | Pull (GitOps) |
| --- | --- | --- |
| Who changes the cluster | The pipeline runs `kubectl apply` | An agent inside the cluster (Argo CD) |
| Credentials | CI needs cluster admin credentials | Cluster only needs read access to Git |
| Drift (someone runs `kubectl edit`) | Stays until the next deploy, nobody notices | Detected and reverted automatically |
| Rollback | Re-run an old pipeline | `git revert` |
| Audit trail | Pipeline logs | Git history: who, what, when, why |

Git holds the **desired** state, the cluster is the **actual** state, and the GitOps controller's whole job is to keep making the second match the first. Every change goes through a commit, so the repo is a full history of what was running when.

---

## 6. Installing Argo CD

```bash
$ kubectl create namespace argocd
namespace/argocd created

$ kubectl apply -n argocd --server-side --force-conflicts -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml | tail -8
statefulset.apps/argocd-application-controller serverside-applied
networkpolicy.networking.k8s.io/argocd-application-controller-network-policy serverside-applied
...
networkpolicy.networking.k8s.io/argocd-server-network-policy serverside-applied

$ kubectl get pods -n argocd
NAME                                                READY   STATUS    RESTARTS   AGE
argocd-application-controller-0                     1/1     Running   0          2m40s
argocd-applicationset-controller-76fd8cdd4f-ss6rw   1/1     Running   0          2m40s
argocd-dex-server-66c78cf887-tjgqq                  1/1     Running   0          2m40s
argocd-notifications-controller-7fb9868fd6-fzgpk    1/1     Running   0          2m40s
argocd-redis-bdbdffcb4-l89xt                        1/1     Running   0          2m40s
argocd-repo-server-d89c7967d-28b24                  1/1     Running   0          2m40s
argocd-server-776b7cdd4d-72zs7                      1/1     Running   0          2m40s

$ kubectl get deploy argocd-server -n argocd -o jsonpath='{.spec.template.spec.containers[0].image}'; echo
quay.io/argoproj/argocd:v3.5.4
```

The pieces that matter: the **repo-server** clones Git and renders manifests, the **application-controller** compares rendered vs live state and syncs, and **argocd-server** is the API and UI. `--server-side` is needed because some of Argo CD's CRDs are too big for the `last-applied-configuration` annotation that client-side apply writes.

---

## 7. First Application: the 07-argocd demo app from my fork

The instructor's `07-argocd/app/argocd-application.yaml` points at `https://github.com/Nency-Ravaliya/gitops-demo.git`, path `app`. I wanted Argo CD to watch my own fork instead. I also noticed a problem with the folder:

```bash
$ ls app/
argocd-application.yaml
deployment.yaml
service.yaml
```

The Application manifest sits *inside* the folder Argo CD is told to sync. Point Argo CD at `app/` and it would also apply `argocd-application.yaml` itself, creating a second Application from inside Git (the file's own comment says not to do this). So I made my own copy, `07-argocd/argocd-application-pratyush.yaml`, kept outside `app/`, with:

- `repoURL: https://github.com/PratyushMishra-2nd/devops-heros.git` and the full path `session20-monitoring-observability-gitops/07-argocd/app`
- `directory.exclude: argocd-application.yaml` so the stray file is skipped
- destination namespace `s20-gitops`, with `automated: {prune: true, selfHeal: true}` and `CreateNamespace=true`

```bash
$ kubectl apply -f argocd-application-pratyush.yaml
application.argoproj.io/s20-gitops-app created

$ kubectl get applications -n argocd
NAME             SYNC STATUS   HEALTH STATUS
s20-gitops-app   Synced        Progressing

$ kubectl get deploy,pods,svc -n s20-gitops
NAME                                   READY   UP-TO-DATE   AVAILABLE   AGE
deployment.apps/session20-gitops-app   5/5     5            5           34s

NAME                                        READY   STATUS    RESTARTS   AGE
pod/session20-gitops-app-679fcbbd85-9wvmm   1/1     Running   0          34s
pod/session20-gitops-app-679fcbbd85-cl4f6   1/1     Running   0          34s
pod/session20-gitops-app-679fcbbd85-fl9hc   1/1     Running   0          34s
pod/session20-gitops-app-679fcbbd85-gc6lm   1/1     Running   0          34s
pod/session20-gitops-app-679fcbbd85-gn6bc   1/1     Running   0          34s

NAME                           TYPE        CLUSTER-IP      EXTERNAL-IP   PORT(S)   AGE
service/session20-gitops-app   ClusterIP   10.110.10.182   <none>        80/TCP    34s
```

5 replicas, which is the `replicas: 5` from my earlier commit "replicas from 2 to 5" on the fork. Then with the CLI, logging in with the initial admin secret through a port-forward (`kubectl port-forward svc/argocd-server -n argocd 8443:443`):

```bash
$ argocd login localhost:8443 --username admin --password "$(kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d)" --insecure --grpc-web
'admin:login' logged in successfully
Context 'localhost:8443' updated

$ argocd app get s20-gitops-app --grpc-web
Name:               argocd/s20-gitops-app
Project:            default
Server:             https://kubernetes.default.svc
Namespace:          s20-gitops
URL:                https://localhost:8443/applications/s20-gitops-app
Source:
- Repo:             https://github.com/PratyushMishra-2nd/devops-heros.git
  Target:           main
  Path:             session20-monitoring-observability-gitops/07-argocd/app
SyncWindow:         Sync Allowed
Sync Policy:        Automated (Prune)
Sync Status:        Synced to main (0678d7f)
Health Status:      Healthy

GROUP  KIND        NAMESPACE   NAME                  STATUS   HEALTH   HOOK  MESSAGE
       Namespace               s20-gitops            Running  Synced         namespace/s20-gitops created
       Service     s20-gitops  session20-gitops-app  Synced   Healthy        service/session20-gitops-app created
apps   Deployment  s20-gitops  session20-gitops-app  Synced   Healthy        deployment.apps/session20-gitops-app created
```

`Synced to main (0678d7f)` is the exact commit at the tip of my fork's `main`. `argocd-application.yaml` does not appear in the resource list, so the exclude worked. I put the password straight into `argocd login` with `$(...)` rather than printing it, so it never shows up in my terminal history or screenshots.

📸 `screenshots/04-argocd-sync.png`

---

## 8. Mini project: the session20-mini app

`08-mini-project/app/argocd-application.yaml` has `repoURL: https://github.com/YOUR_USERNAME/YOUR_GITOPS_REPO.git` and `path: app`. Same fix as section 7: my copy is `08-mini-project/argocd-application-pratyush.yaml`, pointing at my fork with path `session20-monitoring-observability-gitops/08-mini-project/app` and the template Application excluded. The manifests in `app/` hardcode `namespace: session20`, so the destination stays `session20`.

```bash
$ grep -n 'repoURL\|path:\|namespace:' app/argocd-application.yaml
6:  namespace: argocd
11:    repoURL: https://github.com/YOUR_USERNAME/YOUR_GITOPS_REPO.git
13:    path: app
17:    namespace: session20

$ kubectl get ns session20
Error from server (NotFound): namespaces "session20" not found

$ kubectl apply -f argocd-application-pratyush.yaml
application.argoproj.io/session20-mini created

$ kubectl get applications -n argocd
NAME             SYNC STATUS   HEALTH STATUS
s20-gitops-app   Synced        Healthy
session20-mini   Unknown       Healthy

$ kubectl get all -n session20
No resources found in session20 namespace.
```

`Unknown` after 45 seconds, so I looked at the Application's conditions:

```bash
$ kubectl get application session20-mini -n argocd -o jsonpath="{.status.conditions}"
[{"lastTransitionTime":"2026-10-07T16:58:28Z","message":"Failed to load target state: failed to generate manifest for source 1 of 1: rpc error: code = Unknown desc = failed to list refs: Get \"https://github.com/PratyushMishra-2nd/devops-heros.git/info/refs?service=git-upload-pack\": dial tcp: lookup github.com on 10.96.0.10:53: server misbehaving","type":"ComparisonError"}]
```

The repo-server could not resolve `github.com` through CoreDNS (`10.96.0.10`). A one-off busybox pod resolved it fine a minute later (`github.com` → `20.207.73.82`), so it was a temporary DNS failure while the node was under heavy load, not a config problem. Argo CD caches the failed comparison and does not retry right away, so I forced a hard refresh:

```bash
$ argocd app get session20-mini --hard-refresh --grpc-web
...
Sync Status:        OutOfSync from main (0678d7f)
Health Status:      Missing

GROUP  KIND        NAMESPACE  NAME            STATUS     HEALTH   HOOK  MESSAGE
       Namespace              session20       OutOfSync  Missing
       Service     session20  session20-mini  OutOfSync  Missing
apps   Deployment  session20  session20-mini  OutOfSync  Missing
```

`OutOfSync` / `Missing` means Argo CD can now read Git and sees three objects that do not exist in the cluster yet. Auto-sync created them a few seconds later:

```bash
$ kubectl get applications -n argocd
NAME             SYNC STATUS   HEALTH STATUS
s20-gitops-app   Synced        Healthy
session20-mini   Synced        Healthy

$ kubectl get all -n session20
NAME                                  READY   STATUS    RESTARTS   AGE
pod/session20-mini-68946db7dd-l9lqm   1/1     Running   0          29s
pod/session20-mini-68946db7dd-tvzdt   1/1     Running   0          29s

NAME                     TYPE        CLUSTER-IP      EXTERNAL-IP   PORT(S)   AGE
service/session20-mini   ClusterIP   10.104.125.30   <none>        80/TCP    29s

NAME                             READY   UP-TO-DATE   AVAILABLE   AGE
deployment.apps/session20-mini   2/2     2            2           29s

NAME                                        DESIRED   CURRENT   READY   AGE
replicaset.apps/session20-mini-68946db7dd   2         2         2       29s
```

2 replicas, matching `replicas: 2` in Git at commit `0678d7f`.

📸 `screenshots/07-mini-project-sync.png`

The same thing in the Argo CD UI (logged in as admin through the port-forward):

📸 `screenshots/05-argocd-applications.png` (both Applications, Healthy and Synced)

📸 `screenshots/06-argocd-mini-tree.png` (resource tree: Application → Namespace, Service, Deployment → ReplicaSets → Pods)

---

## 9. Self-healing: changing the cluster by hand

With `selfHeal: true`, anything I change with kubectl should be put back to what Git says. I wrote a small loop (`watch-mini.sh`) that prints the replica count, the image and Argo CD's sync status every couple of seconds:

```bash
for i in $(seq 1 ${1:-15}); do
  printf '%s  replicas=%s  image=%s  argo=%s\n' "$(date +%T)" \
    "$(kubectl get deploy session20-mini -n session20 -o jsonpath='{.spec.replicas}')" \
    "$(kubectl get deploy session20-mini -n session20 -o jsonpath='{.spec.template.spec.containers[0].image}')" \
    "$(kubectl get application session20-mini -n argocd -o jsonpath='{.status.sync.status}')"
  sleep 2
done
```

**Scale by hand to 5:**

```bash
$ kubectl scale deployment session20-mini -n session20 --replicas=5 && watch-mini.sh 12
deployment.apps/session20-mini scaled
17:02:06  replicas=5  image=nginx:1.27-alpine  argo=Synced
17:02:08  replicas=2  image=nginx:1.27-alpine  argo=Synced
17:02:11  replicas=2  image=nginx:1.27-alpine  argo=Synced
...
```

Back to 2 within about 2 seconds. It was fast enough that my loop never even caught the Application in `OutOfSync`.

**Change the image by hand:**

```bash
$ kubectl set image deployment/session20-mini app=nginx:1.25-alpine -n session20 && watch-mini.sh 12
deployment.apps/session20-mini image updated
17:02:38  replicas=2  image=nginx:1.25-alpine  argo=Synced
17:02:40  replicas=2  image=nginx:1.25-alpine  argo=Synced
17:02:43  replicas=2  image=nginx:1.25-alpine  argo=OutOfSync
17:02:46  replicas=2  image=nginx:1.25-alpine  argo=OutOfSync
...
17:02:59  replicas=2  image=nginx:1.25-alpine  argo=OutOfSync
17:03:02  replicas=2  image=nginx:1.27-alpine  argo=Synced
17:03:05  replicas=2  image=nginx:1.27-alpine  argo=Synced
```

Reverted to `nginx:1.27-alpine` from Git, but this time it took about 24 seconds, not 2.

**Delete the Service:**

```bash
$ kubectl delete service session20-mini -n session20; sleep 10; kubectl get svc -n session20
service "session20-mini" deleted from session20 namespace
No resources found in session20 namespace.

$ kubectl get svc -n session20; kubectl get application session20-mini -n argocd
No resources found in session20 namespace.
NAME             SYNC STATUS   HEALTH STATUS
session20-mini   OutOfSync     Healthy

$ kubectl logs -n argocd argocd-application-controller-0 --since=5m | grep session20-mini | grep -oE 'Skipping auto-sync: already attempted[^"]*' | tail -1
Skipping auto-sync: already attempted sync to [0678d7f49c9a6030bf0699644e70c9f639641b36] with timeout 0s (retrying in 2m21.502853028s)

$ kubectl get svc -n session20; kubectl get application session20-mini -n argocd
NAME             TYPE        CLUSTER-IP    EXTERNAL-IP   PORT(S)   AGE
session20-mini   ClusterIP   10.97.49.50   <none>        80/TCP    3s
NAME             SYNC STATUS   HEALTH STATUS
session20-mini   Synced        Healthy
```

The controller log explains the slowdown. Each self-heal back to the **same commit** gets an exponential backoff, so my third change in a row had to wait about 2m21s. Argo CD does this on purpose: if some other controller (an HPA, an operator, a person in a loop) keeps changing a field, the two would otherwise fight forever and hammer the API server. The Service came back after the backoff ran out with a new ClusterIP (`10.97.49.50` instead of `10.104.125.30`). Self-healing restores the *spec*, not the identity of the object, so anything that hardcoded the old IP would break. That is why you always use the DNS name.

**Delete the pods:**

```bash
$ kubectl delete pod -n session20 -l app=session20-mini; kubectl get pods -n session20
pod "session20-mini-68946db7dd-lpg4v" deleted from session20 namespace
pod "session20-mini-68946db7dd-p9bvq" deleted from session20 namespace
NAME                              READY   STATUS    RESTARTS   AGE
session20-mini-68946db7dd-7ql8v   1/1     Running   0          1s
session20-mini-68946db7dd-7z62k   1/1     Running   0          1s
```

Replacements in 1 second, but this one is **not** Argo CD. Pods are not in Git, the Deployment is. The ReplicaSet controller recreated them like it always does (session 10). Argo CD only cares that the Deployment still says 2 replicas, which it never stopped saying. It is easy to "demo self-healing" this way and credit the wrong controller.

📸 `screenshots/08-self-heal.png`

---

## 10. GitOps in action: changing Git instead of the cluster

<!-- TODO-GITCHANGE -->

I have the change ready locally: `08-mini-project/app/deployment.yaml` line 9, `replicas: 2` → `replicas: 3`. This section is waiting for that commit to be pushed to my fork, so Argo CD can pick it up and I can capture the result.

<!-- /TODO-GITCHANGE -->

---

## File index

| Path | What it is |
| --- | --- |
| `01-monitoring-vs-observability/README.md` | Concept notes (section 1) |
| `02-metrics-logs-traces/k8s-demo/` | busybox Deployment and Service used for `kubectl top` / `logs` (section 2) |
| `03-prometheus/docker-compose.yml`, `prometheus.yml` | Prometheus scraping itself every 5s (section 3) |
| `04-grafana/docker-compose.yml`, `prometheus.yml` | Prometheus plus Grafana (section 4) |
| `04-grafana/docker-compose.lab.yml` | **Mine.** Override: Grafana on host port 3001 plus anonymous Viewer |
| `04-grafana/dashboard-prometheus-self.json` | **Mine.** Dashboard posted to `/api/dashboards/db` |
| `05-introduction-to-gitops/app/`, `06-git-as-source-of-truth/gitops-repo/` | Sample manifests for the GitOps concept notes |
| `07-argocd/app/` | Deployment (5 replicas) and Service synced by `s20-gitops-app` |
| `07-argocd/argocd-application-pratyush.yaml` | **Mine.** Application pointing at my fork, excluding the nested Application file |
| `08-mini-project/app/` | Namespace, Deployment, Service synced by `session20-mini` (`deployment.yaml` has the pending `replicas: 3` change) |
| `08-mini-project/argocd-application-pratyush.yaml` | **Mine.** Mini-project Application with the `YOUR_USERNAME` placeholder filled in |
| `screenshots/` | Terminal and browser screenshots referenced above |

## Resources

- Original session folders: https://github.com/Nency-Ravaliya/devops-heros/tree/main/session20-monitoring-observability-gitops
- Prometheus querying basics: https://prometheus.io/docs/prometheus/latest/querying/basics/
- Grafana HTTP API: https://grafana.com/docs/grafana/latest/developers/http_api/
- Argo CD automated sync and self-heal: https://argo-cd.readthedocs.io/en/stable/user-guide/auto_sync/
