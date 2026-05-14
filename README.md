# k8s-sample-app-of-apps (POC)

Minimal GitOps base for a local Kubernetes cluster + Argo CD, plus a reusable
`service` Helm chart and a sample app wired up for automated image promotion
via [argocd-image-updater](https://argocd-image-updater.readthedocs.io/).

Source-of-truth repo:
[`https://github.com/gac3k/k8s-sample-app-of-apps`](https://github.com/gac3k/k8s-sample-app-of-apps)
(public, cloned anonymously over HTTPS &mdash; no SSH keys to manage).

## Prerequisites

- NixOS with `direnv` and `devenv`
- A running k3s cluster (managed at OS level via `services.k3s`)
- `kubectl`, `helm` and `argocd` (provided by the devenv shell)

## Bootstrap the cluster

```bash
direnv allow
devenv shell
cluster-create       # imports /etc/rancher/k3s/k3s.yaml to .kube/k3s.yaml
argocd-bootstrap     # helm-installs Argo CD + applies the root Application
```

After this, Argo CD self-manages: the root `Application` points at
`argocd/root/`, which contains an `ApplicationSet` that discovers everything
under `helm/<cluster-name>/<namespace>/<app-name>` and rolls it out.

## Layout

```
charts/
  service/                              # reusable base chart
                                        #  (deployment, service, ingress,
                                        #   secret, serviceaccount, hpa)
helm/
  in-cluster/
    argocd/
      argocd/                           # umbrella for Argo CD itself
      argocd-image-updater/             # umbrella for argocd-image-updater
    apps/
      sample-app/                       # wraps charts/service (Helm dep)
    vault/
      vault/                            # HashiCorp Vault (dev mode, POC)
    external-secrets/
      external-secrets/                 # External Secrets Operator + CRDs
      vault-integration/              # ClusterSecretStore + optional demo ES
    default/
      hello/                            # tiny standalone configmap demo
bootstrap/
  root-application.yaml                 # the root Application kubectl-applied
                                        #  after the initial Argo CD install;
                                        #  it points at argocd/root/
argocd/
  root/
    application-set.yaml                # discovers helm/**/* once Argo is alive
    appproject.yaml                     # AppProject "platform"
```

## Conventions

### Namespaces are derived from the directory tree

Each leaf directory under `helm/<cluster>/<namespace>/<app>` becomes one
`Application`:

| Path                                          | Application name                          | Target namespace |
| --------------------------------------------- | ----------------------------------------- | ---------------- |
| `helm/in-cluster/argocd/argocd`               | `argocd-argocd-in-cluster`                | `argocd`         |
| `helm/in-cluster/argocd/argocd-image-updater` | `argocd-image-updater-argocd-in-cluster`  | `argocd`         |
| `helm/in-cluster/vault/vault`                 | `vault-vault-in-cluster`                  | `vault`          |
| `helm/in-cluster/external-secrets/external-secrets` | `external-secrets-external-secrets-in-cluster` | `external-secrets` |
| `helm/in-cluster/external-secrets/vault-integration` | `vault-integration-external-secrets-in-cluster` | `external-secrets` |
| `helm/in-cluster/default/hello`               | `hello-default-in-cluster`                | `default`        |
| `helm/in-cluster/apps/sample-app`             | `sample-app-apps-in-cluster`              | `apps`           |

### Apps under the `apps` namespace use the base `service` chart

Anything under `helm/<cluster>/apps/<name>/` is expected to be a thin
wrapper chart whose `Chart.yaml` lists `charts/service` as a Helm
dependency:

```yaml
# helm/<cluster>/apps/<name>/Chart.yaml
dependencies:
  - name: service
    version: 0.1.0
    repository: "file://../../../../charts/service"
```

After adding or bumping the dependency, vendor it locally:

```bash
helm dependency update helm/<cluster>/apps/<name>
git add helm/<cluster>/apps/<name>/Chart.lock helm/<cluster>/apps/<name>/charts
```

The wrapper's `values.yaml` overrides keys under the `service:` namespace,
exactly as you would override any Helm sub-chart.

### Automated image promotion (argocd-image-updater)

The `ApplicationSet` attaches `argocd-image-updater.argoproj.io/...`
annotations to every Application whose namespace segment is `apps`. The
convention is:

- image lives at `ghcr.io/gac3k/k8s-<app-name>`
- semver tags (`X.Y.Z`) are produced by
  [semantic-release](https://github.com/semantic-release/semantic-release)
  running in the source repository (see
  [`gac3k/k8s-sample-app`](https://github.com/gac3k/k8s-sample-app))
- `argocd-image-updater` watches the registry and writes the latest
  matching tag back to the Application as a Helm parameter override
  (`service.image.tag`), without touching Git

To prevent the ApplicationSet from reverting those overrides on each
reconciliation, the manifest declares
`spec.ignoreApplicationDifferences[].jsonPointers: [/spec/source/helm/parameters]`.

## Adding a new app

1. Create a wrapper chart:

   ```bash
   mkdir -p helm/in-cluster/apps/<name>
   cat > helm/in-cluster/apps/<name>/Chart.yaml <<'YAML'
   apiVersion: v2
   name: <name>
   type: application
   version: 0.1.0
   dependencies:
     - name: service
       version: 0.1.0
       repository: "file://../../../../charts/service"
   YAML
   ```

2. Define overrides in `helm/in-cluster/apps/<name>/values.yaml` under the
   `service:` key (image repo, env vars, ingress, secret data, etc.).

3. Vendor the base chart:

   ```bash
   helm dependency update helm/in-cluster/apps/<name>
   ```

4. Commit and push. The ApplicationSet picks it up automatically, with
   `argocd-image-updater` annotations applied.

## Vault and External Secrets (POC only)

Three charts land in the cluster:

1. **`helm/in-cluster/vault/vault`** &mdash; official [Vault Helm chart](https://github.com/hashicorp/vault-helm) in **dev mode** (in-memory storage, fixed root token `root`). Data is lost when the pod restarts; do not use beyond experiments.
2. **`helm/in-cluster/external-secrets/external-secrets`** &mdash; [External Secrets Operator](https://external-secrets.io/) (installs CRDs, controller, webhook, cert-controller).
3. **`helm/in-cluster/external-secrets/vault-integration`** &mdash; a `ClusterSecretStore` named `vault-backend` using **token auth** against `http://vault.vault.svc.cluster.local:8200`, plus a Kubernetes `Secret` `vault-root-token` in the `external-secrets` namespace holding that token (must match `vault.server.dev.devRootToken`).

Resources in `vault-integration` use Argo CD sync wave **10** so Vault and the operator can reconcile first. On a cold cluster you may still need to **retry** the `vault-integration` app once CRDs exist.

**Seed a secret in Vault** (KV v2):

```bash
kubectl exec -n vault vault-0 -- vault kv put secret/demo password="hello-vault"
```

**Optional demo `ExternalSecret`:** in `vault-integration/values.yaml`, set `demoExternalSecret.enabled: true`. That creates an `ExternalSecret` in `external-secrets` that syncs `secret/data/demo` &rarr; a Kubernetes `Secret` (see the same file for names/paths). Commit after enabling.

For production you would replace dev Vault and root-token auth with proper storage, TLS, and [Kubernetes auth](https://developer.hashicorp.com/vault/docs/auth/kubernetes) (or another method), and you would **not** store long-lived root tokens in Git&mdash;use sealed secrets, SOPS, or a bootstrap job.

## Sample app

See `helm/in-cluster/apps/sample-app/values.yaml` for a worked example
that wires `GREETINGS`, `PAGE_COLOR`, `TEXT_COLOR` and
`SUPER_SECRET_PASSWORD` into the
[`gac3k/k8s-sample-app`](https://github.com/gac3k/k8s-sample-app)
container.
