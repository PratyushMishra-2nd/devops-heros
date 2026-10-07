# Session 21: Final DevOps Capstone — TaskBoard

**Pratyush Mishra · Roll No. 10486**

The class instruction for this session was to run the instructor's TaskBoard project (`session21-python/`) by following its README part by part and record the outputs. TaskBoard is a React + FastAPI + PostgreSQL app, and the README walks it through the whole course: pytest, Docker Compose, Trivy, GitHub Actions, Terraform for AWS VPC + EKS, Kubernetes with Helm, Ingress, HPA, Prometheus + Grafana and a troubleshooting lab. I did every part this machine allows. Several parts did not work as shipped, so a good chunk of this write-up is "it broke, here is why, here is the smallest fix". Everything below is copied straight from my terminal.

**Setup:** Ubuntu 26.04 on WSL2, Docker Engine with Compose v2, Minikube v1.39.0 with the Docker driver, Kubernetes v1.37.0, Helm v4.3.0, Terraform v1.16.4 against **moto** (local AWS emulator, I have no AWS account), Trivy 0.75.0, kube-prometheus-stack 92.1.0. Python tests ran in a `python:3.12-slim` container because WSL has Python 3.14 and the pinned packages target 3.12 (the pipeline also uses 3.12).

> Namespaces used: `taskboard` (the app, from `k8s/namespace.yaml`) and `monitoring` (Prometheus + Grafana).

### What I had to fix to get it running

| # | Where | Problem | Fix |
| --- | --- | --- | --- |
| 1 | `backend/tests/test_api.py` | `TestClient(app)` never fires the startup event, so the SQLite test DB had no `tasks` table and the POST test failed | create the schema explicitly in the test module (6 lines) |
| 2 | `docker-compose.yml` | backend ran `alembic upgrade head` before Postgres accepted connections and exited (1) | new override file `docker-compose.healthcheck.yml` (instructor file untouched) |
| 3 | `backend/requirements.txt` | Trivy gate failed: starlette 0.41.3 has 3 HIGH CVEs | bumped `fastapi` and `prometheus-fastapi-instrumentator` so starlette 1.7.0 gets pulled |
| 4 | `frontend/Dockerfile` | Trivy gate failed: `nginx:1.27-alpine` has 44 HIGH/CRITICAL CVEs | `RUN apk upgrade --no-cache` in the runtime stage |
| 5 | `terraform/*.tf` | every file was written on one line, which is not valid HCL; `init` and `fmt` both fail | re-wrote the same arguments as normal multi-line blocks |
| 6 | `helm/.../ingress.yaml` | `/api` pointed at a Service `taskboard-backend:8080` that does not exist | point at `<release>-taskboard-backend:8000` |
| 7 | Helm chart vs `frontend/nginx.conf` | nginx proxies to `http://backend:8000` (the compose name); no such Service in the chart, so the frontend crash-looped | new template `backend-alias-service.yaml` that adds a Service called `backend` |
| 8 | kube-prometheus-stack | Grafana 13 was killed by its liveness probe during first boot | longer liveness delay in my values file `monitoring/kps-minikube-pratyush.yaml` |

---

## 1. The application (Part A)

The backend is FastAPI with SQLAlchemy models, one Alembic migration (`alembic/versions/0001_create_tasks.py`) and these routes: `/`, `/health`, `/ready`, `/metrics`, and CRUD on `/api/tasks` plus `/api/tasks/stats`. The frontend is a Vite/React single page served by nginx, and nginx proxies `/api/` to the backend so the browser never needs the backend hostname.

`/health` only says the process is alive. `/ready` runs a real `SELECT count(*)` on the tasks table, so it fails while the database is unreachable. That is exactly the split Kubernetes wants for liveness vs readiness, and it mattered later when the backend Pods started before Postgres.

📸 `screenshots/06-swagger-docs.png` (the Swagger page FastAPI generates at `/docs`)

---

## 2. Backend tests with pytest (Part C)

`backend/tests/test_api.py` has 3 tests and `pytest.ini` puts the backend on the path. The test file points `DATABASE_URL` at a local SQLite file so the tests never touch Postgres. First run:

```bash
$ python3 --version; docker exec s21-dev python --version
Python 3.14.4
Python 3.12.15
$ docker exec s21-dev pytest -v
============================= test session starts ==============================
platform linux -- Python 3.12.15, pytest-8.3.4, pluggy-1.6.0 -- /usr/local/bin/python3.12
cachedir: .pytest_cache
rootdir: /app
configfile: pytest.ini
plugins: anyio-4.15.1
collecting ... collected 3 items

tests/test_api.py::test_health PASSED                                    [ 33%]
tests/test_api.py::test_root PASSED                                      [ 66%]
tests/test_api.py::test_create_task_validation FAILED                    [100%]
...
E       sqlalchemy.exc.OperationalError: (sqlite3.OperationalError) no such table: tasks
E       [SQL: INSERT INTO tasks (title, description, priority, status, assignee, created_at) VALUES (?, ?, ?, ?, ?, ?)]
E       [parameters: ('Deploy application', '', 'HIGH', 'TODO', 'Student', '2026-10-07 17:39:37.118957')]
...
=========================== short test summary info ============================
FAILED tests/test_api.py::test_create_task_validation - sqlalchemy.exc.Operat...
=================== 1 failed, 2 passed, 3 warnings in 1.28s ====================
```

(`s21-dev` is a `python:3.12-slim` container with `backend/` mounted at `/app` and `pip install -r requirements.txt` already run.)

`main.py` creates the tables in an `@app.on_event("startup")` hook. Starlette only runs startup/lifespan events when the `TestClient` is used as a context manager (`with TestClient(app) as client:`). The test file does `client = TestClient(app)` at module level, so the hook never runs, the SQLite file is created empty, and the only test that touches the DB fails. `/health` and `/` do not touch the DB, which is why they pass.

This would also have failed the instructor's CI on every push, because pytest is the first job. Fix in the test file:

```python
from app.db import Base, engine
Base.metadata.create_all(bind=engine)
```

```bash
$ docker exec s21-dev pytest -v
...
tests/test_api.py::test_health PASSED                                    [ 33%]
tests/test_api.py::test_root PASSED                                      [ 66%]
tests/test_api.py::test_create_task_validation PASSED                    [100%]
...
======================== 3 passed, 3 warnings in 0.77s =========================
```

The 3 warnings are FastAPI saying `on_event` is deprecated in favour of lifespan handlers. Later (section 6) I bumped FastAPI for a CVE and ran the tests again in a fresh container:

```bash
$ docker run --rm -e PYTHONDONTWRITEBYTECODE=1 -v $PWD/backend:/src:ro python:3.12-slim sh -c "cp -r /src /app && cd /app && pip install -q --root-user-action=ignore -r requirements.txt 2>/dev/null && pip list 2>/dev/null | grep -E \"^(fastapi|starlette) \" && pytest -v -p no:warnings"
fastapi                           0.142.2
starlette                         1.7.0
...
tests/test_api.py::test_health PASSED                                    [ 33%]
tests/test_api.py::test_root PASSED                                      [ 66%]
tests/test_api.py::test_create_task_validation PASSED                    [100%]

============================== 3 passed in 0.54s ===============================
```

Two honest notes on the tests: the rubric asks for 5 tests over 3 endpoints and this reference project has 3 tests, and `test_create_task_validation` does not test validation, it tests a successful create. I left the test content as the instructor wrote it and only fixed the bug.

📸 `screenshots/01-pytest-fail.png`, `screenshots/02-pytest-pass.png`

---

## 3. Running the backend directly (Part B, section 6)

The README runs Alembic and Uvicorn straight against a Postgres. I did it with a throwaway Postgres container and the same Python 3.12 container on one Docker network:

```bash
$ docker ps --filter name=s21- --format "{{.Names}}  {{.Image}}  {{.Ports}}"
s21-dev  python:3.12-slim  0.0.0.0:8000->8000/tcp, [::]:8000->8000/tcp
s21-pg  postgres:16-alpine  5432/tcp
$ export DATABASE_URL=postgresql+psycopg://taskboard:taskboard@s21-pg:5432/taskboard; docker exec -e DATABASE_URL s21-dev alembic upgrade head && docker exec -e DATABASE_URL s21-dev alembic current
INFO  [alembic.runtime.migration] Context impl PostgresqlImpl.
INFO  [alembic.runtime.migration] Will assume transactional DDL.
INFO  [alembic.runtime.migration] Running upgrade  -> 0001_create_tasks
INFO  [alembic.runtime.migration] Context impl PostgresqlImpl.
INFO  [alembic.runtime.migration] Will assume transactional DDL.
0001_create_tasks (head)
$ docker exec -d -e DATABASE_URL s21-dev sh -c "uvicorn app.main:app --reload --host 0.0.0.0 --port 8000 > /tmp/uv.log 2>&1"
$ docker exec s21-dev cat /tmp/uv.log
INFO:     Will watch for changes in these directories: ['/app']
INFO:     Uvicorn running on http://0.0.0.0:8000 (Press CTRL+C to quit)
INFO:     Started reloader process [33] using WatchFiles
INFO:     Started server process [35]
INFO:     Waiting for application startup.
INFO:     Application startup complete.
$ curl -s http://localhost:8000/health; echo; curl -s http://localhost:8000/ready; echo; curl -s http://localhost:8000/api/tasks; echo
{"status":"UP"}
{"status":"READY"}
[]
```

One difference from the README: it says `uvicorn ... --port 8000` without `--host`. That binds to 127.0.0.1, which is fine on a laptop but inside a container nothing outside can reach it. My first try used `--network host` and still got `Connection refused` from WSL, because this Docker daemon runs in its own VM, so "host" is its host, not my WSL shell. A bridge network plus `-p 8000:8000` and `--host 0.0.0.0` is what worked.

📸 `screenshots/03-backend-direct.png`

---

## 4. Docker Compose (Part B section 5, Part E)

`docker-compose.yml` builds the backend (`python:3.12-slim`, runs as uid 10001) and the frontend (multi-stage: `node:22-alpine` builds, `nginx:1.27-alpine` serves), plus `postgres:16-alpine` with a named volume. Host ports 3000, 8000 and 5432 were free on this machine, so no port override was needed.

```bash
$ docker compose up --build -d
...
 Container session21-python-postgres-1 Started
 Container session21-python-backend-1 Starting
 Container session21-python-backend-1 Started
 Container session21-python-frontend-1 Starting
 Container session21-python-frontend-1 Started
$ docker compose ps -a
NAME                          IMAGE                       COMMAND                  SERVICE    CREATED         STATUS                     PORTS
session21-python-backend-1    session21-python-backend    "sh -c 'alembic upgr…"   backend    9 seconds ago   Exited (1) 7 seconds ago
session21-python-frontend-1   session21-python-frontend   "/docker-entrypoint.…"   frontend   9 seconds ago   Up 8 seconds               0.0.0.0:3000->80/tcp, [::]:3000->80/tcp
session21-python-postgres-1   postgres:16-alpine          "docker-entrypoint.s…"   postgres   9 seconds ago   Up 9 seconds               0.0.0.0:5432->5432/tcp, [::]:5432->5432/tcp
$ docker compose logs backend | tail -20
...
backend-1  | sqlalchemy.exc.OperationalError: (psycopg.OperationalError) connection failed: connection to server at "172.24.0.2", port 5432 failed: Connection refused
backend-1  | 	Is the server running on that host and accepting TCP/IP connections?
```

Everything "started", but the backend exited 2 seconds later. `depends_on: [postgres]` only waits for the Postgres **container** to start, not for Postgres to accept connections, and the backend's first command is `alembic upgrade head`. On a fresh volume Postgres spends a few seconds running `initdb`, so the migration lost the race.

I did not edit the instructor's compose file. I added `docker-compose.healthcheck.yml` with a `pg_isready` healthcheck on postgres and `depends_on: {postgres: {condition: service_healthy}}` on the backend:

```bash
$ docker compose down -v
...
$ docker compose -f docker-compose.yml -f docker-compose.healthcheck.yml up --build -d
...
 Container session21-python-postgres-1 Started
 Container session21-python-postgres-1 Waiting
 Container session21-python-postgres-1 Healthy
 Container session21-python-backend-1 Starting
 Container session21-python-backend-1 Started
 Container session21-python-frontend-1 Starting
 Container session21-python-frontend-1 Started
$ docker compose -f docker-compose.yml -f docker-compose.healthcheck.yml ps
NAME                          IMAGE                       COMMAND                  SERVICE    CREATED          STATUS                    PORTS
session21-python-backend-1    session21-python-backend    "sh -c 'alembic upgr…"   backend    12 seconds ago   Up 8 seconds              0.0.0.0:8000->8000/tcp, [::]:8000->8000/tcp
session21-python-frontend-1   session21-python-frontend   "/docker-entrypoint.…"   frontend   12 seconds ago   Up 8 seconds              0.0.0.0:3000->80/tcp, [::]:3000->80/tcp
session21-python-postgres-1   postgres:16-alpine          "docker-entrypoint.s…"   postgres   12 seconds ago   Up 12 seconds (healthy)   0.0.0.0:5432->5432/tcp, [::]:5432->5432/tcp
$ docker compose logs backend | tail -8
backend-1  | INFO  [alembic.runtime.migration] Context impl PostgresqlImpl.
backend-1  | INFO  [alembic.runtime.migration] Will assume transactional DDL.
backend-1  | INFO  [alembic.runtime.migration] Running upgrade  -> 0001_create_tasks
backend-1  | INFO:     Started server process [8]
backend-1  | INFO:     Waiting for application startup.
backend-1  | INFO:     Application startup complete.
backend-1  | INFO:     Uvicorn running on http://0.0.0.0:8000 (Press CTRL+C to quit)
```

The `Waiting` → `Healthy` lines are the healthcheck doing its job. The frontend build log also showed `vite v8.3.3`: `package.json` pins every dependency to `latest`, so this build is not reproducible, it just happened to work today.

📸 `screenshots/04-compose-up.png`, `screenshots/05-compose-ui.png` (the dashboard at http://localhost:3000 after creating tasks through the API below)

---

## 5. API, database and container users

CRUD against the backend on :8000:

```bash
$ curl -s localhost:8000/; echo; curl -s localhost:8000/health; echo; curl -s localhost:8000/ready; echo
{"service":"TaskBoard API","version":"1.0.0","docs":"/docs"}
{"status":"UP"}
{"status":"READY"}
$ curl -s -X POST localhost:8000/api/tasks -H 'Content-Type: application/json' -d '{"title":"Write Terraform for VPC + EKS","priority":"HIGH","assignee":"Pratyush"}'; echo
{"title":"Write Terraform for VPC + EKS","description":"","priority":"HIGH","status":"TODO","assignee":"Pratyush","id":1,"created_at":"2026-10-07T17:43:14.269634Z"}
$ curl -s -X POST localhost:8000/api/tasks -H 'Content-Type: application/json' -d '{"title":"Add Trivy scan to pipeline","priority":"MEDIUM","assignee":"Pratyush","status":"IN_PROGRESS"}'; echo
{"title":"Add Trivy scan to pipeline","description":"","priority":"MEDIUM","status":"IN_PROGRESS","assignee":"Pratyush","id":2,"created_at":"2026-10-07T17:43:14.416445Z"}
$ curl -s -X POST localhost:8000/api/tasks -H 'Content-Type: application/json' -d '{"title":"Throwaway task","priority":"LOW"}'; echo
{"title":"Throwaway task","description":"","priority":"LOW","status":"TODO","assignee":"Unassigned","id":3,"created_at":"2026-10-07T17:43:14.468118Z"}
$ curl -s -X PUT localhost:8000/api/tasks/1 -H 'Content-Type: application/json' -d '{"status":"DONE"}'; echo
{"title":"Write Terraform for VPC + EKS","description":"","priority":"HIGH","status":"DONE","assignee":"Pratyush","id":1,"created_at":"2026-10-07T17:43:14.269634Z"}
$ curl -s -o /dev/null -w 'DELETE /api/tasks/3 -> HTTP %{http_code}\n' -X DELETE localhost:8000/api/tasks/3; curl -s -w '  (HTTP %{http_code})\n' localhost:8000/api/tasks/3
DELETE /api/tasks/3 -> HTTP 204
{"detail":"Task not found"}  (HTTP 404)
$ curl -s localhost:8000/api/tasks/stats; echo
{"total":2,"todo":0,"inProgress":1,"done":1}
$ curl -s -w '\nHTTP %{http_code}\n' -X POST localhost:8000/api/tasks -H 'Content-Type: application/json' -d '{"title":"bad","priority":"URGENT"}'
{"detail":[{"type":"literal_error","loc":["body","priority"],"msg":"Input should be 'LOW', 'MEDIUM' or 'HIGH'","input":"URGENT","ctx":{"expected":"'LOW', 'MEDIUM' or 'HIGH'"}}]}
HTTP 422
```

The `PUT` only sent `status` and every other field survived, because the route uses `model_dump(exclude_unset=True)`. The 422 is Pydantic rejecting a value outside the `Literal` type before the route code even runs.

Then the same API through the frontend's nginx on :3000, which is the path the browser uses, and the Prometheus endpoint:

```bash
$ curl -s -X POST localhost:3000/api/tasks -H 'Content-Type: application/json' -d '{"title":"Helm chart for minikube","priority":"HIGH","assignee":"Pratyush","status":"IN_PROGRESS"}'; echo
{"title":"Helm chart for minikube","description":"","priority":"HIGH","status":"IN_PROGRESS","assignee":"Pratyush","id":4,"created_at":"2026-10-07T17:43:26.119505Z"}
...
$ curl -s localhost:3000/api/tasks/stats; echo; curl -s localhost:3000/health; echo
{"total":5,"todo":2,"inProgress":2,"done":1}
{"status":"UP"}
$ curl -s localhost:8000/metrics | grep -E '^http_requests_total' | head -12
http_requests_total{handler="/",method="GET",status="2xx"} 1.0
http_requests_total{handler="/health",method="GET",status="2xx"} 2.0
http_requests_total{handler="/ready",method="GET",status="2xx"} 1.0
http_requests_total{handler="/api/tasks",method="POST",status="2xx"} 6.0
http_requests_total{handler="/api/tasks/{task_id}",method="PUT",status="2xx"} 1.0
http_requests_total{handler="/api/tasks/{task_id}",method="DELETE",status="2xx"} 1.0
http_requests_total{handler="/api/tasks/{task_id}",method="GET",status="4xx"} 1.0
http_requests_total{handler="/api/tasks/stats",method="GET",status="2xx"} 2.0
http_requests_total{handler="/api/tasks",method="POST",status="4xx"} 1.0
$ curl -s -o /dev/null -w '/docs -> HTTP %{http_code}\n' localhost:8000/docs; curl -s -o /dev/null -w '/openapi.json -> HTTP %{http_code}\n' localhost:8000/openapi.json
/docs -> HTTP 200
/openapi.json -> HTTP 200
```

The metrics line up exactly with what I just did: 6 successful POSTs, 1 rejected POST (the 422), 1 PUT, 1 DELETE, 1 GET that 404'd. The handler label is the route template (`/api/tasks/{task_id}`), not the real URL, which keeps the number of time series small.

The table in Postgres (Final demo step 3), and who the containers run as:

```bash
$ docker compose exec postgres psql -U taskboard -d taskboard -c 'select id, title, priority, status, assignee from tasks order by id;'
 id |             title             | priority |   status    | assignee
----+-------------------------------+----------+-------------+----------
  1 | Write Terraform for VPC + EKS | HIGH     | DONE        | Pratyush
  2 | Add Trivy scan to pipeline    | MEDIUM   | IN_PROGRESS | Pratyush
  4 | Helm chart for minikube       | HIGH     | IN_PROGRESS | Pratyush
  5 | Grafana panel for HTTP rate   | MEDIUM   | TODO        | Pratyush
  6 | Fix broken Service selector   | LOW      | TODO        | Ops
(5 rows)

$ docker compose exec postgres psql -U taskboard -d taskboard -c 'select * from alembic_version;'
    version_num
-------------------
 0001_create_tasks
(1 row)

$ docker compose exec backend id; docker compose exec frontend id
uid=10001(appuser) gid=10001(appuser) groups=10001(appuser)
uid=0(root) gid=0(root) groups=0(root),0(root),1(bin),2(daemon),3(sys),4(adm),6(disk),10(wheel),11(floppy),20(dialout),26(tape),27(video)
$ docker compose exec frontend ps -o user,pid,args
USER     PID   COMMAND
root         1 nginx: master process nginx -g daemon off;
nginx       29 nginx: worker process
nginx       30 nginx: worker process
...
$ docker images | grep -E 'IMAGE|session21-python'
IMAGE                                                                                                 ID             DISK USAGE   CONTENT SIZE   EXTRA
session21-python-backend:latest                                                                       c45f58dbce18        297MB         70.2MB   U
session21-python-frontend:latest                                                                      a90e0d1fba01       73.9MB         21.1MB   U
```

Id 3 is missing because I deleted it, and the sequence does not reuse ids. `alembic_version` is how Alembic knows the migration already ran, so restarting the backend does not re-create the table.

The backend is non-root (the Dockerfile does `useradd --uid 10001` and `USER 10001`). **The frontend is not**: the official `nginx` image starts the master process as root and only the workers drop to `nginx`. The rubric wants both images non-root, so this reference project does not meet that. The usual fix is `nginxinc/nginx-unprivileged`, but it listens on 8080, which would change the compose port, the Helm Service and probes and `nginx.conf`. That is a design change rather than a bug fix, so I left it and am noting it here. The multi-stage build itself works as described: the final frontend image is 73.9 MB because Node and `node_modules` stay in the build stage.

📸 `screenshots/07-api-crud.png`, `screenshots/08-db-and-users.png`

---

## 6. Trivy security scan (Part G)

I scanned both images with the same settings the instructor's pipeline uses (`HIGH,CRITICAL`, `--ignore-unfixed`, `--exit-code 1`), so a finding means the pipeline would stop before pushing:

```bash
$ docker tag session21-python-backend:latest taskboard-backend:local && docker tag session21-python-frontend:latest taskboard-frontend:local
$ docker run --rm -v /var/run/docker.sock:/var/run/docker.sock -v trivy-cache:/root/.cache/ aquasec/trivy:0.75.0 image --quiet --severity HIGH,CRITICAL --ignore-unfixed --exit-code 1 taskboard-backend:local; echo "trivy exit code: $?"
...
Python (python-pkg)
===================
Total: 3 (HIGH: 3, CRITICAL: 0)

┌──────────────────────┬────────────────┬──────────┬────────┬───────────────────┬───────────────┬──────────────────────────────────────────────────────────────┐
│       Library        │ Vulnerability  │ Severity │ Status │ Installed Version │ Fixed Version │                            Title                             │
├──────────────────────┼────────────────┼──────────┼────────┼───────────────────┼───────────────┼──────────────────────────────────────────────────────────────┤
│ starlette (METADATA) │ CVE-2025-62727 │ HIGH     │ fixed  │ 0.41.3            │ 0.49.1        │ starlette: Starlette DoS via Range header merging            │
│                      ├────────────────┤          │        │                   ├───────────────┼──────────────────────────────────────────────────────────────┤
│                      │ CVE-2026-48818 │          │        │                   │ 1.1.0         │ starlette: Starlette: SSRF and NTLM credential theft via UNC │
│                      ├────────────────┤          │        │                   ├───────────────┼──────────────────────────────────────────────────────────────┤
│                      │ CVE-2026-54283 │          │        │                   │ 1.3.1         │ starlette: Starlette: request.form() limits silently ignored │
└──────────────────────┴────────────────┴──────────┴────────┴───────────────────┴───────────────┴──────────────────────────────────────────────────────────────┘
trivy exit code: 1
$ docker run --rm -v /var/run/docker.sock:/var/run/docker.sock -v trivy-cache:/root/.cache/ aquasec/trivy:0.75.0 image --quiet --severity HIGH,CRITICAL --ignore-unfixed --exit-code 1 taskboard-frontend:local; echo "trivy exit code: $?"
...
taskboard-frontend:local (alpine 3.21.3)
========================================
Total: 44 (HIGH: 42, CRITICAL: 2)

│ c-ares       │ CVE-2026-33630 │ HIGH     │ fixed  │ 1.34.5-r0         │ 1.34.8-r0     │ c-ares: c-ares: Use-after-free / double-free in              │
│ libcrypto3   │ CVE-2026-31789 │ CRITICAL │        │ 3.3.3-r0          │ 3.3.7-r0      │ openssl: OpenSSL: Heap buffer overflow on 32-bit systems     │
│              │ CVE-2025-15467 │ HIGH     │        │                   │ 3.3.6-r0      │ openssl: OpenSSL: Remote code execution or Denial of Service │
...
│ zlib         │ CVE-2026-22184 │          │        │ 1.3.1-r2          │ 1.3.2-r0      │ zlib: zlib: Arbitrary code execution via buffer overflow in  │
trivy exit code: 1
```

Both images fail the gate, so as shipped the pipeline would never reach the push step.

- **Backend:** the only findings are in `starlette`, the web framework under FastAPI. One example: CVE-2025-62727 is a denial of service where a crafted `Range` header makes Starlette's file response do a lot of merging work. FastAPI 0.115.6 pins `starlette<0.42`, so the fix is upgrading FastAPI. `prometheus-fastapi-instrumentator` 7.0.2 then blocked starlette 1.x (pip said `ResolutionImpossible`), so it had to move to 8.1.0 as well. The Debian base itself had 0 fixable HIGH/CRITICAL findings.
- **Frontend:** all 44 are OS packages in the `nginx:1.27-alpine` base (openssl, libexpat, libpng, c-ares, zlib, ...), not my code. The `1.27-alpine` tag was built on Alpine 3.21.3 and nobody rebuilt it, but the Alpine 3.21 repo already has patched packages, so `RUN apk upgrade --no-cache` in the runtime stage pulls them.

```bash
$ git diff -U0 -- backend/requirements.txt frontend/Dockerfile | grep -E '^[-+][^-+]'
-fastapi==0.115.6
+fastapi==0.142.2
-prometheus-fastapi-instrumentator==7.0.2
+prometheus-fastapi-instrumentator==8.1.0
+# Fix (Pratyush): base image ships alpine 3.21.3 packages with 44 HIGH/CRITICAL CVEs that Trivy fails on; pull the patched ones.
+RUN apk upgrade --no-cache
$ docker compose -f docker-compose.yml -f docker-compose.healthcheck.yml up --build -d 2>&1 | tail -13
 Image session21-python-backend Built
 Image session21-python-frontend Built
...
$ docker run --rm ... aquasec/trivy:0.75.0 image --quiet --severity HIGH,CRITICAL --ignore-unfixed --exit-code 1 taskboard-backend:local | grep -E 'debian|python-pkg │ +[1-9]'; echo "trivy exit code: ${PIPESTATUS[0]}"
│ taskboard-backend:local (debian 13.7)                                            │   debian   │        0        │    -    │
trivy exit code: 0
$ docker run --rm ... aquasec/trivy:0.75.0 image --quiet --severity HIGH,CRITICAL --ignore-unfixed --exit-code 1 taskboard-frontend:local | grep -E 'alpine'; echo "trivy exit code: ${PIPESTATUS[0]}"
│ taskboard-frontend:local (alpine 3.21.3) │ alpine │        0        │    -    │
trivy exit code: 0
$ docker compose exec backend pip list 2>/dev/null | grep -E '^(fastapi|starlette) '; curl -s localhost:3000/api/tasks/stats; echo
fastapi                           0.142.2
starlette                         1.7.0
{"total":5,"todo":2,"inProgress":2,"done":1}
```

Both scans exit 0 now, the app still answers through nginx, and the tests still pass on the new FastAPI (section 2). `--ignore-unfixed` matters: without it a scan can fail on CVEs that have no patch yet, and the team cannot do anything about those except accept them. The frontend still says `alpine 3.21.3` because that is the base image's release file; the packages inside are the patched ones. As the README says, a clean Trivy run only means "no known, fixable HIGH/CRITICAL CVEs in the OS packages and Python packages it can see". It does not look at my own code (that is SAST) or at what happens at runtime.

📸 `screenshots/09-trivy-fail.png`, `screenshots/10-trivy-pass.png`

---

## 7. CI/CD with GitHub Actions (Part F)

The instructor's workflow is `session21-python/.github/workflows/ci-cd.yml`. GitHub only runs workflows from the repo-root `.github/workflows/`, so that file never triggers in this repo (same situation as session 16). I made a root copy, `.github/workflows/session21-taskboard.yml`, and kept the instructor's job structure:

```text
test               pytest -v, then npm install + npm run build of the frontend
  └─ build-scan-push   docker build both images → Trivy both (HIGH,CRITICAL, exit 1) → docker push to GHCR
       └─ deploy           helm upgrade --install (skipped, see below)
```

What I changed and why:

- `on: push` to `main` with `paths: ['session21-python/**', '.github/workflows/session21-taskboard.yml']`, plus `workflow_dispatch`, so other sessions' commits do not rebuild this.
- Every `working-directory` and Docker build context points into `session21-python/`.
- Image names are lowercased in a step (`${GITHUB_REPOSITORY_OWNER,,}`). My GitHub username is `PratyushMishra-2nd`, and GHCR rejects repository names with capitals, so the instructor's `ghcr.io/${{ github.repository_owner }}/...` would fail at `docker build -t`.
- Tags are `${GITHUB_SHA}`, never `latest`, and the job has `permissions: packages: write, contents: read`.
- The Trivy steps run the pinned `aquasec/trivy:0.75.0` image with the same flags as the instructor's `trivy-action` steps, so CI and my laptop run the identical scanner.
- `deploy` needs a `KUBE_CONFIG_DATA` secret for a cluster GitHub can reach. I have no EKS cluster, and my minikube lives on my laptop, so it is guarded with `if: vars.KUBE_DEPLOY_ENABLED == 'true'` and shows as skipped. (I first used `if: false`, and actionlint flagged it as a constant condition.)

```bash
$ ls .github/workflows/
session16-ci.yml
session21-taskboard.yml
$ docker run --rm -v $PWD:/repo -w /repo rhysd/actionlint:latest -no-color -oneline .github/workflows/session21-taskboard.yml; echo "actionlint exit code: $?"
actionlint exit code: 0
$ docker run --rm -v $PWD:/repo -w /repo rhysd/actionlint:latest -no-color -oneline session21-python/.github/workflows/ci-cd.yml; echo "actionlint exit code: $?"
actionlint exit code: 0
```

Both workflows are syntactically valid. The instructor's version would still have gone red on a real run, at pytest (section 2) and then at Trivy (section 6). Both of those are fixed in the shared source now, so the same commit fixes the copy too.

📸 `screenshots/11-actionlint.png`

<!-- TODO-ACTIONS-RUN -->

---

## 8. Terraform for AWS VPC + EKS (Part H) — run against moto

**I have no AWS account, so none of this created real AWS resources.** I ran `init`, `fmt`, `validate`, `plan`, `apply`, `state` and `destroy` against moto, a local AWS API emulator, the same way as sessions 18 and 19. `terraform/moto/moto_override.tf` points the AWS provider's endpoints at `http://localhost:5000` with fake credentials. Terraform merges any `*_override.tf` into the matching block, so `versions.tf` keeps the instructor's real provider config. I copied the override in only for the run and deleted it afterwards, along with `.terraform/`, the lock file, the plan and the state.

### 8.1 The files did not parse

```bash
$ terraform version | head -1; cat versions.tf
Terraform v1.16.4
terraform { required_version = ">= 1.7.0" required_providers { aws = { source = "hashicorp/aws" version = "~> 5.0" } } }
provider "aws" { region = var.aws_region }
$ terraform init -no-color
Initializing the backend...

Initializing modules...
Downloading registry.terraform.io/terraform-aws-modules/vpc/aws 6.7.3 for vpc...
...
$ terraform fmt -check; echo "fmt exit code: $?"
╷
│ Error: Invalid single-argument block definition
│
│   on main.tf line 1, in module "vpc":
│    1: module "vpc" { source = "terraform-aws-modules/vpc/aws" version = "5.8.1" name = "taskboard-vpc" cidr = "10.20.0...
│
│ A single-line block definition must end with a closing brace immediately
│ after its single argument definition.
╵
...
│   on versions.tf line 1, in terraform:
...
fmt exit code: 2
```

All four `.tf` files were squashed onto one line per block. HCL only allows a one-line block when it has a single argument (`variable "x" { default = 1 }` is fine; two arguments on one line are not). Look at what `init` did before failing: it downloaded VPC module **6.7.3**, not the pinned **5.8.1**, because it could not parse the `version =` argument and fell back to the latest version. A file that half-parses is worse than one that fails cleanly. `terraform fmt` cannot repair a parse error, so I rewrote the same arguments as normal multi-line blocks. Nothing semantic changed.

### 8.2 init, fmt, validate, plan

```bash
$ git diff --stat -- .
 session21-python/terraform/main.tf      | 32 ++++++++++++++++++++++++++++++--
 session21-python/terraform/outputs.tf   | 14 +++++++++++---
 session21-python/terraform/variables.tf | 14 +++++++++++---
 session21-python/terraform/versions.tf  | 15 +++++++++++++--
 4 files changed, 65 insertions(+), 10 deletions(-)
$ terraform fmt -check; echo "fmt exit code: $?"
fmt exit code: 0
$ cp moto/moto_override.tf . && terraform init -no-color | grep -E 'Downloading|vpc in|eks in|Installed|Reusing|Using previously|successfully'
- Reusing previous version of hashicorp/cloudinit from the dependency lock file
- Reusing previous version of hashicorp/aws from the dependency lock file
...
- Using previously-installed hashicorp/aws v5.100.0
...
Terraform has been successfully initialized!
$ terraform validate -no-color
Success! The configuration is valid.
$ terraform plan -no-color -out=taskboard.tfplan > /tmp/s21plan.txt 2>&1; echo "plan exit code: $?"; grep -E '^Plan:|Error' /tmp/s21plan.txt
plan exit code: 0
Plan: 54 to add, 0 to change, 0 to destroy.
$ terraform show -no-color taskboard.tfplan | grep -E '^  # ' | grep -E 'aws_vpc\.|aws_subnet|aws_nat_gateway|aws_internet_gateway|aws_eks_cluster|aws_eks_node_group|aws_kms_key|aws_iam_role\.|aws_launch_template' | sed 's/ will be created//'
  # module.eks.aws_eks_cluster.this[0]
  # module.eks.aws_iam_role.this[0]
  # module.vpc.aws_internet_gateway.this[0]
  # module.vpc.aws_nat_gateway.this[0]
  # module.vpc.aws_subnet.private[0]
  # module.vpc.aws_subnet.private[1]
  # module.vpc.aws_subnet.public[0]
  # module.vpc.aws_subnet.public[1]
  # module.vpc.aws_vpc.this[0]
  # module.eks.module.eks_managed_node_group["main"].aws_eks_node_group.this[0]
  # module.eks.module.eks_managed_node_group["main"].aws_iam_role.this[0]
  # module.eks.module.eks_managed_node_group["main"].aws_launch_template.this[0]
  # module.eks.module.kms.aws_kms_key.this[0]
$ terraform show -no-color taskboard.tfplan | grep -E '^  # ' | sed -E 's/^  # (module\.[a-z]+).*/\1/' | sort | uniq -c
      2   # (config refers to values not yet known)
     37 module.eks
     19 module.vpc
```

Two `module` blocks in `main.tf` turn into 54 resources: 19 for the network (VPC, 2 public + 2 private subnets, IGW, one NAT gateway with its EIP, route tables) and 37 for EKS (cluster, KMS key for secrets encryption, IAM roles, security groups, CloudWatch log group, managed node group with a launch template, OIDC provider). That is what the community modules buy you, and also why you should read the plan instead of trusting the module.

### 8.3 apply against moto: VPC yes, EKS no

```bash
$ timeout 900 terraform apply -no-color taskboard.tfplan > /tmp/s21apply.txt 2>&1; echo "apply exit code: $?"; grep -E 'Apply complete|Error:|Creation complete' /tmp/s21apply.txt | sed -E 's/ \[id=[^]]*\]//' | tail -70
apply exit code: 1
...
module.vpc.aws_vpc.this[0]: Creation complete after 11s
module.vpc.aws_subnet.public[0]: Creation complete after 0s
module.vpc.aws_subnet.public[1]: Creation complete after 0s
module.vpc.aws_subnet.private[0]: Creation complete after 0s
module.vpc.aws_subnet.private[1]: Creation complete after 0s
...
module.vpc.aws_nat_gateway.this[0]: Creation complete after 0s
...
module.eks.module.kms.aws_kms_key.this[0]: Creation complete after 12s
module.eks.module.kms.aws_kms_alias.this["cluster"]: Creation complete after 0s
module.eks.aws_iam_policy.cluster_encryption[0]: Creation complete after 0s
module.eks.aws_iam_role_policy_attachment.cluster_encryption[0]: Creation complete after 0s
Error: attaching IAM Policy (arn:aws:iam::aws:policy/AmazonEKSVPCResourceController) to IAM Role (taskboard-eks-cluster-20261007180731217100000003): operation error IAM: AttachRolePolicy, https response error StatusCode: 404, ..., NoSuchEntity: Policy arn:aws:iam::aws:policy/AmazonEKSVPCResourceController does not exist or is not attachable.
Error: attaching IAM Policy (arn:aws:iam::aws:policy/AmazonEKSClusterPolicy) to IAM Role (taskboard-eks-cluster-...): ... NoSuchEntity: Policy arn:aws:iam::aws:policy/AmazonEKSClusterPolicy does not exist or is not attachable.
Error: attaching IAM Policy (arn:aws:iam::aws:policy/AmazonEKSWorkerNodePolicy) to IAM Role (main-eks-node-group-...): ... NoSuchEntity ...
Error: attaching IAM Policy (arn:aws:iam::aws:policy/AmazonEKS_CNI_Policy) to IAM Role (main-eks-node-group-...): ... NoSuchEntity ...
Error: attaching IAM Policy (arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly) to IAM Role (main-eks-node-group-...): ... NoSuchEntity ...
$ aws --endpoint-url http://localhost:5000 iam get-policy --policy-arn arn:aws:iam::aws:policy/AmazonEKSClusterPolicy

aws: [ERROR]: An error occurred (NoSuchEntity) when calling the GetPolicy operation: Policy arn:aws:iam::aws:policy/AmazonEKSClusterPolicy not found
```

41 resources were created, and the whole VPC came up. EKS stopped at the IAM step. The EKS module attaches **AWS-managed** policies (`arn:aws:iam::aws:policy/...`) to the cluster and node roles. On real AWS those always exist. moto does not load its catalogue of AWS-managed policies unless the server was started with that option, and the shared moto container here was not. Restarting or resetting it would wipe other people's state, so I did not. The cluster and node group `depends_on` those attachments, so Terraform never tried to create them. This is a limit of the emulator, not of the code: `plan` showed the EKS resources were correctly defined.

So with moto I could prove the network part end to end, and the EKS part only up to the plan. I could not produce the AWS Console screenshot the rubric asks for.

### 8.4 What exists, then destroy

```bash
$ terraform state list | wc -l; terraform state list | grep -E 'aws_vpc|aws_subnet|aws_nat|aws_internet|aws_eks|aws_kms_key|aws_iam_role\.'
52
module.eks.aws_iam_role.this[0]
module.vpc.aws_internet_gateway.this[0]
module.vpc.aws_nat_gateway.this[0]
module.vpc.aws_subnet.private[0]
module.vpc.aws_subnet.private[1]
module.vpc.aws_subnet.public[0]
module.vpc.aws_subnet.public[1]
module.vpc.aws_vpc.this[0]
module.eks.module.eks_managed_node_group["main"].aws_iam_role.this[0]
module.eks.module.kms.aws_kms_key.this[0]
$ terraform state show -no-color 'module.vpc.aws_vpc.this[0]' | grep -E '^ +(id|cidr_block|arn) '
    arn                                  = "arn:aws:ec2:ap-south-1:123456789012:vpc/vpc-880e9b8b2e4f89525"
    cidr_block                           = "10.20.0.0/16"
    id                                   = "vpc-880e9b8b2e4f89525"
$ aws --endpoint-url http://localhost:5000 ec2 describe-subnets --filters Name=tag:Name,Values='taskboard-vpc-*' --query 'Subnets[].[Tags[?Key==`Name`]|[0].Value,CidrBlock,AvailabilityZone]' --output table
------------------------------------------------------------------------
|                            DescribeSubnets                           |
+------------------------------------+------------------+--------------+
|  taskboard-vpc-public-ap-south-1a  |  10.20.101.0/24  |  ap-south-1a |
|  taskboard-vpc-private-ap-south-1a |  10.20.1.0/24    |  ap-south-1a |
|  taskboard-vpc-public-ap-south-1b  |  10.20.102.0/24  |  ap-south-1b |
|  taskboard-vpc-private-ap-south-1b |  10.20.2.0/24    |  ap-south-1b |
+------------------------------------+------------------+--------------+
$ timeout 900 terraform destroy -no-color -auto-approve > /tmp/s21destroy.txt 2>&1; echo "destroy exit code: $?"; grep -c "Destruction complete" /tmp/s21destroy.txt; grep -E "Destroy complete|Error" /tmp/s21destroy.txt
destroy exit code: 0
41
Destroy complete! Resources: 41 destroyed.
$ terraform state list | wc -l
0
$ aws --endpoint-url http://localhost:5000 ec2 describe-vpcs --filters Name=cidr,Values=10.20.0.0/16 --query "length(Vpcs)"
0
```

`state list` shows 52 entries because data sources (account id, partition, IAM policy documents) are tracked too. Only the 41 real resources are destroyed. Two public subnets in two AZs is the minimum EKS needs for a load balancer. The private subnets are where the module would have put the worker nodes, with one NAT gateway for outbound traffic (`single_nat_gateway = true`, which is cheaper but is a single point of failure for egress). Destroy was clean and nothing was left behind in moto. On real AWS this is the step that stops the NAT gateway and EKS control plane from billing by the hour.

📸 `screenshots/12-tf-broken-hcl.png`, `screenshots/13-tf-init-plan.png`, `screenshots/14-tf-apply-moto.png`, `screenshots/15-tf-state-destroy.png`

---

## 9. Kubernetes + Helm on minikube (Parts I, J)

No EKS, so the chart went onto my minikube. The images never went through a registry: I loaded the locally built, Trivy-clean images straight into the minikube node and pointed the chart at them with `helm/values-minikube-pratyush.yaml` (image names, tag `local`, Ingress on for `taskboard.local`, HPA 2 to 6).

### 9.1 First install, exactly as the README says

```bash
$ kubectl apply -f k8s/namespace.yaml
namespace/taskboard created
$ minikube image load taskboard-backend:local && minikube image load taskboard-frontend:local && minikube image ls | grep taskboard
docker.io/library/taskboard-frontend:local
docker.io/library/taskboard-backend:local
$ helm upgrade --install taskboard ./helm/taskboard --namespace taskboard --create-namespace
Release "taskboard" does not exist. Installing it now.
Error: unable to build kubernetes objects from release manifest: resource mapping not found for name: "taskboard-taskboard-backend" namespace: "" from "": no matches for kind "ServiceMonitor" in version "monitoring.coreos.com/v1"
ensure CRDs are installed first
$ kubectl get crd | grep -c monitoring.coreos.com
0
```

`values.yaml` has `monitoring.serviceMonitor.enabled: true`. `ServiceMonitor` is a custom resource that only exists after the Prometheus Operator is installed, and the README installs that later (Part M). Helm checks every kind before it creates anything, so the whole release failed and nothing was created. Until monitoring is in, it has to be installed with the ServiceMonitor off.

### 9.2 Second install: frontend crash-loops

```bash
$ helm upgrade --install taskboard ./helm/taskboard -n taskboard -f helm/values-minikube-pratyush.yaml --set monitoring.serviceMonitor.enabled=false
Release "taskboard" does not exist. Installing it now.
NAME: taskboard
...
STATUS: deployed
REVISION: 1
$ kubectl get pods -n taskboard
NAME                                           READY   STATUS             RESTARTS      AGE
taskboard-frontend-bbb7b895f-bkknl             0/1     CrashLoopBackOff   2 (17s ago)   47s
taskboard-frontend-bbb7b895f-jn967             0/1     CrashLoopBackOff   2 (17s ago)   47s
taskboard-postgres-755b4497b-tjmcx             1/1     Running            0             47s
taskboard-taskboard-backend-7d8fb7697c-42cwp   1/1     Running            2 (40s ago)   47s
taskboard-taskboard-backend-7d8fb7697c-vqfdm   1/1     Running            2 (40s ago)   47s
$ kubectl logs -n taskboard deploy/taskboard-frontend --tail=3
Found 2 pods, using pod/taskboard-frontend-bbb7b895f-bkknl
/docker-entrypoint.sh: Configuration complete; ready for start up
2026/10/07 18:03:53 [emerg] 1#1: host not found in upstream "backend" in /etc/nginx/conf.d/default.conf:13
nginx: [emerg] host not found in upstream "backend" in /etc/nginx/conf.d/default.conf:13
$ kubectl get svc -n taskboard
NAME                          TYPE        CLUSTER-IP       EXTERNAL-IP   PORT(S)    AGE
taskboard-frontend            ClusterIP   10.103.148.211   <none>        80/TCP     54s
taskboard-postgres            ClusterIP   10.99.98.159     <none>        5432/TCP   54s
taskboard-taskboard-backend   ClusterIP   10.99.28.136     <none>        8000/TCP   54s
$ grep -n proxy_pass frontend/nginx.conf
13:    proxy_pass http://backend:8000;
21:    proxy_pass http://backend:8000/health;
$ kubectl get ingress taskboard -n taskboard -o jsonpath="{range .spec.rules[0].http.paths[*]}{.path} -> {.backend.service.name}:{.backend.service.port.number}{\"\n\"}{end}"
/api -> taskboard-backend:8080
/ -> taskboard-frontend:80
$ kubectl describe ingress taskboard -n taskboard | grep -A4 Rules
Rules:
  Host             Path  Backends
  ----             ----  --------
  taskboard.local
                   /api   taskboard-backend:8080 (<error: services "taskboard-backend" not found>)
```

Two separate bugs, both naming mismatches:

1. **Frontend:** `nginx.conf` is baked into the image and proxies to `http://backend:8000`. That works in Compose, where the service is literally called `backend`. In the chart the backend Service is `{{ .Release.Name }}-taskboard-backend`, i.e. `taskboard-taskboard-backend`. nginx resolves every `proxy_pass` hostname when it starts, gets NXDOMAIN, and exits, so the Pod restarts forever. I added a template `templates/backend-alias-service.yaml`: a second Service named `backend` that selects the same backend Pods. Now the same image works in both Compose and Kubernetes. I gave it a different label so the ServiceMonitor does not scrape the backend twice.
2. **Ingress:** `/api` was routed to `taskboard-backend` on port **8080**. There is no Service with that name and the backend listens on **8000**. Changed to `{{ include "taskboard.fullname" . }}-backend` port 8000.

The backend's 2 restarts are the Compose race again: the backend Pods came up before Postgres, Alembic failed, and Kubernetes restarted them until it worked. Here that heals by itself, which is the difference between a restart policy and Compose's "exited (1), done". The `/ready` probe kept them out of the Service until then.

### 9.3 After the fixes

```bash
$ helm upgrade --install taskboard ./helm/taskboard -n taskboard -f helm/values-minikube-pratyush.yaml --set monitoring.serviceMonitor.enabled=false --wait --timeout 5m
Release "taskboard" has been upgraded. Happy Helming!
NAME: taskboard
LAST DEPLOYED: Wed Oct  7 18:04:37 2026
NAMESPACE: taskboard
STATUS: deployed
REVISION: 2
DESCRIPTION: Upgrade complete
TEST SUITE: None
$ kubectl get pods -n taskboard -o wide
NAME                                           READY   STATUS    RESTARTS       AGE    IP             NODE       NOMINATED NODE   READINESS GATES
taskboard-frontend-bbb7b895f-bkknl             1/1     Running   4 (63s ago)    2m3s   10.244.0.145   minikube   <none>           <none>
taskboard-frontend-bbb7b895f-jn967             1/1     Running   4 (64s ago)    2m3s   10.244.0.147   minikube   <none>           <none>
taskboard-postgres-755b4497b-tjmcx             1/1     Running   0              2m3s   10.244.0.143   minikube   <none>           <none>
taskboard-taskboard-backend-7d8fb7697c-42cwp   1/1     Running   2 (116s ago)   2m3s   10.244.0.144   minikube   <none>           <none>
taskboard-taskboard-backend-7d8fb7697c-vqfdm   1/1     Running   2 (116s ago)   2m3s   10.244.0.146   minikube   <none>           <none>
$ kubectl get svc,ingress,hpa,pvc -n taskboard
NAME                                  TYPE        CLUSTER-IP       EXTERNAL-IP   PORT(S)    AGE
service/backend                       ClusterIP   10.97.154.207    <none>        8000/TCP   54s
service/taskboard-frontend            ClusterIP   10.103.148.211   <none>        80/TCP     2m4s
service/taskboard-postgres            ClusterIP   10.99.98.159     <none>        5432/TCP   2m4s
service/taskboard-taskboard-backend   ClusterIP   10.99.28.136     <none>        8000/TCP   2m4s

NAME                                  CLASS   HOSTS             ADDRESS        PORTS   AGE
ingress.networking.k8s.io/taskboard   nginx   taskboard.local   192.168.49.2   80      2m4s

NAME                                                    REFERENCE                                TARGETS       MINPODS   MAXPODS   REPLICAS   AGE
horizontalpodautoscaler.autoscaling/taskboard-backend   Deployment/taskboard-taskboard-backend   cpu: 2%/60%   2         6         2          2m4s

NAME                                            STATUS   VOLUME                                     CAPACITY   ACCESS MODES   STORAGECLASS   VOLUMEATTRIBUTESCLASS   AGE
persistentvolumeclaim/taskboard-postgres-data   Bound    pvc-2213fed7-f4a5-4c97-9f80-17eb019621ca   5Gi        RWO            standard       <unset>                 2m4s
$ helm list -n taskboard
NAME     	NAMESPACE	REVISION	UPDATED                                	STATUS  	CHART          	APP VERSION
taskboard	taskboard	2       	2026-10-07 18:04:37.881001148 +0000 UTC	deployed	taskboard-1.0.0	1.0.0
```

Everything is Running: 2 frontend and 2 backend replicas, all ClusterIP Services (nothing exposed except through the Ingress), Postgres on a 5 Gi PVC from minikube's `standard` storage class. The frontend Pods are the same ones as before (4 restarts). They were in back-off, and the next restart after the `backend` Service appeared simply succeeded. No rollout was needed, because the image and config did not change, only DNS did.

Two things I'd point out about the chart. The DB password sits in plain text in `values.yaml` and is rendered into a Secret, which is fine for a classroom and not for production. The README says the same thing about RDS vs in-cluster Postgres. And `frontend-deployment.yaml`/`frontend-service.yaml` hard-code their names while the backend uses the release name, which is how mismatch #2 crept in.

📸 `screenshots/16-helm-first-install.png`, `screenshots/17-helm-running.png`

---

## 10. Ingress (Part K)

minikube's ingress-nginx controller is not reachable from Windows directly, so I port-forwarded the controller Service to 8088 and sent `Host: taskboard.local`:

```bash
$ nohup kubectl port-forward --address 0.0.0.0 -n ingress-nginx svc/ingress-nginx-controller 8088:80 > /tmp/s21-pf-ing.log 2>&1 &
$ curl -s -H 'Host: taskboard.local' localhost:8088/api/tasks/stats; echo
{"total":0,"todo":0,"inProgress":0,"done":0}
$ for t in 'Run TaskBoard on minikube with Helm' 'Route /api through the Ingress' 'Watch the HPA scale the backend' 'Scrape /metrics with Prometheus'; do curl -s -o /dev/null -w "POST %{http_code}  $t\n" -H 'Host: taskboard.local' -H 'Content-Type: application/json' -X POST localhost:8088/api/tasks -d "{\"title\":\"$t\",\"priority\":\"HIGH\",\"assignee\":\"Pratyush\"}"; done
POST 201  Run TaskBoard on minikube with Helm
POST 201  Route /api through the Ingress
POST 201  Watch the HPA scale the backend
POST 201  Scrape /metrics with Prometheus
$ curl -s -o /dev/null -w 'PUT %{http_code}\n' -H 'Host: taskboard.local' -H 'Content-Type: application/json' -X PUT localhost:8088/api/tasks/1 -d '{"status":"DONE"}'; curl -s -o /dev/null -w 'PUT %{http_code}\n' -H 'Host: taskboard.local' -H 'Content-Type: application/json' -X PUT localhost:8088/api/tasks/2 -d '{"status":"IN_PROGRESS"}'
PUT 200
PUT 200
$ curl -s -H 'Host: taskboard.local' localhost:8088/api/tasks/stats; echo; curl -s -H 'Host: taskboard.local' localhost:8088/ | grep -o '<title>.*</title>'
{"total":4,"todo":2,"inProgress":1,"done":1}
<title>TaskBoard</title>
$ curl -s -o /dev/null -w 'no Host header -> HTTP %{http_code}\n' localhost:8088/api/tasks
no Host header -> HTTP 404
$ kubectl exec -n taskboard deploy/taskboard-postgres -- psql -U taskboard -d taskboard -c 'select id, title, status from tasks order by id;'
 id |                title                |   status
----+-------------------------------------+-------------
  1 | Run TaskBoard on minikube with Helm | DONE
  2 | Route /api through the Ingress      | IN_PROGRESS
  3 | Watch the HPA scale the backend     | TODO
  4 | Scrape /metrics with Prometheus     | TODO
(4 rows)
```

The total started at 0: this is the in-cluster Postgres on its own PVC, not the Compose one. `/api/...` goes straight to the backend Service and `/` to the frontend Service, one hostname for both. Without the `Host` header the controller has no rule to match and returns its default 404. As the README says, the Ingress object is only routing rules; the ingress-nginx controller Pod is the thing that actually reads them and proxies.

For the browser screenshot I used headless Chrome with `--host-resolver-rules="MAP taskboard.local 127.0.0.1"` and opened `http://taskboard.local:8088/`, so the browser really sends `Host: taskboard.local`, the same as an `/etc/hosts` entry would.

📸 `screenshots/18-ingress-curl.png`, `screenshots/19-ingress-ui.png`

---

## 11. Troubleshooting lab (Part N)

### 11.1 Broken image

```bash
$ kubectl apply -f troubleshooting/broken-image.yaml
deployment.apps/taskboard-broken-image created
$ kubectl get pods -n taskboard -l app=broken-image
NAME                                      READY   STATUS             RESTARTS   AGE
taskboard-broken-image-6669966b5b-wmv5v   0/1     ImagePullBackOff   0          25s
$ kubectl describe pod -n taskboard -l app=broken-image | grep -E '^ +Image:|Reason|Failed|Back-off' | head -8
    Image:          ghcr.io/example/taskboard-backend:does-not-exist
      Reason:       ImagePullBackOff
  Type     Reason     Age               From               Message
  Normal   BackOff    19s               kubelet            Back-off pulling image "ghcr.io/example/taskboard-backend:does-not-exist"
  Warning  Failed     19s               kubelet            Error: ImagePullBackOff
  Warning  Failed     7s (x2 over 20s)  kubelet            Failed to pull image "ghcr.io/example/taskboard-backend:does-not-exist": failed to pull and unpack image "ghcr.io/example/taskboard-backend:does-not-exist": failed to resolve reference "ghcr.io/example/taskboard-backend:does-not-exist": failed to authorize: failed to fetch anonymous token: unexpected status from GET request to https://ghcr.io/token?scope=repository%3Aexample%2Ftaskboard-backend%3Apull&service=ghcr.io: 403 Forbidden
  Warning  Failed     7s (x2 over 20s)  kubelet            Error: ErrImagePull
```

The interesting part is that GHCR says **403 Forbidden**, not "not found". For a repository that does not exist (or is private), GHCR refuses to hand out an anonymous pull token, so a typo in the org name looks exactly like missing credentials. Read the image string in `describe` before you go and create an `imagePullSecret`. The fix is to point the Deployment at an image that exists. This manifest also has no `DATABASE_URL`, and the backend image would just crash-loop on Alembic without one, so it needed both:

```bash
$ kubectl set image deployment/taskboard-broken-image -n taskboard backend=taskboard-backend:local
deployment.apps/taskboard-broken-image image updated
$ kubectl set env deployment/taskboard-broken-image -n taskboard DATABASE_URL=postgresql+psycopg://taskboard:taskboard@taskboard-postgres:5432/taskboard
deployment.apps/taskboard-broken-image env updated
$ kubectl rollout status deployment/taskboard-broken-image -n taskboard --timeout=120s
Waiting for deployment "taskboard-broken-image" rollout to finish: 1 old replicas are pending termination...
...
deployment "taskboard-broken-image" successfully rolled out
$ kubectl get pods -n taskboard -l app=broken-image; kubectl exec -n taskboard deploy/taskboard-broken-image -- python -c "import urllib.request;print(urllib.request.urlopen(\"http://localhost:8000/ready\").read().decode())"
NAME                                      READY   STATUS    RESTARTS   AGE
taskboard-broken-image-66c4789f88-drrcr   1/1     Running   0          7s
{"status":"READY"}
```

Each `kubectl set` creates a new ReplicaSet, which is why there were briefly two Pods. In a real team you'd fix the YAML in Git and re-apply, otherwise the next `kubectl apply` puts the bad tag back.

### 11.2 Broken Service

```bash
$ kubectl apply -f troubleshooting/broken-service.yaml
service/broken-service created
$ kubectl get svc broken-service -n taskboard
NAME             TYPE        CLUSTER-IP     EXTERNAL-IP   PORT(S)    AGE
broken-service   ClusterIP   10.111.65.31   <none>        8080/TCP   0s
$ kubectl get endpoints broken-service -n taskboard
Warning: v1 Endpoints is deprecated in v1.33+; use discovery.k8s.io/v1 EndpointSlice
NAME             ENDPOINTS   AGE
broken-service   <none>      0s
$ kubectl run svc-test -n taskboard --rm -i --restart=Never --image=busybox:1.36 -- wget -qO- -T 3 http://broken-service:8080/health; true
...
wget: can't connect to remote host (10.111.65.31): Connection refused
$ kubectl get svc broken-service -n taskboard -o jsonpath='{.spec.selector}{"\n"}'; kubectl get pods -n taskboard --show-labels | awk '{print $1, $3, $NF}' | column -t
{"app":"label-that-does-not-exist"}
NAME                                          STATUS   LABELS
taskboard-broken-image-66c4789f88-drrcr       Running  app=broken-image,pod-template-hash=66c4789f88
taskboard-frontend-bbb7b895f-bkknl            Running  app=taskboard-frontend,pod-template-hash=bbb7b895f
taskboard-frontend-bbb7b895f-jn967            Running  app=taskboard-frontend,pod-template-hash=bbb7b895f
taskboard-postgres-755b4497b-tjmcx            Running  app=taskboard-postgres,pod-template-hash=755b4497b
taskboard-taskboard-backend-7d8fb7697c-42cwp  Running  app=taskboard-backend,pod-template-hash=7d8fb7697c
taskboard-taskboard-backend-7d8fb7697c-vqfdm  Running  app=taskboard-backend,pod-template-hash=7d8fb7697c
```

The Service is there, DNS resolves it, it has a ClusterIP, and everything still fails, because no Pod carries `app=label-that-does-not-exist`. That gives `ENDPOINTS <none>`, so kube-proxy has nothing to forward to and the connection is refused immediately. There was a second, quieter bug: `targetPort: 8080`, while the backend listens on 8000. Fixing only the selector would have turned "connection refused" into "endpoints present but still connection refused". Both fixed:

```bash
$ kubectl apply -f troubleshooting/broken-service.yaml
service/broken-service created
$ kubectl patch svc broken-service -n taskboard --type merge -p '{"spec":{"selector":{"app":"taskboard-backend"},"ports":[{"port":8080,"targetPort":8000}]}}'
service/broken-service patched
$ kubectl get endpointslices -n taskboard -l kubernetes.io/service-name=broken-service
NAME                   ADDRESSTYPE   PORTS   ENDPOINTS                   AGE
broken-service-j92dl   IPv4          8000    10.244.0.146,10.244.0.144   0s
$ kubectl exec -n taskboard deploy/taskboard-frontend -- wget -qO- -T 3 http://broken-service:8080/health; echo
{"status":"UP"}
$ kubectl delete -f troubleshooting/broken-service.yaml
service "broken-service" deleted from taskboard namespace
```

(I had deleted the Service a bit too early during the first fix, and the busybox test lost its output, so I re-applied it and redid the fix shown here.) The two endpoint IPs are exactly the two backend Pods from section 9. Both broken resources are deleted again at the end.

📸 `screenshots/20-troubleshoot-image.png`, `screenshots/21-troubleshoot-service.png`

---

## 12. HPA (Part L)

The chart's HPA scales the backend between 2 and 6 Pods at 60% of the CPU **request** (100m), so the target is about 60m per Pod. First the instructor's `scripts/load-test.sh`:

```bash
$ kubectl get hpa -n taskboard
NAME                REFERENCE                                TARGETS       MINPODS   MAXPODS   REPLICAS   AGE
taskboard-backend   Deployment/taskboard-taskboard-backend   cpu: 2%/60%   2         6         2          9m58s
$ curl -s -o /dev/null -w 'default URL path /api/health -> HTTP %{http_code}\n' -H 'Host: taskboard.local' localhost:8088/api/health
default URL path /api/health -> HTTP 404
$ nohup kubectl port-forward -n taskboard svc/taskboard-taskboard-backend 8089:8000 > /tmp/s21-pf-be.log 2>&1 &
$ time URL=http://localhost:8089/health bash scripts/load-test.sh
Load test completed

real	0m3.325s
user	0m0.842s
sys	0m0.949s
$ kubectl top pods -n taskboard -l app=taskboard-backend; kubectl get hpa -n taskboard
NAME                                           CPU(cores)   MEMORY(bytes)
taskboard-taskboard-backend-7d8fb7697c-42cwp   2m           66Mi
taskboard-taskboard-backend-7d8fb7697c-vqfdm   2m           75Mi
NAME                REFERENCE                                TARGETS       MINPODS   MAXPODS   REPLICAS   AGE
taskboard-backend   Deployment/taskboard-taskboard-backend   cpu: 2%/60%   2         6         2          10m
```

Two problems with the script. Its default URL `http://taskboard.local/api/health` is a route that does not exist (the backend has `/health`, and `/api/...` goes to the backend unchanged), so every request is a 404. And 500 sequential requests finish in 3.3 seconds, too short for metrics-server's 15 s scrape window to even notice. The README predicts exactly this: "a normal health request may not create enough CPU pressure". So I ran a controlled load instead: 4 busybox Pods in a tight `wget` loop on `/api/tasks`, which does a real DB query per request:

```bash
$ for i in 1 2 3 4; do kubectl run load-$i -n taskboard --image=busybox:1.36 --restart=Never -- /bin/sh -c 'while true; do wget -q -O /dev/null http://taskboard-taskboard-backend:8000/api/tasks; done'; done
pod/load-1 created
pod/load-2 created
pod/load-3 created
pod/load-4 created
$ cat /tmp/s21-hpawatch.txt   # kubectl get hpa every 20s while the load ran
18:14:09 cpu: 2%/60% 2 6 2
18:14:29 cpu: 113%/60% 2 6 4
18:14:50 cpu: 113%/60% 2 6 4
18:15:10 cpu: 113%/60% 2 6 4
18:15:30 cpu: 440%/60% 2 6 6
18:15:50 cpu: 440%/60% 2 6 6
18:16:11 cpu: 440%/60% 2 6 6
18:16:31 cpu: 385%/60% 2 6 6
18:16:51 cpu: 385%/60% 2 6 6
18:17:11 cpu: 385%/60% 2 6 6
18:17:32 cpu: 373%/60% 2 6 6
18:17:52 cpu: 373%/60% 2 6 6
$ kubectl top pods -n taskboard -l app=taskboard-backend
NAME                                           CPU(cores)   MEMORY(bytes)
taskboard-taskboard-backend-7d8fb7697c-42cwp   365m         69Mi
taskboard-taskboard-backend-7d8fb7697c-592jd   372m         68Mi
taskboard-taskboard-backend-7d8fb7697c-dftl2   378m         71Mi
taskboard-taskboard-backend-7d8fb7697c-nwjfr   372m         71Mi
taskboard-taskboard-backend-7d8fb7697c-pbrgg   378m         67Mi
taskboard-taskboard-backend-7d8fb7697c-vqfdm   373m         76Mi
$ kubectl describe hpa taskboard-backend -n taskboard | grep -A8 Events
...
  Normal   SuccessfulRescale             3m39s              horizontal-pod-autoscaler  New size: 4; reason: cpu resource utilization (percentage of request) above target
  Normal   SuccessfulRescale             2m39s              horizontal-pod-autoscaler  New size: 6; reason: cpu resource utilization (percentage of request) above target
$ kubectl delete pod -n taskboard load-1 load-2 load-3 load-4 --wait=false
pod "load-1" deleted from taskboard namespace
...
```

2 → 4 → 6 in about 80 seconds. The first step is the HPA formula exactly: desired = ceil(2 × 113 / 60) = 4. Once those Pods were busy too, usage jumped to 440% and the formula asked for far more than 6, so it stopped at `maxReplicas: 6`. At 6 Pods it was still at ~380% of the request. That is because the request is only 100m and each Pod could burst to its 500m limit, so "373%" means "pinned near the limit". The HPA wanted more Pods and was not allowed any. Those events also show the classic startup warning, `no metrics returned from resource metrics API`, which is just metrics-server not having data for brand-new Pods yet. I deleted the load Pods right away so I wasn't eating CPU on a shared machine. The HPA then waits out its 5-minute scale-down stabilisation and goes back to 2 (it was at 2 again when I checked in section 13).

📸 `screenshots/22-hpa-scale.png`

---

## 13. Prometheus + Grafana (Part M)

The README's `monitoring/prometheus-values.yaml` is meant for kube-prometheus-stack, and its two settings matter: `serviceMonitorSelectorNilUsesHelmValues: false` and an empty `serviceMonitorNamespaceSelector`. Together they let Prometheus pick up ServiceMonitors from any namespace, not only ones labelled for this Helm release. The cluster is shared with other labs in about 7 GB, so I added `monitoring/kps-minikube-pratyush.yaml` on top: Alertmanager off, 6h retention, memory limits, and anonymous Viewer access in Grafana for the screenshots.

```bash
$ cat monitoring/prometheus-values.yaml
grafana:
  enabled: true
prometheus:
  prometheusSpec:
    serviceMonitorSelectorNilUsesHelmValues: false
    serviceMonitorNamespaceSelector: {}
$ helm upgrade --install kube-prometheus-stack prometheus-community/kube-prometheus-stack --version 92.1.0 -n monitoring --create-namespace -f monitoring/prometheus-values.yaml -f monitoring/kps-minikube-pratyush.yaml --wait --timeout 10m | head -8
Error: resource Deployment/monitoring/kube-prometheus-stack-grafana not ready. status: Failed, message: Progress deadline exceeded
Release "kube-prometheus-stack" does not exist. Installing it now.
$ kubectl get pods -n monitoring
NAME                                                        READY   STATUS    RESTARTS      AGE
kube-prometheus-stack-grafana-579c9bccc5-dl4ld              2/3     Running   2 (72s ago)   10m
kube-prometheus-stack-kube-state-metrics-78dc75b868-7t94x   1/1     Running   0             10m
kube-prometheus-stack-operator-5b45f5c978-xqbgw             1/1     Running   0             10m
kube-prometheus-stack-prometheus-node-exporter-vs8n2        1/1     Running   0             10m
prometheus-kube-prometheus-stack-prometheus-0               2/2     Running   0             9m36s
$ kubectl get crd | grep monitoring.coreos.com | wc -l
10
```

Everything came up except Grafana, and the events said why:

```text
Warning   Unhealthy   pod/kube-prometheus-stack-grafana-579c9bccc5-dl4ld   Liveness probe failed: Get "http://10.244.0.163:3000/api/health": dial tcp 10.244.0.163:3000: connect: connection refused
Normal    Killing     pod/kube-prometheus-stack-grafana-579c9bccc5-dl4ld   Container grafana failed liveness probe, will be restarted
```

Grafana 13's first boot (database migrations plus loading the chart's default dashboards) took longer than the chart's 60 s liveness delay, so the kubelet killed it mid-startup. It only got to Ready after two restarts, and by then `helm --wait` had already given up. `kubectl top` showed that one Grafana Pod using over 8 CPU cores (`8328m`) while it struggled. Liveness probes that are shorter than startup time cause exactly this restart loop. I gave Grafana a 300 s initial delay and more memory in my values file and upgraded:

```bash
$ helm upgrade kube-prometheus-stack prometheus-community/kube-prometheus-stack --version 92.1.0 -n monitoring -f monitoring/prometheus-values.yaml -f monitoring/kps-minikube-pratyush.yaml --wait --timeout 12m | head -7
Release "kube-prometheus-stack" has been upgraded. Happy Helming!
NAME: kube-prometheus-stack
LAST DEPLOYED: Wed Oct  7 18:29:56 2026
NAMESPACE: monitoring
STATUS: deployed
REVISION: 2
DESCRIPTION: Upgrade complete
$ kubectl get pods -n monitoring
NAME                                                        READY   STATUS    RESTARTS   AGE
kube-prometheus-stack-grafana-fc99d48d-d8lrc                3/3     Running   0          15m
kube-prometheus-stack-kube-state-metrics-78dc75b868-7t94x   1/1     Running   0          26m
kube-prometheus-stack-operator-5b45f5c978-xqbgw             1/1     Running   0          26m
kube-prometheus-stack-prometheus-node-exporter-vs8n2        1/1     Running   0          26m
prometheus-kube-prometheus-stack-prometheus-0               2/2     Running   0          25m
```

The CRDs exist now, so the ServiceMonitor can go back on. The plain upgrade without `--set` picks up the chart default `enabled: true`:

```bash
$ helm upgrade --install taskboard ./helm/taskboard -n taskboard -f helm/values-minikube-pratyush.yaml --wait | head -6
Release "taskboard" has been upgraded. Happy Helming!
NAME: taskboard
LAST DEPLOYED: Wed Oct  7 18:41:23 2026
NAMESPACE: taskboard
STATUS: deployed
REVISION: 3
$ kubectl get servicemonitor -n taskboard --show-labels
NAME                          AGE   LABELS
taskboard-taskboard-backend   1s    app.kubernetes.io/managed-by=Helm,release=kube-prometheus-stack
$ helm list -n taskboard
NAME     	NAMESPACE	REVISION	UPDATED                                	STATUS  	CHART          	APP VERSION
taskboard	taskboard	3       	2026-10-07 18:41:23.202545466 +0000 UTC	deployed	taskboard-1.0.0	1.0.0
```

Prometheus picked both backend Pods up within about 20 seconds (port-forwarded to 9091):

```bash
$ curl -s localhost:9091/api/v1/targets | python3 -c 'import json,sys; [print(t["labels"]["job"], t["scrapeUrl"], t["health"]) for t in json.load(sys.stdin)["data"]["activeTargets"] if "taskboard" in t["labels"].get("namespace","")]'
taskboard-taskboard-backend http://10.244.0.144:8000/metrics up
taskboard-taskboard-backend http://10.244.0.146:8000/metrics up
$ curl -s localhost:8089/metrics | grep -E '^http_requests_total' | head -8
http_requests_total{handler="/ready",method="GET",status="2xx"} 233.0
http_requests_total{handler="/health",method="GET",status="2xx"} 654.0
http_requests_total{handler="/api/tasks",method="POST",status="2xx"} 2.0
http_requests_total{handler="/api/tasks/stats",method="GET",status="2xx"} 1.0
http_requests_total{handler="/api/tasks",method="GET",status="2xx"} 47189.0
http_requests_total{handler="none",method="GET",status="4xx"} 1.0
http_requests_total{handler="/metrics",method="GET",status="2xx"} 3.0
```

The ServiceMonitor selects Services labelled `app: taskboard-backend` and scrapes their port named `http`. The operator turns that into scrape config and Prometheus then scrapes **each Pod** behind the Service, which is why there are two targets and not one. The 47,189 `GET /api/tasks` on that one Pod are left over from the HPA load test. `/ready` and `/health` keep ticking because the kubelet probes hit them every 10-15 s.

For Grafana, kube-prometheus-stack already provisions a Prometheus data source. I built a small dashboard through Grafana's HTTP API and saved it as `monitoring/grafana-dashboard-taskboard.json`. It has 7 panels: targets UP, total req/s, 4xx share, backend replicas (from kube-state-metrics), requests/s by handler, p95 latency by handler, and backend CPU per Pod. Then I generated steady traffic with the instructor's script in a loop against `/api/tasks`, `/api/tasks/stats` and `/api/tasks/999` (that last one gives a steady stream of 404s for the error panel). That loop alone, a few hundred requests every few seconds, was enough to push the HPA to 4 replicas a little later (`cpu: 46%/60%   2     6     4`), and it scaled back to 2 once the loop finished.

```bash
$ kubectl get secret -n monitoring kube-prometheus-stack-grafana -o jsonpath={.data.admin-password} | base64 -d; echo
taskboard-lab
$ curl -s -u admin:taskboard-lab localhost:3005/api/datasources | python3 -c "import json,sys; [print(d[\"name\"], d[\"type\"], d[\"url\"]) for d in json.load(sys.stdin)]"
Alertmanager alertmanager http://kube-prometheus-stack-alertmanager.monitoring:9093/
Prometheus prometheus http://kube-prometheus-stack-prometheus.monitoring:9090/
$ curl -s -u admin:taskboard-lab -H "Content-Type: application/json" -X POST localhost:3005/api/dashboards/db -d @monitoring/grafana-dashboard-taskboard.json; echo
{"folderUid":"","id":219997477085184,"slug":"taskboard-api-session-21","status":"success","uid":"taskboard-api","url":"/d/taskboard-api/taskboard-api-session-21","version":1}
```

(The Alertmanager data source is provisioned by the chart even though I turned Alertmanager off. It just points at nothing.)

📸 `screenshots/23-monitoring-install.png`, `screenshots/24-prometheus-cli.png`, `screenshots/25-prometheus-targets.png` (Status → Target health, both backend endpoints UP), `screenshots/26-grafana-dashboard.png` (request rate per handler, p95 latency, backend CPU per Pod; taken after the fix in 13.1)

### 13.1 Grafana took the whole machine down

About 40 minutes later the WSL VM stopped answering (`Wsl/Service/0x8007274c`, connection timed out), and so did my headless Chrome screenshots. Once it responded again:

```bash
$ kubectl top pods -n monitoring; uptime
NAME                                                        CPU(cores)   MEMORY(bytes)
kube-prometheus-stack-grafana-fc99d48d-d8lrc                23053m       764Mi
kube-prometheus-stack-kube-state-metrics-78dc75b868-7t94x   4m           33Mi
kube-prometheus-stack-operator-5b45f5c978-xqbgw             4m           41Mi
kube-prometheus-stack-prometheus-node-exporter-vs8n2        3m           17Mi
prometheus-kube-prometheus-stack-prometheus-0               46m          573Mi
 19:22:39 up  3:10,  2 users,  load average: 51.42, 39.50, 20.38
```

Grafana was using **23 cores**. My values file had set a memory limit for Grafana but no CPU limit, so nothing stopped it from taking every core on the node, and that starved minikube, the other labs and WSL itself. (The Grafana Pod had also restarted once by then.) This is the "noisy neighbour" problem that CPU limits exist for. I added `limits: {cpu: "1", memory: 1Gi}` and turned off the chart's bundled Kubernetes dashboards (`defaultDashboardsEnabled: false`), which this lab doesn't need:

```bash
$ helm upgrade kube-prometheus-stack prometheus-community/kube-prometheus-stack --version 92.1.0 -n monitoring -f monitoring/prometheus-values.yaml -f monitoring/kps-minikube-pratyush.yaml | head -7
Release "kube-prometheus-stack" has been upgraded. Happy Helming!
NAME: kube-prometheus-stack
LAST DEPLOYED: Wed Oct  7 19:23:15 2026
NAMESPACE: monitoring
STATUS: deployed
REVISION: 3
DESCRIPTION: Upgrade complete
```

```bash
$ kubectl get pods -n monitoring -l app.kubernetes.io/name=grafana; kubectl top pods -n monitoring | grep grafana; uptime
NAME                                             READY   STATUS    RESTARTS   AGE
kube-prometheus-stack-grafana-6cd999fdb7-xb4xc   3/3     Running   0          51s
kube-prometheus-stack-grafana-6cd999fdb7-xb4xc              873m         443Mi
 19:24:16 up  3:12,  2 users,  load average: 13.44, 29.66, 18.72
```

Capped at 1 core it was Ready in 51 s and stayed under the limit, and the load average started falling. Grafana keeps its database on an `emptyDir` here (no persistence in the chart defaults), so the new Pod had lost my dashboard. That is why it lives in Git as `monitoring/grafana-dashboard-taskboard.json`, and I re-imported it with the same `curl` as above.

```bash
$ kubectl get pods -n monitoring -l app.kubernetes.io/name=grafana; kubectl top pods -n monitoring -l app.kubernetes.io/name=grafana
NAME                                             READY   STATUS    RESTARTS   AGE
kube-prometheus-stack-grafana-6cd999fdb7-xb4xc   3/3     Running   0          2m48s
NAME                                             CPU(cores)   MEMORY(bytes)
kube-prometheus-stack-grafana-6cd999fdb7-xb4xc   40m          585Mi
$ kubectl get deploy kube-prometheus-stack-grafana -n monitoring -o jsonpath='{.spec.template.spec.containers[?(@.name=="grafana")].resources}{"\n"}'
{"limits":{"cpu":"1","memory":"1Gi"},"requests":{"cpu":"100m","memory":"256Mi"}}
$ curl -s -u admin:taskboard-lab -H 'Content-Type: application/json' -X POST localhost:3005/api/dashboards/db -d @monitoring/grafana-dashboard-taskboard.json; echo
{"folderUid":"","id":230801262800896,"slug":"taskboard-api-session-21","status":"success","uid":"taskboard-api","url":"/d/taskboard-api/taskboard-api-session-21","version":1}
```

Three minutes later it had settled at 40m CPU. Then I ran the traffic loop again (instructor script against `/api/tasks` and `/api/tasks/999`, with an 8 s pause between rounds) and took the dashboard screenshot after it finished.

📸 `screenshots/27-grafana-cpu-cap.png`

How to read the dashboard (`26-grafana-dashboard.png`, last 15 minutes): the request-rate panel shows about 25-33 req/s of `GET /api/tasks` (2xx) alternating with `GET /api/tasks/{task_id}` (4xx, the `/999` lookups) while the loop ran, then a drop to 0 when it ended around 01:13 (the browser shows IST, i.e. 19:43 UTC). After that only the probe traffic (`/ready`, `/health`) and Prometheus' own `/metrics` scrapes are left, about 0.44 req/s. The stat panels show *current* values, which is why "4xx share" reads 0% even though the graph below it is full of 404s. The CPU panel has a lesson in it: only **one** backend Pod (`...-42cwp`) did any work. `kubectl port-forward svc/...` does not load-balance; it picks one Pod behind the Service when it starts and sends everything there. The in-cluster load test in section 12 went through the real Service, which is why all 6 Pods were busy there.

---

## 14. Git, GitHub and the final demo (Parts D, O)

This repo is my fork of the course repo (`PratyushMishra-2nd/devops-heros`), so the README's `git init` / `git remote add` steps were already done. Every session, this one included, goes in as a commit with a message saying what changed. The `.gitignore` in this folder excludes `.env`, `node_modules/`, `.terraform/` and `*.tfstate*`, but not `__pycache__/` or `.venv/`, and the upstream repo has committed `.pyc` files under `backend/app/__pycache__/`. I left those as they are.

The final-demo checklist maps onto the sections above: app and API (1, 4, 5), database (5, 10), CI (7), Docker images (4, 5), security (6), Terraform (8), Kubernetes and Helm (9), Ingress (10), HPA (12), monitoring (13), failure simulation (11).

---

## 15. Rubric checklist (GRADING.md)

| Module | What the rubric wants | Where it is covered | Status |
| --- | --- | --- | --- |
| M1 Application | `/health`, CRUD, Alembic table, UI that calls the API | §1, §3, §5; 📸 03, 05, 06, 07, 08 | Done. "Recent activity" panel in the UI is static text |
| M2 Testing | pytest passes, ≥5 tests over 3 endpoints, test DB, pytest.ini | §2; 📸 01, 02 | Passes after the fix, uses SQLite + pytest.ini. **Only 3 tests**, reference project as shipped |
| M3 Git/GitHub | public repo, good messages, .gitignore | §14 | Fork is public. `.gitignore` misses `__pycache__`/`.venv` |
| M4 Docker | both Dockerfiles build, multi-stage frontend, non-root, compose up | §4, §5; 📸 04, 05, 08 | Done after healthcheck override. **Frontend nginx master runs as root** |
| M5 CI/CD | workflow on push to main, pytest, frontend build, both images, GHCR, SHA tags | §7; 📸 11 | Workflow written + actionlint clean. Green-run evidence: see the Actions section in §7 |
| M6 Trivy | scan both images in CI, fail on HIGH/CRITICAL, explain a CVE | §6, §7; 📸 09, 10 | Done locally (fail → fix → pass). Same gate in the workflow |
| M7 Terraform | init, plan, VPC with 2 public subnets, EKS + node group, destroy, tfvars.example | §8; 📸 12-15 | **No AWS account: ran against moto.** init/validate/plan OK (54 resources), VPC + 2 public subnets applied, **EKS failed in moto** (no AWS-managed IAM policies), destroy clean. No AWS Console screenshot. No `terraform.tfvars.example` in the reference |
| M8 Kubernetes + Helm | namespace, chart, helm install, 2+ replicas, ClusterIP, Ingress `/` + `/api`, all Running | §9, §10; 📸 16-19 | Done on **minikube instead of EKS**, after 2 chart fixes |
| M9 Observability | `/metrics`, Prometheus scraping, Grafana, live panel | §5, §13; 📸 23-27 | Done |
| M10 Presentation/docs | README, live demo | this file | Write-up done. A live pipeline-to-cluster demo is not possible because the deploy job has no reachable cluster |

---

## 16. Cleanup

```bash
$ docker compose -f docker-compose.yml -f docker-compose.healthcheck.yml down -v
...
 Volume session21-python_postgres-data Removed
 Network session21-python_default Removed
```

```bash
$ kubectl get pods,hpa -n taskboard
NAME                                               READY   STATUS    RESTARTS       AGE
pod/taskboard-frontend-bbb7b895f-bkknl             1/1     Running   4 (107m ago)   108m
pod/taskboard-frontend-bbb7b895f-jn967             1/1     Running   4 (107m ago)   108m
pod/taskboard-postgres-755b4497b-tjmcx             1/1     Running   0              108m
pod/taskboard-taskboard-backend-7d8fb7697c-42cwp   1/1     Running   2 (107m ago)   108m
pod/taskboard-taskboard-backend-7d8fb7697c-vqfdm   1/1     Running   2 (107m ago)   108m

NAME                                                    REFERENCE                                TARGETS       MINPODS   MAXPODS   REPLICAS   AGE
horizontalpodautoscaler.autoscaling/taskboard-backend   Deployment/taskboard-taskboard-backend   cpu: 2%/60%   2         6         2          108m
$ helm list -n taskboard; helm list -n monitoring
NAME     	NAMESPACE	REVISION	UPDATED                                	STATUS  	CHART          	APP VERSION
taskboard	taskboard	3       	2026-10-07 18:41:23.202545466 +0000 UTC	deployed	taskboard-1.0.0	1.0.0
NAME                 	NAMESPACE 	REVISION	UPDATED                                	STATUS  	CHART                       	APP VERSION
kube-prometheus-stack	monitoring	3       	2026-10-07 19:23:15.642097454 +0000 UTC	deployed	kube-prometheus-stack-92.1.0	v0.94.1
$ docker ps -a --filter name=s21 --filter name=session21 --format '{{.Names}}' | wc -l; kubectl get pods -n taskboard -l 'run in (load-1,load-2,load-3,load-4)' 2>&1 | tail -1
0
No resources found in taskboard namespace.
$ ls -a terraform/
.
..
.gitignore
README.md
main.tf
moto
outputs.tf
variables.tf
versions.tf
```

The Compose stack is down with its volume, no containers of mine are left, the load-generator Pods and the broken lab resources are deleted, the HPA is back at 2 replicas, my port-forwards are stopped, and Terraform's `.terraform/`, lock file, plan, state and the copied override are gone from `terraform/`. The `taskboard` Helm release (revision 3) and the `monitoring` stack are left running on minikube.

📸 `screenshots/28-final-state.png`

---

## File index

| Path | What it is |
| --- | --- |
| `backend/` | FastAPI app, Alembic migration, pytest tests (instructor). `tests/test_api.py` and `requirements.txt` changed by me, see table at the top |
| `frontend/` | React/Vite UI + nginx config (instructor). `Dockerfile` got `apk upgrade` |
| `docker-compose.yml` | Instructor's 3-service stack (unchanged) |
| `docker-compose.healthcheck.yml` | **Mine.** Postgres healthcheck + `service_healthy` dependency for the backend |
| `.github/workflows/ci-cd.yml` | Instructor's pipeline (unchanged, never triggers from a subfolder) |
| `../.github/workflows/session21-taskboard.yml` | **Mine.** Root copy that actually runs: pytest → build → Trivy → GHCR, deploy guarded |
| `terraform/` | VPC + EKS via community modules. The 4 `.tf` files were reformatted so they parse |
| `terraform/moto/moto_override.tf` | **Mine.** Provider override for running against moto at localhost:5000 |
| `k8s/namespace.yaml` | `taskboard` namespace |
| `helm/taskboard/` | Instructor's chart. `templates/ingress.yaml` fixed, `templates/backend-alias-service.yaml` added by me |
| `helm/values-minikube-pratyush.yaml` | **Mine.** Local images, Ingress on, HPA 2 to 6 |
| `monitoring/prometheus-values.yaml` | Instructor's kube-prometheus-stack values |
| `monitoring/kps-minikube-pratyush.yaml` | **Mine.** Trims for minikube, Grafana anonymous viewer + longer liveness delay |
| `monitoring/grafana-dashboard-taskboard.json` | **Mine.** The 7-panel TaskBoard dashboard, importable via the Grafana API |
| `troubleshooting/` | `broken-image.yaml`, `broken-service.yaml` |
| `scripts/load-test.sh` | 500 sequential curls (default URL is a 404 path, see §12) |
| `GRADING.md` | Capstone rubric |
| `screenshots/` | 28 screenshots referenced above |

## Resources

- Original instructor README: https://github.com/Nency-Ravaliya/devops-heros/blob/main/session21-python/README.md
