# CI/CD & Automation

## 1. Tool responsibilities — draw the lines clearly

| Tool | Owns | Does NOT own |
|---|---|---|
| **Terraform** | Infrastructure lifecycle: VMs, networks, LBs, DNS, clusters, storage, cloud IAM | App config, package installs, K8s workloads |
| **Ansible** | Host configuration, hardening, agent install, VM app deployment, patching, K8s node install | Provisioning infra, K8s workload lifecycle |
| **GitLab CI** | Build, test, scan, sign, publish artifacts; open the promotion MR | Holding prod cluster credentials |
| **Jenkins** | Long-running / legacy / VM-orchestration jobs, scheduled DB & batch ops | New app pipelines (use GitLab CI) |
| **ArgoCD** | Deploying and reconciling everything inside Kubernetes | Building images |
| **Helm / Kustomize** | Packaging K8s manifests | Environment secrets |

**The seam that matters:** CI *builds and proves* an artifact. CD *reconciles* the desired state. They meet at a Git commit containing an image digest — never at a `kubectl apply` from a runner.

---

## 2. GitLab CI — application pipeline

```yaml
# .gitlab-ci.yml
stages: [validate, test, build, scan, sign, publish, promote]

variables:
  IMAGE: harbor.internal/app/payment-service
  DOCKER_BUILDKIT: "1"

default:
  tags: [k8s-runner-untrusted]     # PR builds run on an isolated runner fleet
  interruptible: true

# ---------- validate ----------
secrets-scan:
  stage: validate
  script:
    - gitleaks detect --source=. --redact --exit-code 1 --log-opts="--all"

lint:
  stage: validate
  script:
    - ruff check . && ruff format --check .
    - hadolint Dockerfile

sast:
  stage: validate
  script:
    - semgrep ci --config=auto --error --severity=ERROR --severity=WARNING
  artifacts: { reports: { sast: semgrep.sarif }, when: always }

deps-scan:
  stage: validate
  script:
    - trivy fs --scanners vuln,license --severity HIGH,CRITICAL --exit-code 1 .

# ---------- test ----------
unit-test:
  stage: test
  script:
    - pytest --cov=src --cov-fail-under=80 --junitxml=report.xml
  artifacts: { reports: { junit: report.xml } }

integration-test:
  stage: test
  services: [postgres:16]
  script: [pytest tests/integration]

# ---------- build ----------
build-image:
  stage: build
  rules: [{ if: '$CI_COMMIT_BRANCH == "main"' }]
  script:
    - |
      docker build \
        --build-arg VERSION=$CI_COMMIT_SHA \
        --label org.opencontainers.image.revision=$CI_COMMIT_SHA \
        --label org.opencontainers.image.source=$CI_PROJECT_URL \
        -t $IMAGE:$CI_COMMIT_SHA .
    - docker push $IMAGE:$CI_COMMIT_SHA
    - |
      DIGEST=$(docker inspect --format='{{index .RepoDigests 0}}' $IMAGE:$CI_COMMIT_SHA)
      echo "DIGEST=$DIGEST" >> build.env
  artifacts: { reports: { dotenv: build.env } }

# ---------- scan ----------
image-scan:
  stage: scan
  script:
    - trivy image --severity CRITICAL --exit-code 1 --ignore-unfixed $DIGEST
    - trivy image --severity HIGH --exit-code 0 --format json -o high.json $DIGEST
  artifacts: { paths: [high.json], when: always }

sbom:
  stage: scan
  script:
    - syft $DIGEST -o cyclonedx-json > sbom.json
  artifacts: { paths: [sbom.json] }

# ---------- sign ----------
sign-image:
  stage: sign
  id_tokens: { SIGSTORE_ID_TOKEN: { aud: sigstore } }
  script:
    - cosign sign --yes $DIGEST
    - cosign attest --yes --predicate sbom.json --type cyclonedx $DIGEST

# ---------- promote ----------
promote-dev:
  stage: promote
  tags: [k8s-runner-trusted]
  script:
    - ./ci/bump-digest.sh gitops business/payment-service/overlays/dev "$DIGEST"
  environment: { name: dev }

promote-uat:
  stage: promote
  when: manual
  script:
    - ./ci/bump-digest.sh gitops business/payment-service/overlays/uat "$DIGEST"
  environment: { name: uat }

promote-prod:
  stage: promote
  when: manual
  allow_failure: false
  script:
    # opens an MR — a human with prod rights merges it; the runner never merges
    - ./ci/open-promotion-mr.sh gitops business/payment-service/overlays/prod "$DIGEST"
  environment: { name: prod }
  rules: [{ if: '$CI_COMMIT_BRANCH == "main"' }]
```

**Vault integration (no CI secret variables):**
```yaml
.vault-auth: &vault-auth
  id_tokens: { VAULT_ID_TOKEN: { aud: https://vault.internal } }
  before_script:
    - export VAULT_TOKEN=$(vault write -field=token auth/jwt/login role=ci-payment jwt=$VAULT_ID_TOKEN)
    - export HARBOR_PASS=$(vault kv get -field=password kv/ci/harbor)
```

---

## 3. GitLab CI — Terraform pipeline

```yaml
stages: [validate, plan, apply]

.tf: &tf
  image: hashicorp/terraform:1.9
  before_script:
    - cd environments/$ENVIRONMENT
    - terraform init -input=false

tf-validate:
  <<: *tf
  stage: validate
  script:
    - terraform fmt -check -recursive ../..
    - terraform validate
    - tflint --recursive
    - checkov -d ../.. --framework terraform --soft-fail-on LOW

tf-plan:
  <<: *tf
  stage: plan
  script:
    - terraform plan -input=false -lock-timeout=5m -out=tfplan
    - terraform show -no-color tfplan > plan.txt
    # fail the pipeline if the plan destroys anything in prod
    - |
      if [ "$ENVIRONMENT" = "prod" ] && terraform show -json tfplan \
         | jq -e '.resource_changes[]?.change.actions|index("delete")' >/dev/null; then
        echo "DESTROY detected in prod plan — requires explicit override"; exit 1
      fi
  artifacts: { paths: [environments/$ENVIRONMENT/tfplan, environments/$ENVIRONMENT/plan.txt], expire_in: 7 days }

tf-apply:
  <<: *tf
  stage: apply
  when: manual
  environment: { name: $ENVIRONMENT }
  script: [terraform apply -input=false tfplan]     # applies the reviewed plan, never re-plans
  rules: [{ if: '$CI_COMMIT_BRANCH == "main"' }]
```

Rules: plan is posted to the MR for review; apply consumes the **saved plan file** so what's approved is what runs; prod apply requires 2 approvals and a change ticket ID in the commit message.

---

## 4. Jenkins — where it still earns its place

Use Jenkins for: VM deployment orchestration (long-running, node-by-node), scheduled DB maintenance, batch/ETL jobs, and pipelines needing rich approval workflows or legacy plugin integrations.

```groovy
// Jenkinsfile — VM blue/green rollout
pipeline {
  agent { label 'ansible-controller' }
  options { timestamps(); disableConcurrentBuilds(); buildDiscarder(logRotator(numToKeepStr: '50')) }
  parameters {
    choice(name: 'ENVIRONMENT', choices: ['uat', 'prod'])
    string(name: 'ARTIFACT_VERSION', defaultValue: '')
  }
  environment { VAULT_ADDR = 'https://vault.internal:8200' }

  stages {
    stage('Checkout')  { steps { checkout scm } }

    stage('Fetch secrets') {
      steps {
        withVault(configuration: [vaultUrl: env.VAULT_ADDR],
                  vaultSecrets: [[path: 'kv/ansible/deploy',
                                  secretValues: [[envVar: 'ANSIBLE_BECOME_PASS', vaultKey: 'become']]]]) {
          sh 'echo secrets loaded into env for this stage only'
        }
      }
    }

    stage('Dry run') {
      steps {
        sh """ansible-playbook -i inventories/${params.ENVIRONMENT}/hosts.yml \
              playbooks/deploy-app.yml --check --diff \
              -e app_version=${params.ARTIFACT_VERSION}"""
      }
    }

    stage('Approval') {
      when { expression { params.ENVIRONMENT == 'prod' } }
      steps {
        timeout(time: 60, unit: 'MINUTES') {
          input message: "Deploy ${params.ARTIFACT_VERSION} to PROD?", submitter: 'release-managers'
        }
      }
    }

    stage('Rolling deploy') {
      steps {
        // serial:1 in the play drains one LB member at a time
        sh """ansible-playbook -i inventories/${params.ENVIRONMENT}/hosts.yml \
              playbooks/deploy-app.yml -e app_version=${params.ARTIFACT_VERSION}"""
      }
    }

    stage('Smoke test') {
      steps { sh "./ci/smoke.sh ${params.ENVIRONMENT}" }
    }
  }

  post {
    failure {
      sh """ansible-playbook -i inventories/${params.ENVIRONMENT}/hosts.yml \
            playbooks/deploy-app.yml -e app_version=${env.PREVIOUS_VERSION} -e rollback=true"""
      slackSend channel: '#deploys', color: 'danger', message: "ROLLED BACK ${params.ENVIRONMENT}"
    }
    always { archiveArtifacts artifacts: '**/*.log', allowEmptyArchive: true }
  }
}
```

Jenkins hardening: agents ephemeral (K8s plugin), no build on controller, script security enabled, RBAC via Keycloak OIDC, credentials from Vault (not Jenkins credential store where avoidable), Jenkins config as code (JCasC) in Git, plugins version-pinned and patched monthly.

---

## 5. Ansible — VM deployment pattern

```yaml
# playbooks/deploy-app.yml — blue/green over the LB pool
- name: Deploy application to VM pool
  hosts: app_servers
  serial: 1                          # one node at a time — never all at once
  max_fail_percentage: 0             # any failure stops the rollout
  become: true

  pre_tasks:
    - name: Verify target version artifact exists
      ansible.builtin.uri:
        url: "{{ artifact_repo }}/{{ app_name }}/{{ app_version }}/checksum"
        status_code: 200
      delegate_to: localhost
      become: false

    - name: Drain node from load balancer
      community.general.haproxy:
        state: disabled
        host: "{{ inventory_hostname }}"
        socket: /var/run/haproxy.sock
        backend: "{{ app_name }}_backend"
        drain: true
        wait: true
      delegate_to: "{{ item }}"
      loop: "{{ groups['loadbalancers'] }}"

    - name: Wait for connections to finish
      ansible.builtin.wait_for: { timeout: 30 }

  roles:
    - role: app_deploy
      vars:
        app_deploy_version: "{{ app_version }}"

  post_tasks:
    - name: Wait for app health endpoint
      ansible.builtin.uri:
        url: "http://127.0.0.1:8080/healthz"
        status_code: 200
      register: health
      retries: 30
      delay: 5
      until: health.status == 200

    - name: Run smoke test on this node
      ansible.builtin.command: /opt/app/bin/smoke-test.sh
      changed_when: false

    - name: Re-enable node in load balancer
      community.general.haproxy:
        state: enabled
        host: "{{ inventory_hostname }}"
        socket: /var/run/haproxy.sock
        backend: "{{ app_name }}_backend"
        wait: true
      delegate_to: "{{ item }}"
      loop: "{{ groups['loadbalancers'] }}"

    - name: Soak — watch error rate before moving to next node
      ansible.builtin.pause: { seconds: 60 }
```

Ansible rules: always `--check --diff` first in CI; idempotency verified (second run = 0 changed); no `shell`/`command` without `changed_when`/`creates`; `ansible-lint` in CI; roles versioned via `requirements.yml`.

---

## 6. ArgoCD — GitOps for Kubernetes

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: payment-service-prod
  namespace: argocd
  finalizers: [resources-finalizer.argocd.argoproj.io]
spec:
  project: business-prod
  source:
    repoURL: https://gitlab.internal/platform/apps-gitops.git
    targetRevision: main
    path: business/payment-service/overlays/prod
  destination:
    server: https://kubernetes.default.svc
    namespace: app-payment
  syncPolicy:
    automated: { prune: false, selfHeal: true }   # prod: selfHeal yes, prune NO (avoid surprise deletes)
    syncOptions: [CreateNamespace=false, ApplyOutOfSyncOnly=true]
    retry: { limit: 3, backoff: { duration: 10s, factor: 2, maxDuration: 3m } }
  revisionHistoryLimit: 10
```

- **AppProject** per environment restricts which repos, destinations, and cluster resources an app may touch.
- ArgoCD SSO via Keycloak; RBAC: devs get `get/sync` on dev/uat, `get` only on prod.
- Notifications → Slack/Teams on `sync-failed`, `health-degraded`, `out-of-sync > 15m`.
- Drift is an alert: `selfHeal` fixes it and `OutOfSync` fires a notification — someone changed prod by hand and that needs investigating.

**Progressive delivery (Argo Rollouts) for prod app traffic:**
```yaml
strategy:
  canary:
    canaryService: payment-canary
    stableService: payment-stable
    trafficRouting: { nginx: { stableIngress: payment-ingress } }
    steps:
      - setWeight: 5
      - pause: { duration: 5m }
      - analysis:
          templates: [{ templateName: success-rate }]   # abort if error rate > 1%
      - setWeight: 25
      - pause: { duration: 10m }
      - setWeight: 50
      - pause: { duration: 10m }
      - setWeight: 100
```

---

## 7. Deployment strategy per workload type

| Workload | Strategy | Rollback |
|---|---|---|
| Stateless API (K8s) | Canary via Argo Rollouts, automated analysis | auto-abort → previous ReplicaSet, < 2 min |
| Stateless API (VM) | Blue/green at LB, `serial: 1` | re-run playbook with previous version |
| Database schema | Expand → migrate → contract, in **separate releases** | never rollback a migration; roll forward |
| Stateful set (Kafka/PG) | Operator-managed rolling, one pod at a time | operator failover + PITR restore |
| Config change | Same pipeline as code (GitOps) | `git revert` |
| Emergency hotfix | Same pipeline, expedited approval, **never a manual kubectl** | documented, post-incident review mandatory |

**Database migration rule (the one that bites everyone):** deploy code that works with both old and new schema, migrate, then remove old-schema support in a later release. This keeps rollback possible at every step.

## 8. Golden rules

1. Build once, promote the same digest. A rebuild for prod invalidates all your testing.
2. CI never has prod cluster credentials. ArgoCD pulls; CI pushes a commit.
3. Every deploy has a documented, *tested* rollback. Untested rollback = no rollback.
4. Manual gates are for approval, not for typing commands.
5. Prod deploys during business hours with the team available. Not Friday 17:00.
6. If the pipeline is slow, developers route around it. Keep the PR path under 10 minutes.
