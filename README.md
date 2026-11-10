# unified-deploy-pipeline

> One shared deploy pipeline, pinned by tag, that every component reuses through a ~20-line
> dispatcher — on GitLab CI or GitHub Actions — with four modes so a config change never
> costs a rebuild.

[![ci](https://github.com/henrydominguez-cloud/unified-deploy-pipeline/actions/workflows/ci.yml/badge.svg)](https://github.com/henrydominguez-cloud/unified-deploy-pipeline/actions/workflows/ci.yml) ![license](https://img.shields.io/badge/license-MIT-blue) ![helm](https://img.shields.io/badge/Helm-3_|_4-0f1689)

## Why this exists

When every service carries its own long CI file, and its chart and values live in other
repos, two things happen: a pipeline bug has to be fixed N times, and a one-line config
change triggers a full build, test and pod restart. I rebuilt the pattern I use to avoid that
as a generic, MIT-licensed model: code, chart and values in one repo, one shared pipeline
composed from small blocks (the same composition idea as my `ansible-lego` roles), and
explicit modes. All behaviour lives in plain shell scripts, so GitLab CI and GitHub Actions
are two thin adapters over the same logic. It is a reference implementation to fork, not a
hosted product.

| What | Status |
|---|---|
| `scripts/ci/*.sh`, chart, four modes | Tested: 27 unit/script tests + 19 end-to-end assertions on kind (`make preflight`) |
| GitHub Actions adapter | Self-test on every push to this repo (test, build, push, scan, render); deploy to a real cluster not yet exercised |
| GitLab CI adapter | Written and linted; first run on a live GitLab instance pending |

## Architecture

```
 component repo (any service)              this repo, tagged vX.Y.Z
┌───────────────────────────┐            ┌────────────────────────────────────────────┐
│ dispatcher (~20 lines)    │  include / │ GitLab adapter      GitHub adapter         │
│   form: MODE · CLUSTERS   ├── uses ───▶│ pipeline/*.yml      .github/workflows/     │
│ Dockerfile, src/          │  by tag    │                       deploy.yml           │
│ chart/                    │            │        └───────┬───────┘                   │
│ envs/<env>/infra.yaml ops │            │                ▼                           │
│ envs/<env>/app.yaml  team │            │ scripts/ci/*.sh   ← all the logic (POSIX)  │
└───────────────────────────┘            │ setup test build scan render deploy smoke  │
                                         │ rollback                                   │
                                         └──────────────────┬─────────────────────────┘
                                                            │ helm (kubeconfig per cluster)
                                                 ┌──────────┴──────────┐
                                                 ▼                     ▼
                                            cluster-a             cluster-b

 full:         setup → test → build → scan → lint → ▶deploy → smoke   (▶ = manual gate)
 config_only:  setup → lint → deploy (same image, new values) → smoke
 deploy_image: setup → lint → ▶deploy (existing tag) → smoke
 rollback:     setup → rollback (previous or chosen Helm revision)
```

- **Dispatcher** — the only CI file in a component. Shows a form and calls the shared pipeline at a pinned tag.
- **Adapters** — decide *when* and *where* each step runs. No deploy logic in YAML.
- **scripts/ci/** — decide *how*: one script per step, tested without a cluster and on kind.
- **Values chain** — `chart/values.yaml` → `envs/<env>/infra.yaml` → `envs/<env>/app.yaml` → image tag. No `--reuse-values`: git is the source of truth.
- **examples/sample-app** — a tiny Python service with chart and envs, used by every test.

## Getting started

| Tool | Why |
|---|---|
| helm (3 or 4), yamllint, shellcheck, python3 + pytest | Local checks — `make doctor` lists what is missing |
| docker (or Colima), kind, kubectl | Local end-to-end test |
| GitLab or GitHub | To run the pipeline for real |

**Try it locally first** (Linux or macOS, no cloud cost):

```bash
git clone https://github.com/henrydominguez-cloud/unified-deploy-pipeline.git && cd unified-deploy-pipeline
make doctor                  # tools installed? prints an install hint per missing tool
make preflight               # 7 steps, ends with "PREFLIGHT OK · 7/7 steps"
SKIP_E2E=1 make preflight    # same without the kind test (~1 min, no cluster)
make kind-down               # teardown: deletes the kind cluster and everything in it
```

`make preflight` runs unit tests, script tests with stubbed helm/kubectl, yamllint and
shellcheck, `helm lint` + render for both environments, a secret/private-term scan of files
and git history, and the four modes on a kind cluster. The kind test uses its own kubeconfig,
never your current kubectl context.

### Use it with GitHub Actions

1. Copy `examples/dispatcher-github/.github/workflows/deploy.yml` into your component repo.
   Keep the two tags in it equal (`@v0.1.0` and `pipeline_ref: v0.1.0`).
2. Put the chart in `chart/` and values in `envs/develop|production/{infra,app}.yaml`.
3. Add repository secrets `KUBECONFIG_CLUSTER_A` and/or `KUBECONFIG_CLUSTER_B` with the
   kubeconfig **content**. A cluster without a secret is skipped.
4. For a manual gate, add required reviewers to the environments `cluster-a` / `cluster-b`
   (*Settings → Environments*).
5. *Actions → deploy → Run workflow*, pick mode and clusters. Or from a terminal:

```bash
gh workflow run deploy.yml -R your-org/your-component --ref main -f mode=config_only -f clusters=cluster-a
```

Images go to `ghcr.io/<owner>/<repo>/<app>` using the built-in `GITHUB_TOKEN`.

### Use it with GitLab CI

1. Host this repo on your GitLab instance (*New project → Import project → Repository by URL*):
   GitLab can only `include:` pipelines from the same instance.
2. Copy `examples/dispatcher-gitlab/.gitlab-ci.yml` to your component root. Set `project:`
   and `PIPELINE_REPO` to where you host this repo, and keep `ref:` equal to `PIPELINE_REF`.
3. Put the chart in `chart/` and values in `envs/develop|production/{infra,app}.yaml`.
4. Add **File** variables `KUBECONFIG_CLUSTER_A` and/or `KUBECONFIG_CLUSTER_B` (protected).
   A cluster without a variable gets no jobs.
5. *Build → Pipelines → Run pipeline*, pick mode and clusters.

Images go to the GitLab Container Registry by default (`REGISTRY*` variables override it).
`examples/console-gitlab/` is an optional launcher repo that triggers any component from one
place; the dispatcher also accepts trigger tokens and the pipelines API.

### Same concept on both platforms

| Concept | GitLab CI | GitHub Actions |
|---|---|---|
| Shared pipeline | `pipeline/unified-pipeline.yml` | `.github/workflows/deploy.yml` (reusable workflow) |
| Pin by tag | `include: project … ref: v0.1.0` | `uses: …/deploy.yml@v0.1.0` |
| Form | `variables:` with `options:` | `workflow_dispatch` inputs |
| Cluster credentials | File variable `KUBECONFIG_CLUSTER_A` | Secret `KUBECONFIG_CLUSTER_A` |
| Manual gate | `when: manual` on deploy (not for `config_only`) | Environment reviewers (apply to every mode) |
| One deploy at a time | `resource_group` | `concurrency` |
| Launch from outside | Console repo, trigger token, API | `gh workflow run`, REST API |
| Undo after a deploy | Manual `rollback_*` job in the same pipeline | Run again with `mode=rollback` |

### Modes

| Mode | Builds | Image deployed | Use when |
|---|---|---|---|
| `full` | yes | new `dev-`/`prod-<run id>` | new code |
| `config_only` | no | the one running now (read from the cluster) | edited `app.yaml` or `infra.yaml` |
| `deploy_image` | no | the `IMAGE_TAG` you pass | promote or roll forward |
| `rollback` | no | previous Helm revision, or the one you pass | something broke |

Branch → environment: `main`, `master`, `release/*` → `production`; anything else → `develop`.
Every deploy log ends with `DEPLOY OK · <release> · <cluster> · <namespace> · <tag> · <mode>`.

## Design decisions

| Decision | Alternative considered | Why |
|---|---|---|
| Logic in POSIX scripts; CI YAML only wires jobs | Shell inline in the CI file | One implementation serves GitLab, GitHub and `make`, and is testable without a cluster. Cost: the scripts must be fetched at the pinned ref in every job. |
| Shared pipeline called **by tag** | Track `main`, or copy the YAML into each repo | A fix ships once; each component upgrades when it chooses and can stay on the old tag. Cost: components drift across versions, so old tags need a deprecation window. |
| Explicit **modes** | One pipeline that always builds and deploys | `config_only` skips build and test, so a value change takes seconds. Cost: a human can pick the wrong mode; `setup` rejects the obvious mistakes. |
| No `--reuse-values` | Let Helm merge with the last release | Every deploy re-applies the repo's values. Only the image tag is carried over, read from the running Deployment. |
| `app.yaml` vs `infra.yaml`, enforced with CODEOWNERS | One values file per environment | Teams change behaviour without asking ops; ops own capacity. Only real with code-owner approval (`examples/dispatcher-gitlab/CODEOWNERS`). |
| Config checksum on the pod template | Always restart, or never | Pods roll only when the rendered ConfigMap changes — asserted by the kind test. |
| Cluster enabled by the presence of a credential | A cluster list in YAML | Forks run green with zero setup; adding a cluster is a settings change, not a code change. |

## What I'd do differently in production

- **Credentials:** stored kubeconfigs are long-lived secrets. I'd use OIDC (GitLab `id_tokens`,
  GitHub `id-token`) for short-lived cloud credentials, so nothing is stored in CI settings.
- **GitOps:** this pipeline pushes with `helm upgrade`. For many clusters I'd commit the image
  tag to an environment repo and let Argo CD or Flux reconcile: drift detection, and no
  cluster access from CI.
- **Supply chain:** tool images and actions are pinned by tag, not digest, and the scripts
  and Grype installer are fetched at job time. Next: a digest-pinned tools image carrying the
  scripts, image signing (cosign) and an admission policy for unsigned images.
- **Runners:** deploy jobs run on shared runners. Production needs runners inside each
  cluster's network and protected environments with named approvers.
- **Smoke test:** it only calls `/healthz` from inside the namespace. Real services need
  per-component checks and an automatic rollback when they fail.

## Repository layout

```
.
├── pipeline/                    GitLab adapter: unified-pipeline.yml + blocks 00…40
├── .github/workflows/
│   ├── deploy.yml               GitHub adapter (reusable workflow)
│   └── ci.yml                   this repo's checks: make preflight + deploy self-test
├── .gitlab-ci.yml               this repo's checks on GitLab
├── scripts/
│   ├── ci/                      setup · test · build · scan · render · deploy · smoke · rollback
│   ├── check-sanitized.sh       secret / private-term scan: files + git history
│   ├── doctor.sh · preflight.sh tool check · all pre-push checks in one command
│   └── hooks/pre-push           installed by `make hooks`
├── examples/
│   ├── dispatcher-github/       workflow to copy into a component (GitHub)
│   ├── dispatcher-gitlab/       .gitlab-ci.yml + CODEOWNERS to copy (GitLab)
│   ├── console-gitlab/          optional launcher repo (GitLab)
│   └── sample-app/              app.py, tests, Dockerfile, chart/, envs/
├── tests/                       ci-scripts.sh (stubs) · e2e-kind.sh (real cluster)
├── Makefile                     doctor · preflight · hooks · test · lint · render · sanitize · e2e · kind-*
└── LICENSE
```

## License

MIT — see [LICENSE](LICENSE).
