# Session 12: Ingress, ConfigMaps and Secrets

Used the manifests in this folder to pull configuration and credentials out of the container image, then put an NGINX Ingress in front of a frontend and a backend so one hostname routes to both. Everything below is copied straight from my terminal.

**Setup:** Ubuntu 26.04 on WSL2, Minikube v1.39.0 with the Docker driver, Kubernetes v1.37.0.

---

## 1. ConfigMap for non-sensitive config

`01-configmap/app-config.yaml` holds 5 plain key/value pairs.

```bash
$ kubectl apply -f 01-configmap/app-config.yaml
configmap/yatri-app-config created
NAME               DATA   AGE
yatri-app-config   5      0s

$ kubectl describe configmap yatri-app-config
Name:         yatri-app-config
Namespace:    default
Labels:       app=yatri-backend
Annotations:  <none>

Data
====
DEFAULT_CURRENCY:
----
INR

ENVIRONMENT:
----
production

LOG_LEVEL:
----
INFO

MAX_BOOKING_DAYS:
----
30

PORT:
----
5000


BinaryData
====

Events:  <none>

$ kubectl get configmap yatri-app-config -o jsonpath='{.data.ENVIRONMENT}'
$ kubectl get configmap yatri-app-config -o jsonpath='{.data.LOG_LEVEL}'
production
INFO
```

The point of this is that the same image can ship to dev, staging and production, and only the ConfigMap changes. Nothing gets rebuilt.

📸 `screenshots/01-configmap.png`

---

## 2. Secret for credentials, and why base64 is not security

`02-secret/db-secret.yaml` is an `Opaque` Secret with a DB user, password and database name.

```bash
$ kubectl apply -f 02-secret/db-secret.yaml
secret/yatri-db-secret created
NAME              TYPE     DATA   AGE
yatri-db-secret   Opaque   3      1s

$ kubectl describe secret yatri-db-secret
Name:         yatri-db-secret
Namespace:    default
Labels:       app=yatri-backend
Annotations:  <none>

Type:  Opaque

Data
====
POSTGRES_DB:        19 bytes
POSTGRES_PASSWORD:  14 bytes
POSTGRES_USER:      11 bytes
```

`describe` only shows you byte counts, which makes it look protected. It is not:

```bash
$ kubectl get secret yatri-db-secret -o jsonpath='{.data.POSTGRES_USER}' | base64 --decode
$ kubectl get secret yatri-db-secret -o jsonpath='{.data.POSTGRES_PASSWORD}' | base64 --decode
yatri_admin
secretpassword
```

One command and the password is back in plaintext. Base64 is an encoding, not encryption. Anyone with read access to Secrets in the namespace can do this, and by default Secrets are stored unencrypted in etcd. What a Secret actually buys you over a ConfigMap is RBAC you can scope separately, values kept out of `describe` and most logs, and the ability to mount them as tmpfs instead of writing to disk.

📸 `screenshots/02-secret-and-injection.png`

---

## 3. The trailing newline gotcha

This is the one that causes real authentication failures.

```bash
$ echo "secretpassword" | xxd
$ echo "secretpassword" | base64
$ echo -n "secretpassword" | xxd
$ echo -n "secretpassword" | base64
# with echo (adds a trailing newline):
00000000: 7365 6372 6574 7061 7373 776f 7264 0a    secretpassword.
c2VjcmV0cGFzc3dvcmQK

# with echo -n (clean):
00000000: 7365 6372 6574 7061 7373 776f 7264       secretpassword
c2VjcmV0cGFzc3dvcmQ=
```

Look at the last byte in the first hex dump: `0a`. That is a newline that `echo` appended, and it is inside the encoded value. The two base64 strings are different because of it, `...kK` versus `...kQ=`.

If you paste the first one into a Secret, your app connects to the database with the password `secretpassword\n` and gets rejected. Nothing in the logs will tell you there is an invisible byte on the end, which is why this wastes so much time. Always use `echo -n`, or better, `kubectl create secret generic --from-literal=` and let kubectl handle the encoding.

📸 `screenshots/02-secret-and-injection.png` (same shot as above)

---

## 4. Injecting both into a pod

`04-full-demo/backend.yaml` pulls in the whole ConfigMap with `envFrom.configMapRef`, then pulls in each credential individually with `env.valueFrom.secretKeyRef`.

```bash
$ kubectl apply -f 04-full-demo/configmap.yaml -f 04-full-demo/secret.yaml -f 04-full-demo/backend.yaml
$ kubectl rollout status deployment/yatri-backend
configmap/yatri-app-config configured
secret/yatri-db-secret configured
deployment.apps/yatri-backend created
service/yatri-backend-service created
Waiting for deployment "yatri-backend" rollout to finish: 0 of 2 updated replicas are available...
Waiting for deployment "yatri-backend" rollout to finish: 1 of 2 updated replicas are available...
deployment "yatri-backend" successfully rolled out

$ kubectl exec deploy/yatri-backend -- env | grep -E "ENVIRONMENT|LOG_LEVEL|POSTGRES|DEFAULT_CURRENCY" | sort
DEFAULT_CURRENCY=INR
ENVIRONMENT=production
LOG_LEVEL=INFO
POSTGRES_DB=yatri_production_db
POSTGRES_PASSWORD=secretpassword
POSTGRES_USER=yatri_admin
```

Both sources land in the same environment. The two styles are worth knowing apart: `envFrom` grabs every key in one go and is convenient for config, while `secretKeyRef` names one key at a time, which is what you want for credentials so you are explicit about exactly what each pod can see.

📸 `screenshots/02-secret-and-injection.png` (same shot as above)

---

## 5. Changing a ConfigMap does not change running pods

```bash
$ kubectl patch configmap yatri-app-config --type merge -p '{"data":{"ENVIRONMENT":"staging"}}'
configmap/yatri-app-config patched

# configmap now says:
staging
# but the running pod still says:
ENVIRONMENT=production
```

The ConfigMap says `staging` but the running pod still reports `production`. Environment variables are read once, when the container starts, so changing the source afterwards does nothing to a process that is already running.

```bash
$ kubectl rollout restart deployment/yatri-backend
deployment.apps/yatri-backend restarted
Waiting for deployment "yatri-backend" rollout to finish: 1 out of 2 new replicas have been updated...
Waiting for deployment "yatri-backend" rollout to finish: 1 out of 2 new replicas have been updated...
Waiting for deployment "yatri-backend" rollout to finish: 1 out of 2 new replicas have been updated...
Waiting for deployment "yatri-backend" rollout to finish: 1 old replicas are pending termination...
Waiting for deployment "yatri-backend" rollout to finish: 1 old replicas are pending termination...
deployment "yatri-backend" successfully rolled out

# after the restart the new pods say:
ENVIRONMENT=staging
```

`rollout restart` replaces the pods one at a time using the normal rolling update, so the new value gets picked up with no downtime.

Worth noting: this only applies to env vars. A ConfigMap mounted as a **volume** does get updated in place by the kubelet, though there is a sync delay of up to about a minute, and your app still has to notice the file changed.

---

## 6. Ingress resource vs Ingress controller

These are two separate things and the names make it confusing.

| | Ingress resource | Ingress controller |
| --- | --- | --- |
| What it is | A YAML object holding routing rules | A reverse proxy running as a pod |
| What it does on its own | Nothing at all | Watches the API for Ingress objects |
| Examples | The `yatri-ingress` below | NGINX, Traefik, HAProxy, Envoy |
| Analogy | The instructions | The thing that reads and follows them |

Create an Ingress with no controller installed and absolutely nothing happens. The object sits in etcd, `ADDRESS` stays blank, and no traffic moves. The controller is what turns those rules into real proxy config and reloads itself.

```bash
$ kubectl api-resources | grep -i ingress
ingressclasses                                   networking.k8s.io/v1              false        IngressClass
ingresses                           ing          networking.k8s.io/v1              true         Ingress
```

```bash
$ minikube addons enable ingress
💡  ingress is an addon maintained by Kubernetes. For any concerns contact minikube on GitHub.
You can view the list of minikube maintainers at: https://github.com/kubernetes/minikube/blob/master/OWNERS
    ▪ Using image registry.k8s.io/ingress-nginx/controller:v1.15.1
    ▪ Using image registry.k8s.io/ingress-nginx/kube-webhook-certgen:v1.6.9
    ▪ Using image registry.k8s.io/ingress-nginx/kube-webhook-certgen:v1.6.9
🔎  Verifying ingress addon...
🌟  The 'ingress' addon is enabled

$ kubectl wait --namespace ingress-nginx --for=condition=ready pod \
    --selector=app.kubernetes.io/component=controller --timeout=300s
$ kubectl get pods -n ingress-nginx
pod/ingress-nginx-controller-d7cd8c989-hk9b6 condition met

NAME                                       READY   STATUS      RESTARTS      AGE
ingress-nginx-admission-create-bkbdl       0/1     Completed   0             20m
ingress-nginx-admission-patch-s2shv        0/1     Completed   2 (20m ago)   20m
ingress-nginx-controller-d7cd8c989-hk9b6   1/1     Running     0             20m
```

The two `Completed` admission pods are one-off jobs that generate and patch the TLS certificate for the validating webhook. They are meant to finish and stay finished, so `0/1 Completed` there is normal and not a failure.

📸 `screenshots/03-ingress-and-routing.png`

---

## 7. Path based routing

`04-full-demo/ingress.yaml` puts both services behind the single host `yatri.local`, with `/` going to the frontend and `/api/` going to the backend.

```bash
$ kubectl apply -f 04-full-demo/frontend.yaml -f 04-full-demo/ingress.yaml
$ kubectl get ingress
NAME            CLASS   HOSTS         ADDRESS        PORTS   AGE
yatri-ingress   nginx   yatri.local   192.168.49.2   80      26s

$ kubectl describe ingress yatri-ingress
Name:             yatri-ingress
Labels:           app=yatri-app
Namespace:        default
Address:          192.168.49.2
Ingress Class:    nginx
Default backend:  <default>
Rules:
  Host         Path  Backends
  ----         ----  --------
  yatri.local  
               /api(/|$)(.*)   yatri-backend-service:80 (10.244.0.97:5000,10.244.0.98:5000)
               /               yatri-frontend-service:80 (10.244.0.99:80,10.244.0.100:80)
Annotations:   nginx.ingress.kubernetes.io/rewrite-target: /$2
               nginx.ingress.kubernetes.io/ssl-redirect: false
               nginx.ingress.kubernetes.io/use-regex: true
Events:
  Type    Reason  Age               From                      Message
  ----    ------  ----              ----                      -------
  Normal  Sync    20s (x2 over 26s)  nginx-ingress-controller  Scheduled for sync
```

`ADDRESS` filled in with `192.168.49.2` once the controller picked the object up, and the rules table shows each path resolved down to the actual pod IPs behind each service.

Testing both routes:

```bash
$ minikube ssh "curl -s -H 'Host: yatri.local' http://localhost/"
$ minikube ssh "curl -s -H 'Host: yatri.local' http://localhost/api/'"
# GET / -> frontend
<title>Welcome to nginx!</title>

# GET /api/ -> backend
Yatri Backend API
=================
ENVIRONMENT     : production
LOG_LEVEL       : INFO
DEFAULT_CURRENCY: INR
POSTGRES_USER   : yatri_admin
POSTGRES_DB     : yatri_production_db
```

Same IP, same port 80, two completely different backends, decided purely on the path. And the `/api/` response is showing the ConfigMap and Secret values from section 4, so the whole chain is working end to end.

I used `-H "Host: yatri.local"` rather than editing `/etc/hosts`. The Ingress matches on the HTTP `Host` header, so setting the header directly does the same job as a hosts entry without needing sudo. The `rewrite-target: /$2` annotation is what strips the `/api` prefix before the request reaches the backend, which is why the backend sees `/` and not `/api/`.

The whole stack:

```bash
NAME               DATA   AGE
yatri-app-config   5      29s

NAME              TYPE     DATA   AGE
yatri-db-secret   Opaque   3      29s

NAME                             READY   UP-TO-DATE   AVAILABLE   AGE
deployment.apps/yatri-backend    2/2     2            2           30s
deployment.apps/yatri-frontend   2/2     2            2           30s
NAME                             TYPE        CLUSTER-IP      EXTERNAL-IP   PORT(S)   AGE
service/kubernetes               ClusterIP   10.96.0.1       <none>        443/TCP   56m
service/yatri-backend-service    ClusterIP   10.102.224.22   <none>        80/TCP    30s
service/yatri-frontend-service   ClusterIP   10.110.197.2    <none>        80/TCP    30s
NAME                                      CLASS   HOSTS         ADDRESS        PORTS   AGE
ingress.networking.k8s.io/yatri-ingress   nginx   yatri.local   192.168.49.2   80      30s
```

📸 `screenshots/03-ingress-and-routing.png` (same shot as above)

---

## 8. How secrets are handled properly in production

Committing a Secret YAML to Git is the thing you are not supposed to do, even though base64 makes it feel fine.

The problems are that Git keeps history forever, so rotating the password does not remove the old one from the repo. Anyone who can clone the repo has the credential, which is a much wider group than the people who should have cluster access. And there is no audit trail of who read it or any way to rotate automatically.

What real setups do instead is keep the credential in a dedicated secret store and sync it in:

```
AWS Secrets Manager  /  Azure Key Vault  /  HashiCorp Vault
                    |
                    v
      External Secrets Operator (ESO)
      or Vault Agent Injector
                    |
                    v
      Kubernetes Secret (created in-cluster, never in Git)
                    |
                    v
      Pod, as env vars or a mounted volume
```

What goes into Git is an `ExternalSecret` object that just says which key to fetch from where. The value itself never touches the repo. The operator pulls it, creates the real Secret in the cluster, and refreshes it on a schedule so rotation happens without a redeploy.

For CI/CD the same idea applies. GitHub Actions secrets or Azure DevOps variable groups hold the values, the pipeline injects them at deploy time, and the manifests in the repo only ever contain references.

```bash
$ kubectl get crds | grep -i secret || echo "Standard native secrets in use"
Standard native secrets in use
```

Nothing installed on this cluster, so this lab uses plain native Secrets.

---

## Manifest index

| Path | What it is |
| --- | --- |
| `01-configmap/app-config.yaml` | ConfigMap with 5 config keys |
| `02-secret/db-secret.yaml` | Opaque Secret with DB credentials |
| `03-ingress/ingress-routes.yaml` | Standalone Ingress with the same routing rules |
| `04-full-demo/` | The complete stack: ConfigMap, Secret, backend, frontend, Ingress, plus run and cleanup scripts |
| `troubleshooting/secret-base64-gotcha.md` | Notes on the trailing newline problem |
