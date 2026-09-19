# Session 9: Kubernetes Fundamentals & Minikube Setup

Installed Minikube and kubectl, ran the cluster through its lifecycle, and read up on the architecture from the official docs. All the output below is copied straight from my terminal.

**Setup:** Ubuntu 26.04 on WSL2, Docker driver.

---

## Task 1: Verify the installation

```bash
$ minikube version
minikube version: v1.39.0
commit: 7a9f6a841470a207de8cf4bafcccee0969d8ba10

$ kubectl version --client
Client Version: v1.34.1
Kustomize Version: v5.7.1
```

---

## Task 2: Start the cluster

```bash
$ minikube start --cpus=4 --memory=6g --driver=docker
😄  minikube v1.39.0 on Ubuntu 26.04 (kvm/amd64)
✨  Using the docker driver based on user configuration
📌  Using Docker driver with root privileges
❗  For an improved experience it's recommended to use Docker Engine instead of Docker Desktop.
Docker Engine installation instructions: https://docs.docker.com/engine/install/#server
👍  Starting "minikube" primary control-plane node in "minikube" cluster
🚜  Pulling base image v0.0.51 ...
🔥  Creating docker container (CPUs=4, Memory=6144MB) ...
📦  Preparing Kubernetes v1.37.0 on containerd 2.3.4 ...
🔗  Configuring CNI (Container Networking Interface) ...
🔎  Verifying Kubernetes components...
    ▪ Using image gcr.io/k8s-minikube/storage-provisioner:v5
🌟  Enabled addons: storage-provisioner, default-storageclass
❗  /usr/local/bin/kubectl is version 1.34.1, which may have incompatibilities with Kubernetes 1.37.0.
    ▪ Want kubectl v1.37.0? Try 'minikube kubectl -- get pods -A'
🏄  Done! kubectl is now configured to use "minikube" cluster and "default" namespace by default
```

I used `--cpus=4 --memory=6g` rather than a plain `minikube start`. The default profile gives you 2 CPUs and 2 GB, which was not enough for the multi-replica labs in Sessions 10 and 11. Pods just sat in `Pending` with an `Insufficient memory` event.

---

## Task 3: Check cluster status and node health

```bash
$ minikube status
minikube
type: Control Plane
host: Running
kubelet: Running
apiserver: Running
kubeconfig: Configured

$ kubectl get nodes -o wide
NAME       STATUS   ROLES           AGE    VERSION   INTERNAL-IP    EXTERNAL-IP   OS-IMAGE                         KERNEL-VERSION                              CONTAINER-RUNTIME
minikube   Ready    control-plane   117s   v1.37.0   192.168.49.2   <none>        Debian GNU/Linux 12 (bookworm)   6.18.33.1-microsoft-standard-WSL2 (amd64)   containerd://2.3.4

$ kubectl cluster-info
Kubernetes control plane is running at https://127.0.0.1:52672
CoreDNS is running at https://127.0.0.1:52672/api/v1/namespaces/kube-system/services/kube-dns:dns/proxy

To further debug and diagnose cluster problems, use 'kubectl cluster-info dump'.
```

One node, with the `control-plane` role, and it is `Ready`.

The thing I did not expect was the container runtime column. It says **containerd**, not Docker. Turns out dockershim was removed back in Kubernetes 1.24, so even though this is running on Docker Desktop, the runtime inside the node itself is containerd.

📸 `screenshots/01-cluster-lifecycle.png`

---

## Task 4: Stop the cluster

```bash
$ minikube stop
✋  Stopping node "minikube"  ...
🛑  Powering off "minikube" via SSH ...
🛑  1 node stopped.

$ minikube status
minikube
type: Control Plane
host: Stopped
kubelet: Stopped
apiserver: Stopped
kubeconfig: Stopped
```

Small thing worth knowing: `minikube status` exits with code 7 when the cluster is stopped. That is just how it reports the state, it does not mean the `stop` command failed.

📸 `screenshots/02-minikube-stop.png`

---

## Task 5: Cluster architecture

```
+-------------------------------------------------------------+
|                    CONTROL PLANE (MASTER)                   |
|                                                             |
|   etcd  <-->  kube-apiserver  <-->  kube-scheduler          |
|                      |                                      |
|                      v                                      |
|            kube-controller-manager                          |
+---------------------------+---------------------------------+
                            |
              +-------------+-------------+
              v                           v
    +-------------------+       +-------------------+
    |   WORKER NODE 1   |       |   WORKER NODE 2   |
    | kubelet kube-proxy|       | kubelet kube-proxy|
    |   containerd      |       |   containerd      |
    |  Pod A    Pod B   |       |  Pod C    Pod D   |
    +-------------------+       +-------------------+
```

### Control plane

| Component | What it does |
| --- | --- |
| **kube-apiserver** | The front door for everything. Every request goes through it, whether that is me running `kubectl`, a controller, or a kubelet reporting in. It handles authentication, authorisation and admission. It is also the only component allowed to talk to etcd directly. |
| **etcd** | A distributed key-value store that holds the whole cluster state. Everything in Kubernetes is an API object, and its desired state gets written here. |
| **kube-scheduler** | Looks for Pods that have no node assigned yet. It filters nodes based on resource requests, taints and affinity rules, then picks the best one and binds the Pod to it. |
| **kube-controller-manager** | Runs the control loops that keep pushing current state towards desired state. It bundles a bunch of controllers together: the Node controller, the ReplicaSet controller, the EndpointSlice controller and others. |

### Worker node

| Component | What it does |
| --- | --- |
| **kubelet** | The agent on each node. It takes PodSpecs from the API server, tells containerd to actually run them, runs the health probes, and reports status back. |
| **kube-proxy** | Keeps the iptables (or IPVS) rules that make Service ClusterIPs work. A ClusterIP is not assigned to any real network interface, it only exists as these rules. |
| **containerd (CRI)** | The bit that actually pulls images and runs containers. |
| **Pod** | The smallest thing you can deploy. Containers inside one Pod share a network namespace and a single IP, so they can reach each other over `localhost`. |

### What actually happens when you run `kubectl apply -f pod.yml`

```
kubectl  -->  kube-apiserver  -->  etcd            (desired state saved, no node picked yet)
                    |
              kube-scheduler                        (picks a node, writes spec.nodeName)
                    |
              kubelet on that node  -->  containerd (pulls image, sets up netns, starts container)
                    |
              status reported back  -->  kube-apiserver  -->  etcd
```

---

## What I took away from this session

The main thing that clicked for me is that `kubectl apply` succeeding does not mean your container is running. All it means is that the API server accepted the object and wrote it to etcd. Whether the container actually starts gets reported back later, separately, as status. That is exactly why you can get a clean `pod/x created` message and then find `ImagePullBackOff` when you check on it, which is what happens in Session 10.

Desired state and observed state are kept deliberately separate, and the controllers are the things that close the gap between them.

## Resources

- <https://kubernetes.io/docs/tutorials/kubernetes-basics/>
- <https://minikube.sigs.k8s.io/docs/start/>
- <https://kubernetes.io/docs/concepts/architecture/>
- <https://github.com/Nency-Ravaliya/Kubernetes>
