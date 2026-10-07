# Session 17: DevSecOps Pipeline

**Pratyush Mishra · Roll No. 10486**

Took the Session 17 demo app (`demo/`) and its pipeline into my own repo, [PratyushMishra-2nd/CI_CD-PIPE](https://github.com/PratyushMishra-2nd/CI_CD-PIPE), and got it running end to end: unit tests, SAST, SCA, Docker build, Trivy image scan, push to Docker Hub, deploy to Kubernetes. Then I went through it stage by stage and re-ran each security check locally with the real tools, to see what each one actually finds and whether it actually stops the pipeline. That second part turned out to be the interesting bit. Command output below is copied from my terminal.

**Setup:** GitHub Actions (`ubuntu-latest`) for the pipeline. Locally: Ubuntu 26.04 on WSL2, Docker, Minikube v1.39.0 / Kubernetes v1.37.0. Scanners run from their Docker images: bandit 1.9.4, pip-audit 2.10.1, Trivy (`aquasec/trivy:latest`), gitleaks v8.30.1.

---

## 1. The pipeline and the run

`.github/workflows/devsecops.yml` in my repo is the instructor's `demo/.github/workflows/devsecops.yml` with the Docker Hub account and image name changed to mine (`basanti13/python-web`). Seven jobs:

```
Unit Tests ──────────┐
SAST - CodeQL ───────┼─► Docker Build ─► Image Scan - Trivy ─► Push Image to Docker Hub ─► Deploy to Kubernetes
SCA - Dependency Scan┘
```

📸 `screenshots/01-devsecops-pipeline-run.png`: run #2 ("added my name", commit `5512d55`, push to `main`), **Success** in **3m 31s**. Unit Tests 11s, SAST-CodeQL 1m 6s, SCA 12s, Docker Build 9s, Image Scan - Trivy 32s, Push Image to Docker Hub 29s, Deploy to Kubernetes 1m 0s.

All three runs, from the GitHub API:

| Run | Commit | Result | Notes |
| --- | --- | --- | --- |
| [#1](https://github.com/PratyushMishra-2nd/CI_CD-PIPE/actions/runs/36109773317) | `d96dca3` "1st commit" | failure | Everything up to the image scan passed; **Login to Docker Hub** failed with `Password required` (no `DOCKERHUB_TOKEN` secret yet, and still the instructor's username). Push and deploy skipped. |
| [#2](https://github.com/PratyushMishra-2nd/CI_CD-PIPE/actions/runs/36110210581) | `5512d55` "added my name" | success | Workflow switched to my Docker Hub account, secret added. This is the screenshot. |
| [#3](https://github.com/PratyushMishra-2nd/CI_CD-PIPE/actions/runs/36110614130) | `2ad869b` "all test perfect" | success | Only added a PNG; all 7 jobs green again. |

The structure is the important part. Tests, SAST and SCA have no `needs:`, so they run in parallel. `docker-build` has `needs: [test, sast, sca]`, so nothing gets built unless all three pass, and each later stage `needs:` the one before. Every `needs:` is a potential **security gate**: if the job before it exits non-zero, everything after is skipped. Run #1 shows that working: the push failed and deploy never ran.

But a gate only works if the scanner actually exits non-zero when it finds something. Going stage by stage below, that is not true for half of them.

---

## 2. Stage 1: unit tests

```yaml
test:
  name: Unit Tests
  runs-on: ubuntu-latest
  steps:
    - uses: actions/checkout@v4
    - uses: actions/setup-python@v5
      with:
        python-version: "3.12"
    - run: pip install -r requirements-dev.txt
    - run: pytest --cov=app --cov-report=term-missing
```

Same thing locally, same Python version:

```bash
$ docker run --rm -v "$PWD":/src -w /src python:3.12-slim sh -c "pip install -q --root-user-action=ignore --disable-pip-version-check -r requirements-dev.txt && pytest -p no:cacheprovider --cov=app --cov-report=term-missing -q -W ignore::DeprecationWarning"
........                                                                 [100%]

---------- coverage: platform linux, python 3.12.15-final-0 ----------
Name              Stmts   Miss  Cover   Missing
-----------------------------------------------
app/__init__.py       0      0   100%
app/app.py          102     32    69%   94, 104-105, 121, 128, 132-133, 145, 179-209, 225, 230, 234
-----------------------------------------------
TOTAL               102     32    69%

8 passed in 0.69s
```

8 tests pass. Coverage is 69%, but nothing enforces a minimum, so coverage is reported, not gated. Adding `--cov-fail-under=80` would turn it into a gate. (I hid the `datetime.utcnow()` deprecation warnings here; the first run printed six of them.)

📸 `screenshots/03-tests-and-sast-bandit.png`

---

## 3. Stage 2: SAST (CodeQL), and what bandit found

SAST reads the source code without running it and looks for insecure patterns.

```yaml
sast:
  name: SAST - CodeQL
  permissions:
    contents: read
    security-events: write     # needed to upload results to the Security tab
  steps:
    - uses: actions/checkout@v4
    - uses: github/codeql-action/init@v3
      with:
        languages: python
    - uses: github/codeql-action/analyze@v3
```

CodeQL uploads its findings to the repo's **Security → Code scanning** tab. It does **not** fail the job when it finds something; the job goes green either way. So it is a report, not a gate, unless you add branch protection on code-scanning results.

I ran bandit (a Python SAST tool) on the same code locally, with a severity threshold so it behaves like a gate:

```bash
$ docker run --rm -v "$PWD":/src:ro -w /src python:3.12-slim sh -c "pip install -q ... bandit && bandit -q -r app --severity-level medium -f custom --msg-template \"{relpath}:{line} {test_id} {severity} {msg}\""; echo "bandit exit code: $?"
app/app.py:234 B201 HIGH A Flask app appears to be run with debug=True, which exposes the Werkzeug debugger and allows the execution of arbitrary code.
app/app.py:234 B104 MEDIUM Possible binding to all interfaces.
bandit exit code: 1
```

The full run also reports five LOW `B311` findings for `random.choice` / `random.uniform`. Those are fine here: the randomness is for a demo greeting and fake pipeline timings, nothing security related.

**B201 is a real problem, and it is in production.** The last line of `app/app.py` is `app.run(host="0.0.0.0", port=5001, debug=True)`, and the Dockerfile runs exactly that (`CMD ["python", "app/app.py"]`). The pods the pipeline image runs in on my cluster confirm it:

```bash
$ kubectl logs -n default deploy/session17-python | head -8
Found 2 pods, using pod/session17-python-7c4fd7db48-chcq5
/app/app/app.py:13: DeprecationWarning: datetime.datetime.utcnow() is deprecated ...
  _start_time = datetime.datetime.utcnow()
 * Serving Flask app 'app'
 * Debug mode: on
WARNING: This is a development server. Do not use it in a production deployment. Use a production WSGI server instead.
 * Running on all addresses (0.0.0.0)
 * Running on http://127.0.0.1:5001
```

`Debug mode: on`, on all interfaces. The Werkzeug debugger lets anyone who triggers an error run Python in the container from the browser. The pipeline was all green while shipping this. The fix is to read debug from an env var that defaults to off and to serve with gunicorn instead of the Flask dev server, and to make the SAST job fail on HIGH findings so it cannot happen again.

📸 `screenshots/03-tests-and-sast-bandit.png`

---

## 4. Stage 3: SCA (pip-audit)

SCA checks third-party dependencies against vulnerability databases. SAST is about *our* code, SCA is about *everyone else's* code we pull in.

```yaml
sca:
  name: SCA - Dependency Scan
  steps:
    - uses: actions/checkout@v4
    - uses: actions/setup-python@v5
      with:
        python-version: "3.12"
    - run: |
        pip install -r requirements.txt
        pip install pip-audit
    - run: pip-audit
```

pip-audit exits 1 when it finds a vulnerability, so this one is a real gate. But look at what it is pointed at:

```bash
$ docker run --rm -v "$PWD":/src:ro -w /src python:3.12-slim sh -c "pip install -q ... pip-audit && pip-audit --version && pip-audit -r requirements.txt -r requirements-dev.txt --desc off"; echo "pip-audit exit code: $?"
pip-audit 2.10.1
Found 2 known vulnerabilities in 1 package
Name   Version ID              Fix Versions
------ ------- --------------- ------------
pytest 8.4.2   PYSEC-2026-1845 9.0.3
pytest 8.4.2   PYSEC-2026-1845 9.0.3
pip-audit exit code: 1

$ docker run --rm -v "$PWD":/src:ro -w /src python:3.12-slim sh -c "pip install -q ... -r requirements.txt pip-audit && pip-audit"; echo "pip-audit exit code: $?"
Found 12 known vulnerabilities in 1 package
Name Version ID              Fix Versions
---- ------- --------------- ------------
pip  25.0.1  PYSEC-2026-1795 25.3
pip  25.0.1  PYSEC-2026-1796 26.0
pip  25.0.1  PYSEC-2026-2875 26.1
...
pip  25.0.1  PYSEC-2026-3721 26.2.0
pip-audit exit code: 1
```

Two things I learned from this:

1. **Bare `pip-audit` audits whatever is installed in the environment, not the project's requirement files.** The CI job only installs `requirements.txt`, so `pytest==8.4.2` from `requirements-dev.txt`, which has a known vulnerability (fixed in 9.0.3), is never checked. Auditing both files directly (first command) is what catches it. Flask 3.1.3 itself is clean.
2. Because it audits the environment, the result depends on the runner image. In the `python:3.12-slim` image the bundled pip is 25.0.1 and gets flagged (second command), so the same command that passed on GitHub's runner (presumably because `setup-python` brings a newer pip) fails here. Pointing it at `-r requirements.txt` avoids auditing the tooling.

The scan was green in September; this is today's database. The vulnerability database changes every day, so a dependency scan that passed last month can fail today with no code change. That is why it needs to run on every push and ideally on a schedule too.

📸 `screenshots/04-sca-pip-audit.png`

---

## 5. Stage 4: secret scanning (missing from the pipeline)

The `06-secret-scanning` lesson covers keeping credentials out of Git. My pipeline does not have a secret-scanning job at all; the closest thing is GitHub's own secret scanning / push protection on the repo. So I ran gitleaks locally, on the demo folder and on the full Git history of my repo:

```bash
$ docker run --rm -v "$PWD":/scan:ro zricethezav/gitleaks:latest version
v8.30.1

$ docker run --rm -v "$PWD":/scan:ro zricethezav/gitleaks:latest dir /scan/demo --no-banner; echo "exit code: $?"
4:51PM INF scanned ~116763 bytes (116.76 KB) in 97.8ms
4:51PM INF no leaks found
exit code: 0

$ git log --oneline && docker run --rm -v "$PWD":/repo:ro zricethezav/gitleaks:latest git /repo --no-banner; echo "exit code: $?"
2ad869b all test perfect
5512d55 added my name
d96dca3 1st commit
4:51PM INF 2 commits scanned.
4:51PM INF scanned ~56446 bytes (56.45 KB) in 64ms
4:51PM INF no leaks found
exit code: 0
```

Clean, which is what I expected, because the Docker Hub token only ever lived in GitHub's encrypted secrets (`${{ secrets.DOCKERHUB_TOKEN }}`), never in a file. History matters as much as the current files: a secret committed and then deleted is still in every clone.

To check it actually catches something, I put a fake GitHub token (random characters) in a throwaway folder outside the repo:

```bash
$ printf "GITHUB_TOKEN = \"ghp_%s\"\n" $(head -c 200 /dev/urandom | tr -dc A-Za-z0-9 | head -c 36) > config.py && cat config.py
GITHUB_TOKEN = "ghp_AVzxO29bf56KCCFmxez4UqJ0hCXVjOwW9xXb"

$ docker run --rm -v "$PWD":/scan:ro zricethezav/gitleaks:latest dir /scan --no-banner --redact -v; echo "exit code: $?"
Finding:     GITHUB_TOKEN = "REDACTED
Secret:      REDACTED
RuleID:      github-pat
Entropy:     4.734184
File:        /scan/config.py
Line:        1
Fingerprint: /scan/config.py:github-pat:1

4:51PM INF scanned ~58 bytes (58 bytes) in 6.11ms
4:51PM WRN leaks found: 1
exit code: 1
```

Caught by the `github-pat` rule, and exit code 1, so as a pipeline job it would block. Adding it is one more parallel job next to SAST and SCA (`gitleaks/gitleaks-action`, with `fetch-depth: 0` on checkout so it sees the whole history), and `docker-build` would then `needs:` it too.

📸 `screenshots/07-secret-scanning-gitleaks.png`

---

## 6. Stage 5: container image scan (Trivy)

The source and the dependencies can be clean and the image still full of holes, because the image also contains a whole Debian userland. Trivy scans the built image.

```yaml
image-scan:
  needs: [docker-build]
  steps:
    - uses: actions/checkout@v4
    - run: docker build -t session17-python:${{ github.sha }} .
    - name: Install Trivy
      run: |   # adds the aquasecurity apt repo and installs trivy
        ...
    - name: Scan image
      run: trivy image --severity HIGH,CRITICAL session17-python:${{ github.sha }}
```

Note that it rebuilds the image, because each job is a fresh runner and `docker-build` did not pass the image along. I built the same Dockerfile locally and scanned it:

```bash
$ docker build -q -t session17-python:local . && docker images session17-python:local
sha256:6174c2667dc9354dfa0b706572d9cd91c0ca8e1e4c2e6cf15a40528b21affa11
IMAGE                    ID             DISK USAGE   CONTENT SIZE   EXTRA
session17-python:local   6174c2667dc9        200MB         49.2MB

$ docker run --rm -v /var/run/docker.sock:/var/run/docker.sock -v trivy-cache:/root/.cache/ aquasec/trivy:latest image --quiet --severity HIGH,CRITICAL session17-python:local
Report Summary
│ session17-python:local (debian 13.7)                                         │   debian   │       44        │    -    │
│ usr/local/lib/python3.12/site-packages/flask-3.1.3.dist-info/METADATA        │ python-pkg │        0        │    -    │
│ usr/local/lib/python3.12/site-packages/werkzeug-3.1.9.dist-info/METADATA     │ python-pkg │        0        │    -    │
...
session17-python:local (debian 13.7)
====================================
Total: 44 (HIGH: 44, CRITICAL: 0)

│ bsdutils      │ CVE-2026-76642 │ HIGH     │ affected     │ 1:2.41.5-0+deb13u1                │               │ util-linux: util-linux: failed external mount helper still  │
...
│ libacl1       │ CVE-2026-54369 │          │              │ 2.3.2-2+b1                        │               │ acl: Symlink traversal privilege escalation via libacl      │
...
```

44 HIGH findings, all in Debian packages from the `python:3.12-slim` base (util-linux, systemd libs, ncurses, perl-base, acl). The Python packages are all clean. Every one of the 44 is status `affected` with no fixed version yet, so a rebuild would not help today.

📸 `screenshots/05-trivy-image-scan.png`

### The gate that is not a gate

```bash
$ docker run ... aquasec/trivy:latest image --quiet --severity HIGH,CRITICAL session17-python:local | grep -E "^Total"; echo "exit code: ${PIPESTATUS[0]}"
Total: 44 (HIGH: 44, CRITICAL: 0)
exit code: 0

$ docker run ... aquasec/trivy:latest image --quiet --severity HIGH,CRITICAL --exit-code 1 session17-python:local | grep -E "^Total"; echo "exit code: ${PIPESTATUS[0]}"
Total: 44 (HIGH: 44, CRITICAL: 0)
exit code: 1

$ docker run ... aquasec/trivy:latest image --quiet --severity CRITICAL --exit-code 1 session17-python:local | grep -E "^Total"; echo "exit code: ${PIPESTATUS[0]}"
exit code: 0

$ docker run ... aquasec/trivy:latest image --quiet --severity HIGH,CRITICAL --ignore-unfixed --exit-code 1 session17-python:local | grep -E "^Total"; echo "exit code: ${PIPESTATUS[0]}"
exit code: 0
```

**Trivy exits 0 by default no matter what it finds.** My pipeline's scan step has no `--exit-code 1`, so the "Image Scan - Trivy" job is green whatever is in the image. It printed a table and the image went on to Docker Hub and Kubernetes. The instructor's `07-container-image-scanning` lesson has the flag (`--exit-code 1`); I lost it when adapting the workflow.

The last three commands are the policy choice. `--exit-code 1` on HIGH,CRITICAL would block every build right now on 44 findings nobody can fix yet, which just teaches people to turn the scan off. What I would actually ship is `--severity CRITICAL --exit-code 1` (block on critical) or `--severity HIGH,CRITICAL --ignore-unfixed --exit-code 1` (block on anything that has a fix available). Both pass today (no output, because zero findings means no table) and would fail the moment a fixable HIGH or any CRITICAL shows up. (Again, today's database; the September run would have had different numbers.)

📸 `screenshots/06-trivy-gate.png`

---

## 7. Stage 6 and 7: push and deploy

```yaml
push:
  needs: [image-scan]
  steps:
    - uses: docker/login-action@v3
      with:
        username: basanti13
        password: ${{ secrets.DOCKERHUB_TOKEN }}
    - run: |
        docker build -t basanti13/python-web:${{ github.sha }} -t basanti13/python-web:latest .
        docker push basanti13/python-web:${{ github.sha }}
        docker push basanti13/python-web:latest

deploy:
  needs: [push]
  if: github.ref == 'refs/heads/main' && github.event_name == 'push'
  steps:
    - uses: helm/kind-action@v1.10.0          # throwaway Kind cluster on the runner
    - run: sed -i "s|__IMAGE_TAG__|${{ github.sha }}|g" k8s/deployment.yaml
    - run: kubectl apply -f k8s/deployment.yaml && kubectl apply -f k8s/service.yaml
    - run: kubectl rollout status deployment/session17-python --timeout=60s
    - run: |   # port-forward and curl the app inside CI
        ...
```

Every image gets two tags, the commit SHA (immutable, traceable to the exact commit) and `latest`. The `if:` on deploy means pull requests run all the checks but never deploy.

Here is the chain from the pipeline to my Minikube cluster, read-only:

```bash
$ kubectl get deploy,pods,svc -n default -o wide | grep -E "NAME|session17"
NAME                               READY   UP-TO-DATE   AVAILABLE   AGE   CONTAINERS         IMAGES                        SELECTOR
deployment.apps/session17-python   2/2     2            2           12d   session17-python   basanti13/python-web:latest   app=session17-python
NAME                                    READY   STATUS    RESTARTS        AGE   IP           NODE       NOMINATED NODE   READINESS GATES
pod/session17-python-7c4fd7db48-chcq5   1/1     Running   1 (9m28s ago)   12d   10.244.0.4   minikube   <none>           <none>
pod/session17-python-7c4fd7db48-xzngb   1/1     Running   1 (9m28s ago)   12d   10.244.0.5   minikube   <none>           <none>
NAME                       TYPE        CLUSTER-IP      EXTERNAL-IP   PORT(S)        AGE   SELECTOR
service/session17-python   NodePort    10.107.16.245   <none>        80:30001/TCP   12d   app=session17-python

$ kubectl get pods -n default -l app=session17-python -o jsonpath="{range .items[*]}{.metadata.name}  {.status.containerStatuses[0].imageID}{\"\n\"}{end}"
session17-python-7c4fd7db48-chcq5  docker.io/basanti13/python-web@sha256:12477121692544ab587dccf6f6d4d2bef482da006086321a1fdbf2e9a67630e7
session17-python-7c4fd7db48-xzngb  docker.io/basanti13/python-web@sha256:12477121692544ab587dccf6f6d4d2bef482da006086321a1fdbf2e9a67630e7

$ curl -s "https://hub.docker.com/v2/repositories/basanti13/python-web/tags?page_size=10" | python3 -c "..."
latest 2026-09-25T08:03:25 sha256:12477121692544ab587dccf6f6d4d2bef482da006086321a1fdbf2e9a67630e7
2ad869b092c83b247c9fcfc2685d16dde50f6c60 2026-09-25T08:03:23 sha256:12477121692544ab587dccf6f6d4d2bef482da006086321a1fdbf2e9a67630e7
5512d55cfdb179461f167bf1b84cf1dc994fcb4b 2026-09-25T07:58:31 sha256:4b0540ac5135bbb9fdf8763b40725b72ce2cf92712ff2b8e717d9125737c8683

$ minikube ssh -- curl -s http://localhost:30001/api/status; echo
{
  "app": "DevSecOps Dashboard",
  "platform": "Linux",
  "python_version": "3.12.14",
  "status": "running",
  ...
  "version": "2.0.0"
}
```

The pods are running digest `sha256:12477121...`, which on Docker Hub is the image tagged `2ad869b...`, pushed by run #3 at 08:03 UTC. So the cluster is running exactly what the pipeline built, scanned and pushed. Docker Hub has one SHA tag per green run (#2 and #3) and none for #1, whose push failed.

To be accurate about how it got there: the pipeline's deploy job deploys to a **throwaway Kind cluster on the GitHub runner** (to prove the manifests apply and the app answers), not to my laptop, which GitHub cannot reach. The Minikube deployment was applied by me from the same `k8s/` manifests (it was created at 07:18 UTC, before the first pipeline run). It uses `image: basanti13/python-web:latest` with `imagePullPolicy: Always`, so when the pods restarted they pulled the newest `latest`, which is run #3's image.

Two things I would change:

- My `k8s/deployment.yaml` hard-codes `:latest`, so the `sed s|__IMAGE_TAG__|...|` step finds nothing to replace and the deploy is not pinned to the commit (the instructor's manifest has the `__IMAGE_TAG__` placeholder; I replaced it when I changed the image name). Deploying the SHA tag means a rollback is a known image, not "whatever latest was".
- `demo/.dockerignore  │` has `  │` (two spaces and a box-drawing character) at the end of its name, so Docker never reads it. It is empty anyway, which is why `app/__pycache__/` gets copied into the image.

📸 `screenshots/02-cluster-and-registry.png`

---

## 8. Security gates: what actually blocks

| Stage | Tool | Exits non-zero on findings? | Gate in my pipeline? | Fix |
| --- | --- | --- | --- | --- |
| Unit tests | pytest | Yes, on failures | **Yes** | Add `--cov-fail-under=80` to gate on coverage too |
| SAST | CodeQL | No (uploads to Security tab) | **No** | Fail on HIGH (bandit `--severity-level high`, or a required code-scanning check) |
| SCA | pip-audit | Yes | **Yes**, but only audits the runtime env | `pip-audit -r requirements.txt -r requirements-dev.txt` |
| Secret scan | gitleaks | Yes | **Missing** | Add a gitleaks job with full history |
| Image scan | Trivy | Only with `--exit-code 1` | **No** | `--severity CRITICAL --exit-code 1`, or `HIGH,CRITICAL --ignore-unfixed --exit-code 1` |
| Push / deploy | | | Protected by `needs:` and the `main`-only `if:` | Deploy by SHA tag, not `latest` |

So the pipeline is fully green, but only two of the five security checks can actually stop a release, and the app it deployed has the Flask debugger switched on. "The pipeline has a security scan" and "the pipeline is secure" are different claims. A scan finds a problem; a gate is the `exit 1` that decides what happens next.

---

## File index

| Path | What it is |
| --- | --- |
| `02-container-registry/` | Pushing images to a registry (GHCR in the lesson; I used Docker Hub) |
| `03-kubernetes-deployment/` | Deployment + Service manifests and `rollout status` |
| `04-sast/` | SAST with GitHub CodeQL |
| `05-sca/` | SCA with pip-audit |
| `06-secret-scanning/` | Keeping credentials out of Git, GitHub secret scanning |
| `07-container-image-scanning/` | Trivy, including `--exit-code 1` |
| `08-security-gates/` | `needs:` chains and pass/fail gates |
| `demo/` | The Flask "DevSecOps Dashboard" app, tests, Dockerfile, `k8s/` and the `devsecops.yml` pipeline (instructor's version) |
| `screenshots/` | The pipeline run, cluster/registry evidence and the local scans |

## Resources

- My pipeline repo: <https://github.com/PratyushMishra-2nd/CI_CD-PIPE> (workflow: `.github/workflows/devsecops.yml`)
- Instructor demo: <https://github.com/Nency-Ravaliya/devops-heros/tree/main/session-17-devsecops/demo>
- <https://codeql.github.com/docs/>, <https://github.com/pypa/pip-audit>, <https://trivy.dev/>, <https://github.com/gitleaks/gitleaks>, <https://bandit.readthedocs.io/>
