# CI/CD & GitOps Cheat Sheet

> **Author:** Mengty LIM

GitLab CI, Jenkins, ArgoCD, promotion by digest, deployment strategies, rollback.

Companions: [docs/05-cicd-automation.md](../../docs/05-cicd-automation.md),
[docs/10-deployment-strategies.md](../../docs/10-deployment-strategies.md),
[docs/14-promotion-procedure.md](../../docs/14-promotion-procedure.md).

---

## 1. The shape

```
commit ─► CI (build, test, scan, sign) ─► registry (immutable digest)
                                              │
                                              ▼
              env repo (Git)  ◄── bump-digest commit (the promotion)
                    │
                    ▼
              ArgoCD (in cluster, PULLS) ─► Kubernetes
                    │
              Jenkins/Ansible (VM track) ─► VM fleet, blue/green
```

**CI builds. CD pulls.** The pipeline never holds production credentials; the
cluster reaches out to Git. That single inversion buys you separation of duties,
a smaller credential blast radius, and drift correction for free.

---

## 2. Build once, promote the digest

The artifact tested in dev is the artifact that reaches prod — byte for byte.
Rebuilding per environment produces a *different, untested* artifact and quietly
invalidates every test you ran.

```bash
# promotion = one commit that changes one line
./ci/scripts/bump-digest.sh --service payment-service \
  --env prod --digest sha256:0000…
git commit -m "promote payment-service to prod: sha256:0000…"
```

```yaml
# gitops/apps/business/prod/payment-service.yaml (the only thing that differs)
image: registry.internal/payment-service@sha256:0000…
```

What this gives you: the diff a reviewer sees is exactly the change; rollback is
`git revert`; and "what is running in prod, from which commit" is answerable from
the repo without asking a cluster.

---

## 3. GitLab CI

```yaml
stages: [validate, build, test, security, publish, deploy]

variables:
  IMAGE: $CI_REGISTRY_IMAGE
  DOCKER_BUILDKIT: "1"

default:
  interruptible: true                # cancel superseded pipelines
  retry: { max: 2, when: [runner_system_failure, stuck_or_timeout_failure] }

.secure: &secure
  image: aquasec/trivy:latest
  allow_failure: false

lint:
  stage: validate
  script: [hadolint Dockerfile, yamllint ., ansible-lint]

build:
  stage: build
  script:
    - docker build -t $IMAGE:$CI_COMMIT_SHA .
    - docker push $IMAGE:$CI_COMMIT_SHA
    - echo "DIGEST=$(docker inspect --format='{{index .RepoDigests 0}}' $IMAGE:$CI_COMMIT_SHA)" >> build.env
  artifacts: { reports: { dotenv: build.env } }    # pass the digest downstream

sast:      { stage: security, script: [semgrep --config=p/owasp-top-ten --error .] }
sca:       { stage: security, script: [trivy fs --exit-code 1 --severity HIGH,CRITICAL .] }
image-scan:{ stage: security, script: [trivy image --exit-code 1 --ignore-unfixed --severity HIGH,CRITICAL $DIGEST] }
sbom:      { stage: security, script: [syft $DIGEST -o cyclonedx-json > sbom.json], artifacts: { paths: [sbom.json] } }
sign:      { stage: publish,  script: [cosign sign --key $COSIGN_KEY $DIGEST] }

promote:dev:
  stage: deploy
  script: [./ci/scripts/bump-digest.sh --env dev --digest $DIGEST]
  rules: [{ if: '$CI_COMMIT_BRANCH == "main"' }]

promote:prod:
  stage: deploy
  script: [./ci/scripts/bump-digest.sh --env prod --digest $DIGEST]
  when: manual                       # human gate
  environment: { name: production }
  rules: [{ if: '$CI_COMMIT_TAG' }]
```

Keywords worth knowing: `rules` (replaces `only/except`), `needs` (DAG, not
stage-ordered), `extends` + `!reference`, `include: project|template`, `parallel:
matrix`, `resource_group` (serialise deploys to one environment), `environment`
(deployment tracking + protected variables), `interruptible`, `dotenv` artifacts.

---

## 4. Jenkins (VM track orchestration)

```groovy
pipeline {
  agent { label 'deploy' }
  options {
    timeout(time: 45, unit: 'MINUTES')
    disableConcurrentBuilds()
    buildDiscarder(logRotator(numToKeepStr: '50'))
  }
  parameters {
    string(name: 'ARTIFACT_VERSION', defaultValue: '', description: 'exact version, no latest')
    choice(name: 'ENVIRONMENT', choices: ['dev','staging','prod'])
  }
  stages {
    stage('Validate') {
      steps { sh 'ansible-playbook --syntax-check playbooks/deploy-app.yml' }
    }
    stage('Approval') {
      when { expression { params.ENVIRONMENT == 'prod' } }
      steps { input message: 'Deploy to prod?', submitter: 'release-managers' }
    }
    stage('Rolling deploy') {
      steps {
        withCredentials([vaultString(path: 'secret/ci/ssh', credentialsId: 'vault')]) {
          sh """ansible-playbook -i inventories/${params.ENVIRONMENT} \
                playbooks/deploy-app.yml -e app_version=${params.ARTIFACT_VERSION}"""
        }
      }
    }
    stage('Smoke') { steps { sh './ci/scripts/smoke.sh ${ENVIRONMENT}' } }
  }
  post {
    failure { sh './ci/scripts/rollback.sh ${ENVIRONMENT}' }
    always  { archiveArtifacts artifacts: 'logs/**', allowEmptyArchive: true }
  }
}
```

Rules for Jenkins that keep it maintainable: pipelines in the repo (`Jenkinsfile`),
shared library for anything reused, agents ephemeral (Kubernetes plugin or
containerised), credentials from Vault not the Jenkins credential store where
possible, and **no build logic in the Jenkins UI** — a job configured by clicking
is state you can't review or restore.

---

## 5. ArgoCD

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: payment-service-prod
  namespace: argocd
spec:
  project: business-prod
  source:
    repoURL: https://git.internal/platform/gitops.git
    targetRevision: main               # or a tag for prod
    path: business/payment-service/overlays/prod
  destination: { server: https://kubernetes.default.svc, namespace: app-payment }
  syncPolicy:
    automated: { prune: true, selfHeal: true }
    syncOptions: [CreateNamespace=false, ServerSideApply=true]
    retry: { limit: 5, backoff: { duration: 10s, factor: 2, maxDuration: 3m } }
  revisionHistoryLimit: 10
```

- **`selfHeal: true`** reverts manual `kubectl edit` — drift correction as a
  feature. It also means "I'll just patch it quickly in prod" stops working,
  which is the point.
- **`prune: true`** deletes resources removed from Git. Powerful and sharp —
  combine with `Prune=false` annotations on anything stateful, and never point
  two Applications at overlapping resources.
- **AppProject** restricts which repos, clusters, namespaces and kinds an app may
  touch — the multi-tenancy boundary _(regulated)_.
- **Sync waves** (`argocd.argoproj.io/sync-wave: "-1"`) order things like
  migrations before the deployment; **hooks** (`PreSync`, `PostSync`) run Jobs.
- **App-of-apps** for bootstrapping: one Application that creates the others.

```bash
argocd app list
argocd app get payment-service-prod
argocd app diff payment-service-prod        # Git vs cluster
argocd app sync payment-service-prod --prune --dry-run
argocd app history payment-service-prod
argocd app rollback payment-service-prod 12
argocd app set … --sync-policy none         # pause automation during an incident
```

---

## 6. Deployment strategies (quick table)

| Strategy | Downtime | Cost | Rollback | Use when |
|---|---|---|---|---|
| Recreate | yes | 1× | slow redeploy | Dev only, singletons |
| Rolling | no | 1.25× | minutes | Default for internal services |
| Blue/green | no | 2× | instant flip | VM fleets, big-bang cutovers |
| **Canary** | no | 1.1× | instant | **Default for prod customer-facing** |
| Shadow | no | 2× | n/a | Validating a rewrite on real traffic |
| Feature flag | no | 1× | instant toggle | Decouple deploy from release — pair with any above |

Canary with automated analysis (Argo Rollouts) is the target state: 5% → analysis
→ 25% → analysis → 50% → 100%, aborting on success-rate or p99 breach. Two rules
that make it real: analysis queries must be **scoped to the canary pods** (by
`rollouts-pod-template-hash`), otherwise the stable pods' healthy traffic masks
the canary's errors; and an abort must **page**, because a silent auto-rollback
nobody investigates ships the same bug again next week.

---

## 7. Database changes — expand / migrate / contract

The reason most "zero-downtime" deploys aren't:

```
1. EXPAND    add the new column/table, nullable, no constraint   (old + new code both work)
2. MIGRATE   backfill in batches; new code writes both, reads old
3. SWITCH    new code reads new                                  (deploy)
4. CONTRACT  drop the old column                                 (a later, separate release)
```
Never combine a schema change and a code change that depends on it in one
release — you've just made rollback impossible. Every migration must be
backward-compatible with the previous application version, because during a
rolling deploy both versions are live simultaneously.

---

## 8. Rollback

| Track | Rollback |
|---|---|
| GitOps/K8s | `git revert` the digest commit → ArgoCD syncs. Or `argocd app rollback` for speed, then fix Git |
| Argo Rollouts | Automatic abort on analysis failure; `kubectl argo rollouts undo` |
| Plain Deployment | `kubectl rollout undo deploy/x` |
| VM blue/green | Flip the LB back to the previous pool |
| Database | Usually **forward-only** — which is why expand/contract exists |
| Feature | Toggle the flag off (fastest of all) |

The rule: a change is not deployable until its rollback has been **tested**, and
"we'd roll forward" is only an answer if you can show the forward path is faster
than the back path.

---

## 9. Environments and promotion gates

```
dev      auto-deploy on merge to main      no gate
staging  auto-deploy, prod-like data shape  automated tests + DAST
prod     manual promotion (digest commit)   review + change window + canary
```
Environment differences live in overlays/values only — never in the image, never
in a branch. Branch-per-environment drifts and produces merge conflicts that hide
config changes; use one repo, one main branch, and directories per environment.

---

## 10. Metrics that tell you if it's working (DORA)

| Metric | Elite-ish | What it exposes |
|---|---|---|
| Deployment frequency | on demand | Batch size, friction |
| Lead time for change | < 1 day | Pipeline speed + approval drag |
| Change failure rate | < 15% | Test quality, canary effectiveness |
| MTTR | < 1 hour | Rollback and observability quality |

Read them together: frequency alone rewards recklessness, change-failure alone
rewards never shipping.

---

## 11. Best practices checklist

- [ ] Build once; promote the **digest**; `latest` banned
- [ ] CI holds no prod credentials; deployment is pull-based
- [ ] Pipeline config in the repo; no job logic configured in a UI
- [ ] Ephemeral runners/agents, no persistent state or credentials
- [ ] Security gates block, with an expiring exception process
- [ ] Every environment reproducible from Git alone
- [ ] `resource_group` / `disableConcurrentBuilds` so two deploys can't race
- [ ] Migrations expand/contract, backward-compatible with N-1
- [ ] Prod deploys are canary with automated analysis and auto-abort that pages
- [ ] Rollback tested, documented in the change record, and timed
- [ ] Smoke tests after every deploy, and the deploy is marked failed if they fail
- [ ] Deployment events annotated onto dashboards — "what changed?" in one glance
- [ ] DORA metrics tracked and reviewed, not gamed

➡ [Interview Q&A](interview-qna.md)
