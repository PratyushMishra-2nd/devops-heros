# Session 15: Helm

**Pratyush Mishra · Roll No. 10486**

Went through the topic folders in order: generated a chart with `helm create`, read through what `Chart.yaml`, `values.yaml` and `templates/` each do, linted and rendered charts locally, then installed, upgraded, broke and rolled back real releases. Finished with the Notes App mini-project. Everything below is copied straight from my terminal.

**Setup:** Ubuntu 26.04 on WSL2, Minikube v1.39.0 with the Docker driver, Kubernetes v1.37.0, Helm v4.3.0. All releases went into my own namespaces (`s15-helm`, `s15-guestbook`, `s15-notes`).

> **Note on the Helm version:** the session material is written for Helm 3, but the version on my machine is Helm 4. Every command in the session works the same, with one exception that I hit in section 8 (`--atomic` is deprecated and renamed).

---

## 1. Creating a chart with `helm create`

```bash
$ helm version
version.BuildInfo{Version:"v4.3.0", GitCommit:"bec5b06ed841fe5269972d864d5177944fd5970f", GitTreeState:"clean", GoVersion:"go1.27.1", KubeClientVersion:"v1.37"}

$ helm create pratyush-chart
Creating pratyush-chart

$ ls -A pratyush-chart pratyush-chart/templates
pratyush-chart:
.helmignore
Chart.yaml
charts
templates
values.yaml

pratyush-chart/templates:
NOTES.txt
_helpers.tpl
deployment.yaml
hpa.yaml
httproute.yaml
ingress.yaml
service.yaml
serviceaccount.yaml
tests

$ diff -r -I 'pratyush-chart' -I 'demo-chart' -I '^version:' pratyush-chart /mnt/c/Codeing/Devops/devops-heros/session-15-helm/02-helm-charts/demo-chart && echo 'same scaffold as the repo demo-chart'
Only in pratyush-chart: charts

$ grep -v '^#' pratyush-chart/Chart.yaml | grep -v '^$'
apiVersion: v2
name: pratyush-chart
description: A Helm chart for Kubernetes
type: application
version: 0.1.0
appVersion: "1.16.0"
```

`helm create` gives you a full working chart for nginx, not an empty skeleton. Ignoring the lines that just contain the chart name, my generated chart is identical to `02-helm-charts/demo-chart` in the repo, apart from one thing: the empty `charts/` folder (where sub-chart dependencies go) is missing from the repo copy. Git does not track empty directories, so it disappeared when the instructor committed it. Helm does not care either way.

📸 `screenshots/01-helm-create.png`

---

## 2. Chart structure: Chart.yaml, values.yaml, templates

`03-chart-structure/simple-chart` is the smallest useful chart, just four files:

```bash
$ find simple-chart -type f | sort
simple-chart/Chart.yaml
simple-chart/templates/deployment.yaml
simple-chart/templates/service.yaml
simple-chart/values.yaml

$ cat simple-chart/Chart.yaml
apiVersion: v2
name: simple-chart
description: A simple Helm chart for learning
type: application
version: 0.1.0
appVersion: "1.0"

$ cat simple-chart/values.yaml
replicaCount: 1

image:
  repository: nginx
  tag: latest

service:
  port: 80
```

How I think of the three parts:

| Part | What it answers | Example |
| --- | --- | --- |
| `Chart.yaml` | What is this package? | name, `version` (of the chart), `appVersion` (of the app inside) |
| `values.yaml` | What are the defaults? | `replicaCount: 1`, `image.tag: latest` |
| `templates/` | What Kubernetes objects get created? | Deployment and Service YAML with `{{ .Values.x }}` holes in them |

`version` and `appVersion` are different things. `version` is bumped when the chart files change, `appVersion` tracks the application (usually the image tag). You can ship a new chart version that deploys the same app version.

Then lint and render without touching the cluster:

```bash
$ helm lint simple-chart
==> Linting simple-chart
[INFO] Chart.yaml: icon is recommended

1 chart(s) linted, 0 chart(s) failed

$ helm template my-release simple-chart
---
# Source: simple-chart/templates/service.yaml
apiVersion: v1
kind: Service
metadata:
  name: my-release-svc
spec:
  selector:
    app: my-release
  ports:
    - port: 80
      targetPort: 80

---
# Source: simple-chart/templates/deployment.yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: my-release-app
spec:
  replicas: 1
  selector:
    matchLabels:
      app: my-release
  template:
    metadata:
      labels:
        app: my-release
    spec:
      containers:
        - name: app
          image: "nginx:latest"
          ports:
            - containerPort: 80
```

`{{ .Release.Name }}` became `my-release` and `{{ .Values.image.tag }}` became `latest`. Every object name is prefixed with the release name, which is what lets you install the same chart twice in one namespace without the names clashing.

📸 `screenshots/02-lint-and-template.png`

---

## 3. What `helm lint` catches in Chart.yaml

I copied `04-chart-yaml/Chart.yaml` into a chart folder, linted it, then commented out `apiVersion` to see what a broken one looks like:

```bash
$ helm lint my-app
==> Linting my-app
[INFO] Chart.yaml: icon is recommended
[INFO] values.yaml: file does not exist

1 chart(s) linted, 0 chart(s) failed

$ sed -i 's/^apiVersion: v2/#apiVersion: v2/' my-app/Chart.yaml && helm lint my-app
==> Linting my-app
[ERROR] Chart.yaml: apiVersion is required. The value must be either "v1" or "v2"
[INFO] Chart.yaml: icon is recommended
[ERROR] Chart.yaml: chart type is not valid in apiVersion ''. It is valid in apiVersion 'v2'
[INFO] values.yaml: file does not exist

Error: 1 chart(s) linted, 1 chart(s) failed
```

`[INFO]` lines are suggestions, `[ERROR]` lines fail the lint with a non-zero exit code, which is what you want a CI step to stop on. The second error is a knock-on effect: `type:` only exists in `apiVersion: v2` (Helm 3+) charts, so once the apiVersion is gone Helm cannot validate it either.

---

## 4. values.yaml, `-f` and `--set` precedence

`05-values-yaml` has a `values.yaml` and a `values-prod.yaml`. The only real difference is the replica count:

```bash
$ diff values.yaml values-prod.yaml
1c1
< replicaCount: 1
---
> replicaCount: 5
11c11
<   name: demo-app
---
>   name: demo-app-prod

$ helm template demo ./my-app | grep -E 'replicas:|image:'
  replicas: 1
          image: "nginx:1.16.0"
      image: busybox

$ helm template demo ./my-app -f values-prod.yaml | grep -E 'replicas:|image:'
  replicas: 5
          image: "nginx:latest"
      image: busybox

$ helm template demo ./my-app -f values-prod.yaml --set replicaCount=2 | grep -E 'replicas:|image:'
  replicas: 2
          image: "nginx:latest"
      image: busybox
```

Three layers: the chart's own `values.yaml`, then any `-f` file on top, then `--set` on top of that. `--set` always wins. In the first render the image is `nginx:1.16.0` because the chart's `image.tag` is empty and the template falls back to `.Chart.AppVersion`. The `busybox` image is the `helm test` pod from `templates/tests/`, not part of the app.

Then a real install with the prod file:

```bash
$ helm install demo ./my-app -f values-prod.yaml -n s15-helm --wait --timeout 180s
NAME: demo
LAST DEPLOYED: Wed Oct  7 16:42:44 2026
NAMESPACE: s15-helm
STATUS: deployed
REVISION: 1
DESCRIPTION: Install complete
...

$ kubectl get deploy,pods,svc -n s15-helm -l app.kubernetes.io/instance=demo
NAME                          READY   UP-TO-DATE   AVAILABLE   AGE
deployment.apps/demo-my-app   5/5     5            5           2s

NAME                               READY   STATUS    RESTARTS   AGE
pod/demo-my-app-76fcccb449-4j5x2   1/1     Running   0          2s
pod/demo-my-app-76fcccb449-727rj   1/1     Running   0          2s
pod/demo-my-app-76fcccb449-q2qsr   1/1     Running   0          2s
pod/demo-my-app-76fcccb449-rc2bn   1/1     Running   0          2s
pod/demo-my-app-76fcccb449-tfj9z   1/1     Running   0          2s

NAME                  TYPE        CLUSTER-IP       EXTERNAL-IP   PORT(S)   AGE
service/demo-my-app   ClusterIP   10.103.199.229   <none>        80/TCP    2s

$ helm get values demo -n s15-helm
USER-SUPPLIED VALUES:
app:
  name: demo-app-prod
image:
  repository: nginx
  tag: latest
replicaCount: 5
service:
  port: 80
```

5 replicas, straight from `values-prod.yaml`. `helm get values` shows exactly what was passed in for a release, which is the first thing I would check if a release is behaving differently from what the chart defaults say.

📸 `screenshots/03-values-prod-install.png`

---

## 5. Templates, conditionals and `--dry-run`

`06-templates/template-demo/templates/service.yaml` is wrapped in `{{- if .Values.service.enabled }}`:

```bash
$ helm template t1 template-demo | grep -E '^kind:|# Source'
# Source: template-demo/templates/service.yaml
kind: Service
# Source: template-demo/templates/deployment.yaml
kind: Deployment

$ helm template t1 template-demo --set service.enabled=false | grep -E '^kind:|# Source'
# Source: template-demo/templates/deployment.yaml
kind: Deployment
```

With `service.enabled=false` the Service is not rendered at all, so the same chart can optionally include or skip objects.

Then I tried to break it on purpose, passing a string where Kubernetes wants a number:

```bash
$ helm template t1 template-demo --set replicaCount=abc | grep replicas
  replicas: abc

$ helm install t1 template-demo -n s15-helm --set replicaCount=abc --dry-run=server
NAME: t1
LAST DEPLOYED: Wed Oct  7 16:42:22 2026
NAMESPACE: s15-helm
STATUS: pending-install
REVISION: 1
DESCRIPTION: Dry run complete
...
spec:
  replicas: abc
...
```

This surprised me. Neither `helm template` nor `helm install --dry-run=server` complained about `replicas: abc`. Helm's dry run renders the templates (with `server` it is allowed to talk to the cluster for `lookup` calls), but it does not send the objects to the API server for schema validation. The thing that does catch it is a real server-side dry run with kubectl:

```bash
$ kubectl create namespace s15-helm
namespace/s15-helm created

$ helm template t1 template-demo --set replicaCount=abc | kubectl apply -n s15-helm --dry-run=server -f -
service/t1-svc created (server dry run)
Error from server (BadRequest): error when creating "STDIN": Deployment in version "v1" cannot be handled as a Deployment: json: cannot unmarshal string into Go struct field DeploymentSpec.spec.replicas of type int32

$ helm template t1 template-demo | kubectl apply -n s15-helm --dry-run=server -f -
service/t1-svc created (server dry run)
deployment.apps/t1-app created (server dry run)
```

So my pre-deploy check is: `helm lint`, then `helm template | kubectl apply --dry-run=server -f -`. The first catches chart mistakes, the second catches anything the API server would reject.

---

## 6. Install and upgrade (`07-install-upgrade/app-chart`)

```bash
$ helm install web-app ./app-chart -n s15-helm --wait
NAME: web-app
LAST DEPLOYED: Wed Oct  7 16:42:47 2026
NAMESPACE: s15-helm
STATUS: deployed
REVISION: 1
DESCRIPTION: Install complete
TEST SUITE: None

$ kubectl get deploy web-app-app -n s15-helm -o wide
NAME          READY   UP-TO-DATE   AVAILABLE   AGE   CONTAINERS   IMAGES       SELECTOR
web-app-app   1/1     1            1           1s    app          nginx:1.24   app=web-app

$ helm upgrade web-app ./app-chart -n s15-helm --set replicaCount=3 --wait
Release "web-app" has been upgraded. Happy Helming!
NAME: web-app
LAST DEPLOYED: Wed Oct  7 16:42:48 2026
NAMESPACE: s15-helm
STATUS: deployed
REVISION: 2
DESCRIPTION: Upgrade complete
TEST SUITE: None

$ kubectl get deploy web-app-app -n s15-helm -o wide; kubectl get pods -n s15-helm -l app=web-app
NAME          READY   UP-TO-DATE   AVAILABLE   AGE   CONTAINERS   IMAGES       SELECTOR
web-app-app   3/3     3            3           2s    app          nginx:1.24   app=web-app
NAME                           READY   STATUS    RESTARTS   AGE
web-app-app-5769cccf7c-cpq5d   1/1     Running   0          1s
web-app-app-5769cccf7c-d6x6k   1/1     Running   0          1s
web-app-app-5769cccf7c-gmg25   1/1     Running   0          2s
```

Then I bumped the image tag in a second upgrade:

```bash
$ helm upgrade web-app ./app-chart -n s15-helm --set image.tag=1.25 --wait
Release "web-app" has been upgraded. Happy Helming!
...
REVISION: 3

$ kubectl get deploy web-app-app -n s15-helm -o wide
NAME          READY   UP-TO-DATE   AVAILABLE   AGE   CONTAINERS   IMAGES       SELECTOR
web-app-app   1/1     1            1           23s   app          nginx:1.25   app=web-app
```

**The image changed, but my 3 replicas went back to 1.** Every `helm upgrade` starts again from the chart's `values.yaml` plus whatever you pass on *that* command. The `--set replicaCount=3` from the previous upgrade is not remembered. This is an easy way to accidentally scale production down. Two fixes: pass `--reuse-values` to carry the last release's values forward, or (better) keep all the values in a `-f` file in Git so every upgrade passes the full set.

```bash
$ helm upgrade web-app ./app-chart -n s15-helm --reuse-values --set replicaCount=3 --wait | grep -E 'REVISION|STATUS'
STATUS: deployed
REVISION: 4

$ kubectl get deploy web-app-app -n s15-helm -o wide
NAME          READY   UP-TO-DATE   AVAILABLE   AGE   CONTAINERS   IMAGES       SELECTOR
web-app-app   3/3     3            3           34s   app          nginx:1.25   app=web-app

$ helm history web-app -n s15-helm
REVISION	UPDATED                 	STATUS    	CHART          	APP VERSION	DESCRIPTION
1       	Wed Oct  7 16:42:47 2026	superseded	app-chart-0.1.0	1.0        	Install complete
2       	Wed Oct  7 16:42:48 2026	superseded	app-chart-0.1.0	1.0        	Upgrade complete
3       	Wed Oct  7 16:42:50 2026	superseded	app-chart-0.1.0	1.0        	Upgrade complete
4       	Wed Oct  7 16:43:21 2026	deployed  	app-chart-0.1.0	1.0        	Upgrade complete
```

Every install or upgrade is a new revision, and only one is `deployed` at a time.

📸 `screenshots/04-upgrade-history.png`

---

## 7. Rollback after a bad upgrade

Pushed a tag that does not exist (`08-rollback` scenario):

```bash
$ helm upgrade web-app ./app-chart -n s15-helm --reuse-values --set image.tag=doesnotexist | grep -E 'REVISION|STATUS'
STATUS: deployed
REVISION: 5

$ kubectl get pods -n s15-helm -l app=web-app
NAME                           READY   STATUS             RESTARTS   AGE
web-app-app-5c66747c-vfrbn     0/1     ImagePullBackOff   0          26s
web-app-app-79bdc85c7d-26rfv   1/1     Running            0          58s
web-app-app-79bdc85c7d-f5fk7   1/1     Running            0          27s
web-app-app-79bdc85c7d-hx9db   1/1     Running            0          27s

$ helm history web-app -n s15-helm
REVISION	UPDATED                 	STATUS    	CHART          	APP VERSION	DESCRIPTION
...
4       	Wed Oct  7 16:43:21 2026	superseded	app-chart-0.1.0	1.0        	Upgrade complete
5       	Wed Oct  7 16:43:22 2026	deployed  	app-chart-0.1.0	1.0        	Upgrade complete
```

Two things to notice. Helm reports revision 5 as `deployed` / `Upgrade complete` even though the new pod is stuck in `ImagePullBackOff`, because without `--wait` Helm only checks that the API server accepted the objects. And the app never actually went down: the Deployment's rolling update keeps the 3 old pods running until a new one becomes ready, which it never does.

```bash
$ helm rollback web-app 4 -n s15-helm --wait
Rollback was a success! Happy Helming!

$ kubectl get deploy web-app-app -n s15-helm -o wide; kubectl get pods -n s15-helm -l app=web-app
NAME          READY   UP-TO-DATE   AVAILABLE   AGE   CONTAINERS   IMAGES       SELECTOR
web-app-app   3/3     3            3           62s   app          nginx:1.25   app=web-app
NAME                           READY   STATUS        RESTARTS   AGE
web-app-app-5c66747c-vfrbn     0/1     Terminating   0          27s
web-app-app-79bdc85c7d-26rfv   1/1     Running       0          59s
web-app-app-79bdc85c7d-f5fk7   1/1     Running       0          28s
web-app-app-79bdc85c7d-hx9db   1/1     Running       0          28s

$ helm history web-app -n s15-helm
REVISION	UPDATED                 	STATUS    	CHART          	APP VERSION	DESCRIPTION
...
5       	Wed Oct  7 16:43:22 2026	superseded	app-chart-0.1.0	1.0        	Upgrade complete
6       	Wed Oct  7 16:43:49 2026	deployed  	app-chart-0.1.0	1.0        	Rollback to 4
```

The broken pod is terminated and we are back on `nginx:1.25` with 3 replicas. The rollback did not erase revision 5, it created revision 6 as a copy of revision 4. History only ever grows, so you can always see that a bad deploy happened.

---

## 8. Automatic rollback with `--atomic` (`--rollback-on-failure` in Helm 4)

```bash
$ helm upgrade web-app ./app-chart -n s15-helm --reuse-values --set image.tag=doesnotexist --atomic --timeout 60s
Flag --atomic has been deprecated, use --rollback-on-failure instead
level=WARN msg="upgrade failed" name=web-app error="resource Deployment/s15-helm/web-app-app not ready. status: InProgress, message: Updated: 1/3\ncontext deadline exceeded"
Error: UPGRADE FAILED: release web-app failed, and has been rolled back due to rollback-on-failure being set: resource Deployment/s15-helm/web-app-app not ready. status: InProgress, message: Updated: 1/3
context deadline exceeded

$ helm history web-app -n s15-helm
REVISION	UPDATED                 	STATUS    	CHART          	APP VERSION	DESCRIPTION
...
6       	Wed Oct  7 16:43:49 2026	superseded	app-chart-0.1.0	1.0        	Rollback to 4
7       	Wed Oct  7 16:44:01 2026	failed    	app-chart-0.1.0	1.0        	Upgrade "web-app" failed: resource Deployment/s15-helm/web-app-app not ready. status: InProgress, message: Updated: ...
8       	Wed Oct  7 16:45:01 2026	deployed  	app-chart-0.1.0	1.0        	Rollback to 6

$ kubectl get deploy web-app-app -n s15-helm -o wide
NAME          READY   UP-TO-DATE   AVAILABLE   AGE     CONTAINERS   IMAGES       SELECTOR
web-app-app   3/3     3            3           2m16s   app          nginx:1.25   app=web-app
```

This is the one place Helm 4 differs from the session notes: `--atomic` still works but prints a deprecation warning, the new name is `--rollback-on-failure`. It implies `--wait`, so Helm watched the Deployment for 60 seconds, saw it stuck at `Updated: 1/3`, marked revision 7 `failed` and rolled back on its own (revision 8). Exactly 60 seconds between revision 7 and 8. This is the flag I would use in a CI pipeline, since nobody is watching at 2am to run `helm rollback` manually.

📸 `screenshots/05-rollback-atomic.png`

---

## 9. Deploying the guestbook app (`09-deploying-application`)

A chart with a ConfigMap, a Deployment that loads it with `envFrom`, and a NodePort Service on 30080:

```bash
$ helm lint guestbook-chart
==> Linting guestbook-chart
[INFO] Chart.yaml: icon is recommended

1 chart(s) linted, 0 chart(s) failed

$ helm install my-guestbook guestbook-chart -n s15-guestbook --create-namespace --wait | head -6
NAME: my-guestbook
LAST DEPLOYED: Wed Oct  7 16:45:25 2026
NAMESPACE: s15-guestbook
STATUS: deployed
REVISION: 1
DESCRIPTION: Install complete

$ kubectl get pods,svc,configmap -n s15-guestbook
NAME                                    READY   STATUS    RESTARTS   AGE
pod/my-guestbook-app-744fd6b4cc-5vvwg   1/1     Running   0          41s

NAME                       TYPE       CLUSTER-IP      EXTERNAL-IP   PORT(S)        AGE
service/my-guestbook-svc   NodePort   10.96.239.194   <none>        80:30080/TCP   41s

NAME                            DATA   AGE
configmap/kube-root-ca.crt      1      41s
configmap/my-guestbook-config   2      41s

$ kubectl exec -n s15-guestbook deploy/my-guestbook-app -- env | grep -E 'welcome|appName'
appName=My Guestbook
welcome=Welcome to the Guestbook!

$ minikube ssh 'curl -s http://localhost:30080' | grep title
<title>Welcome to nginx!</title>
```

Then scale up and roll back:

```bash
$ helm upgrade my-guestbook guestbook-chart -n s15-guestbook --set replicaCount=3 --wait | grep REVISION; kubectl get pods -n s15-guestbook
REVISION: 2
NAME                                READY   STATUS    RESTARTS   AGE
my-guestbook-app-744fd6b4cc-5v5j8   1/1     Running   0          5s
my-guestbook-app-744fd6b4cc-5vvwg   1/1     Running   0          47s
my-guestbook-app-744fd6b4cc-fnrtv   1/1     Running   0          5s

$ helm rollback my-guestbook 1 -n s15-guestbook --wait && sleep 5 && kubectl get pods -n s15-guestbook
Rollback was a success! Happy Helming!
NAME                                READY   STATUS    RESTARTS   AGE
my-guestbook-app-744fd6b4cc-5vvwg   1/1     Running   0          53s

$ helm history my-guestbook -n s15-guestbook
REVISION	UPDATED                 	STATUS    	CHART                	APP VERSION	DESCRIPTION
1       	Wed Oct  7 16:45:25 2026	superseded	guestbook-chart-0.1.0	1.0        	Install complete
2       	Wed Oct  7 16:46:07 2026	superseded	guestbook-chart-0.1.0	1.0        	Upgrade complete
3       	Wed Oct  7 16:46:13 2026	deployed  	guestbook-chart-0.1.0	1.0        	Rollback to 1
```

All pods share the same ReplicaSet hash `744fd6b4cc` the whole way through. Changing only `replicas` does not change the pod template, so no new ReplicaSet is created and no pods are restarted; the scale-up just added two and the rollback just removed two. The nodePort `30080` is hardcoded in this chart's service template, which means you can only install it once per cluster. The mini-project fixes that by moving it into values.

---

## 10. Mini project: Notes App with dev and prod values

`mini-project/notes-chart` takes everything from above: ConfigMap with `APP_NAME` and `ENVIRONMENT`, a Deployment that loads it, NodePort Service with the port in values, and a `values-prod.yaml` with 3 replicas and `nginx:1.25`.

```bash
$ helm lint notes-chart -f notes-chart/values-prod.yaml
==> Linting notes-chart
[INFO] Chart.yaml: icon is recommended

1 chart(s) linted, 0 chart(s) failed

$ helm template notes-dev notes-chart | grep -E 'ENVIRONMENT|replicas|image:|nodePort'
  ENVIRONMENT: "development"
      nodePort: 30090
  replicas: 1
          image: "nginx:1.24"

$ helm install notes-dev notes-chart -n s15-notes --create-namespace --wait | grep -E 'STATUS|REVISION'
STATUS: deployed
REVISION: 1

$ kubectl get deploy,svc,cm -n s15-notes -o wide
NAME                               READY   UP-TO-DATE   AVAILABLE   AGE   CONTAINERS   IMAGES       SELECTOR
deployment.apps/notes-dev-deploy   1/1     1            1           1s    notes        nginx:1.24   app=notes-dev

NAME                    TYPE       CLUSTER-IP       EXTERNAL-IP   PORT(S)        AGE   SELECTOR
service/notes-dev-svc   NodePort   10.103.167.116   <none>        80:30090/TCP   1s    app=notes-dev

NAME                         DATA   AGE
configmap/kube-root-ca.crt   1      1s
configmap/notes-dev-config   2      1s

$ kubectl exec -n s15-notes deploy/notes-dev-deploy -- env | grep -E 'APP_NAME|ENVIRONMENT'
APP_NAME=notes-app
ENVIRONMENT=development
```

Promote the same release to production values:

```bash
$ helm upgrade notes-dev notes-chart -f notes-chart/values-prod.yaml -n s15-notes --wait | grep -E 'STATUS|REVISION'
STATUS: deployed
REVISION: 2

$ kubectl get deploy -n s15-notes -o wide; kubectl get pods -n s15-notes
NAME               READY   UP-TO-DATE   AVAILABLE   AGE   CONTAINERS   IMAGES       SELECTOR
notes-dev-deploy   3/3     3            3           4s    notes        nginx:1.25   app=notes-dev
NAME                                READY   STATUS      RESTARTS   AGE
notes-dev-deploy-74956bd987-j62xr   0/1     Completed   0          4s
notes-dev-deploy-bbcc464b4-2622c    1/1     Running     0          2s
notes-dev-deploy-bbcc464b4-5728h    1/1     Running     0          1s
notes-dev-deploy-bbcc464b4-pr4fj    1/1     Running     0          2s

$ kubectl exec -n s15-notes deploy/notes-dev-deploy -- env | grep -E 'APP_NAME|ENVIRONMENT'
APP_NAME=notes-app
ENVIRONMENT=production
```

3 replicas, `nginx:1.25`, and the pods now see `ENVIRONMENT=production`. The env change only reached the pods because the image tag changed too, which forced new pods. If only the ConfigMap had changed, the old pods would have kept `development` (same issue as session 12, section 5). The usual Helm fix is a `checksum/config` annotation on the pod template so any ConfigMap change also rolls the pods.

📸 `screenshots/06-mini-project-install.png`

Then a bad upgrade and rollback to revision 2:

```bash
$ helm upgrade notes-dev notes-chart -f notes-chart/values-prod.yaml --set image.tag=broken-tag-does-not-exist -n s15-notes | grep -E 'STATUS|REVISION'
STATUS: deployed
REVISION: 3

$ kubectl get pods -n s15-notes
NAME                                READY   STATUS             RESTARTS   AGE
notes-dev-deploy-79b4dbdffd-lhcvv   0/1     ImagePullBackOff   0          20s
notes-dev-deploy-bbcc464b4-2622c    1/1     Running            0          23s
notes-dev-deploy-bbcc464b4-5728h    1/1     Running            0          22s
notes-dev-deploy-bbcc464b4-pr4fj    1/1     Running            0          23s

$ helm rollback notes-dev 2 -n s15-notes --wait
Rollback was a success! Happy Helming!

$ kubectl get deploy -n s15-notes -o wide; kubectl get pods -n s15-notes
NAME               READY   UP-TO-DATE   AVAILABLE   AGE   CONTAINERS   IMAGES       SELECTOR
notes-dev-deploy   3/3     3            3           26s   notes        nginx:1.25   app=notes-dev
NAME                               READY   STATUS    RESTARTS   AGE
notes-dev-deploy-bbcc464b4-2622c   1/1     Running   0          24s
notes-dev-deploy-bbcc464b4-5728h   1/1     Running   0          23s
notes-dev-deploy-bbcc464b4-pr4fj   1/1     Running   0          24s

$ helm history notes-dev -n s15-notes
REVISION	UPDATED                 	STATUS    	CHART            	APP VERSION	DESCRIPTION
1       	Wed Oct  7 16:46:32 2026	superseded	notes-chart-0.1.0	1.0        	Install complete
2       	Wed Oct  7 16:46:33 2026	superseded	notes-chart-0.1.0	1.0        	Upgrade complete
3       	Wed Oct  7 16:46:37 2026	superseded	notes-chart-0.1.0	1.0        	Upgrade complete
4       	Wed Oct  7 16:46:58 2026	deployed  	notes-chart-0.1.0	1.0        	Rollback to 2

$ kubectl get secrets -n s15-notes -l owner=helm
NAME                              TYPE                 DATA   AGE
sh.helm.release.v1.notes-dev.v1   helm.sh/release.v1   1      27s
sh.helm.release.v1.notes-dev.v2   helm.sh/release.v1   1      25s
sh.helm.release.v1.notes-dev.v3   helm.sh/release.v1   1      22s
sh.helm.release.v1.notes-dev.v4   helm.sh/release.v1   1      1s

$ minikube ssh 'curl -s -o /dev/null -w "%{http_code}\n" http://localhost:30090'
200

$ helm list -A | grep s15
demo        	s15-helm     	1       	2026-10-07 16:42:44.833105386 +0000 UTC	deployed	my-app-0.1.0         	1.16.0
my-guestbook	s15-guestbook	3       	2026-10-07 16:46:13.348347961 +0000 UTC	deployed	guestbook-chart-0.1.0	1.0
notes-dev   	s15-notes    	4       	2026-10-07 16:46:58.329657183 +0000 UTC	deployed	notes-chart-0.1.0    	1.0
web-app     	s15-helm     	8       	2026-10-07 16:45:01.65168668 +0000 UTC 	deployed	app-chart-0.1.0      	1.0
```

The rollback brought back the exact same ReplicaSet (`bbcc464b4`), because revision 2's pod template is identical to what those pods were already running. The `sh.helm.release.v1.*` Secrets are where Helm 3+ keeps release history: one Secret per revision, in the release's own namespace. There is no Tiller and no server-side component; `helm history` and `helm rollback` just read these Secrets with my kubeconfig permissions. Helm keeps 10 revisions by default (`--history-max`).

📸 `screenshots/07-mini-project-rollback.png`

---

## File index

| Path | What it is |
| --- | --- |
| `01-what-is-helm/README.md` | Notes on what Helm is and Helm 2 vs 3 |
| `02-helm-charts/demo-chart/`, `myapp/` | Charts generated by `helm create` |
| `03-chart-structure/simple-chart/` | Minimal 4-file chart used in section 2 |
| `04-chart-yaml/Chart.yaml` | Chart.yaml with extra metadata, linted in section 3 |
| `05-values-yaml/my-app/`, `values.yaml`, `values-prod.yaml` | `helm create` chart plus default and prod value files (section 4) |
| `06-templates/template-demo/` | Chart with an `if` conditional around the Service (section 5) |
| `07-install-upgrade/app-chart/` | Chart used for install, upgrade, rollback and `--atomic` (sections 6 to 8) |
| `08-rollback/README.md` | Rollback walkthrough (uses the 07 chart) |
| `09-deploying-application/guestbook-chart/` | Guestbook chart with ConfigMap, Deployment, NodePort Service (section 9) |
| `mini-project/notes-chart/` | Notes App chart with `values.yaml` and `values-prod.yaml` (section 10) |
| `screenshots/` | Terminal screenshots referenced above |

## Resources

- Original session README: https://github.com/Nency-Ravaliya/devops-heros/blob/main/session-15-helm/README.md
- Helm docs: https://helm.sh/docs/
