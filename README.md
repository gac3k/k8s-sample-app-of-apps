# k8s-sample-app-of-apps (POC)

Minimal GitOps base for a local Kubernetes cluster + Argo CD, plus a reusable
`service` Helm chart and a sample app wired up for automated image promotion
via [argocd-image-updater](https://argocd-image-updater.readthedocs.io/).

Source-of-truth Git remote (public HTTPS clone):

`https://github.com/gac3k/k8s-sample-app-of-apps.git`

Web UI: [github.com/gac3k/k8s-sample-app-of-apps](https://github.com/gac3k/k8s-sample-app-of-apps).

## Prerequisites

- NixOS with `direnv` and `devenv`
- A running k3s cluster (managed at OS level via `services.k3s`)
- `kubectl`, `helm` and `argocd` (provided by the devenv shell)

## Bootstrap the cluster

```bash
direnv allow
devenv shell
cluster-create
argocd-bootstrap   # installs Argo CD and applies root (HTTPS clone; no deploy key for Argo CD)
```

Argo CD and the ApplicationSet **clone over HTTPS** (public repo). **argocd-image-updater**
commits tag bumps using **Git write-back** over **SSH**, with credentials in
**`argocd/argocd-image-updater-git-ssh`**: only **`sshPrivateKey`**, synced from **Vault**
path **`secret/argocd/credentials`** (field **`privateKey`**) via an **`ExternalSecret`**
shipped with the **`helm/.../argocd/argocd-image-updater`** umbrella chart (namespace **`argocd`**). The
**`ImageUpdater`** CR sets **`gitConfig.repository`** to the SSH URL so pushes match the
deploy key. Write-back target: **`helmvalues:values.yaml`** on branch **`main`**.

**Optional — seed the write-back secret before External Secrets has reconciled**
(e.g. cold start):

1. Install Argo CD and apply root: `argocd-bootstrap`.
2. Put a Git **deploy key** with **read/write** to the app-of-apps repo into Vault, e.g.  
   `kubectl exec -i -n vault vault-0 -- vault kv put secret/argocd/credentials privateKey=- < ./deploy-key.pem`
3. **`argocd-seed-git-ssh-from-vault`** (reads from Vault; or set `ARGOCD_IMAGE_UPDATER_SSH_KEY_FILE`
   to seed from a local PEM — Secret shape: **`sshPrivateKey`** only).

After this, Argo CD self-manages: the root `Application` points at
`argocd/root/`, which contains an `ApplicationSet` that discovers everything
under `helm/<cluster-name>/<namespace>/<app-name>` and rolls it out.

### Local UIs (Traefik / k3s)

Ingress uses class **`traefik`** (k3s default). Hostnames (RFC 6761 `*.localhost`
usually resolve to loopback):

| Service    | URL                      |
| ---------- | ------------------------ |
| Argo CD UI | http://argocd.localhost  |
| Vault UI   | http://vault.localhost   |
| Sample app | http://sample-app.localhost |

Argo CD server is configured for **HTTP behind the Ingress** (`server.insecure`
+ `configs.cm.url`); this is for local demos only.

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
      argocd-image-updater/             # chart: controller CRDs + ImageUpdater CR + Vault ES
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

### Automated image promotion (argocd-image-updater v1.x)

Since [v1.0](https://argocd-image-updater.readthedocs.io/en/stable/), configuration is **CRD-based**:
an **`ImageUpdater`** resource selects Argo CD `Application`s and declares which
images to track (no `argocd-image-updater.argoproj.io/*` annotations on
`Application`). See the [application configuration](https://argocd-image-updater.readthedocs.io/en/stable/configuration/applications/) docs.

This repo ships the **`ImageUpdater`** as part of **`helm/.../argocd/argocd-image-updater`**
(same Helm release as CRDs and the controller) so the CR is not applied from
**`argocd/root`** before **`ImageUpdater`** CRDs exist — otherwise the controller can log
**`No ImageUpdater CRs to process`** while the CR never made it into etcd.

Configuration lives under **`imageUpdaterGitOps`** and **`gitWriteBackExternalSecret`** in
**`helm/in-cluster/argocd/argocd-image-updater/values.yaml`**. The rendered CR uses
**`writeBackConfig.method: git:secret:argocd/argocd-image-updater-git-ssh`**,
**`gitConfig.repository`** set to the **SSH** remote, and **`gitConfig.branch`** **`main`**,
so new image tags are **committed to Git** in **`helmvalues:values.yaml`** under each app chart (e.g.
`helm/in-cluster/apps/sample-app/values.yaml`). That matches
[Git write-back](https://argocd-image-updater.readthedocs.io/en/stable/basics/update-methods/).
Argo CD still **clones over HTTPS**; only write-back uses the Vault-backed **`sshPrivateKey`** in **`argocd-image-updater-git-ssh`**.

Helm parameter paths for the wrapper chart remain **`manifestTargets.helm.name`**
/
**`manifestTargets.helm.tag`** &rarr; `service.image.repository` /
`service.image.tag`.

Conventions:

- one entry per workload under **`imageUpdaterGitOps.applications`** (map key is only a label;
  **`namePattern`** must match the Argo CD **`Application`** name the ApplicationSet generates, e.g. **`sample-app-apps-in-cluster`**);
- each value has **`images`**: a list of **[argocd-image-updater image specs](https://argocd-image-updater.readthedocs.io/en/stable/configuration/applications/)**
  (multiple images per app supported); optional **`enabled: false`** skips that entry;
- in **`images[].imageName`**, use a **semver constraint** in the tag (e.g. **`>=1.0.0`**, **`^1.0.0`**) — **not** **`latest`** — when **`updateStrategy`** is **`semver`**;
- **`commonUpdateSettings`**: semver and **`allowTags`** restricting tags to
  **`X.Y.Z`** (aligned with **semantic-release** in
  [`gac3k/k8s-sample-app`](https://github.com/gac3k/k8s-sample-app)).

The ApplicationSet **does not** ignore Helm parameter drift on the
`Application` object anymore: tags are persisted in **Git**, not only as
imperative `Application` overrides.

**Checklist so image-updater promotes tags**

1. **`argocd-image-updater-git-ssh`** exists in **`argocd`** with **`sshPrivateKey`**
   (Vault → ExternalSecret or **`argocd-seed-git-ssh-from-vault`**) so **Git push**
   for write-back works.
2. **`argocd-image-updater`** chart is synced; **ImageUpdater CRD** installed.
3. **`ImageUpdater`** `metadata.namespace` is **`argocd`**.
4. **`imageUpdaterGitOps.applications`** includes that app: add a map entry with the right **`namePattern`**
   and an **`images`** list (copy the shape of **`sample-app`**).
5. Registry holds **semver tags** matching **`allowTags`**.
6. **GHCR** reachable; private images need registry auth on the updater.
7. Watch **`kubectl get imageupdater -n argocd`** and **Git commits** on **`main`**
   updating **`service.image.tag`** inside the app `values.yaml`.

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

4. Commit and push. The ApplicationSet picks up the new app automatically.
   In **`helm/in-cluster/argocd/argocd-image-updater/values.yaml`**, under **`imageUpdaterGitOps.applications`**, add a map entry (`namePattern` = `<name>-apps-in-cluster`,
   `imageName` = `ghcr.io/gac3k/k8s-<name>:...`, same **`manifestTargets.helm`**
   as `sample-app`) so [argocd-image-updater v1.x](https://argocd-image-updater.readthedocs.io/en/stable/)
   tracks that Application.

## Vault and External Secrets (POC only)

Three charts land in the cluster:

1. **`helm/in-cluster/vault/vault`** &mdash; official [Vault Helm chart](https://github.com/hashicorp/vault-helm) in **dev mode** (in-memory storage, fixed root token `root`). Data is lost when the pod restarts; do not use beyond experiments.
2. **`helm/in-cluster/external-secrets/external-secrets`** &mdash; [External Secrets Operator](https://external-secrets.io/) (installs CRDs, controller, webhook, cert-controller).
3. **`helm/in-cluster/external-secrets/vault-integration`** &mdash; `ClusterSecretStore` **`vault-backend`** (referenced by the image-updater **`ExternalSecret`**) plus `vault-root-token` in **`external-secrets`** for Vault token auth (must match `vault.server.dev.devRootToken`).

Resources in `vault-integration` use Argo CD sync wave **10** so Vault and the operator can reconcile first. On a cold cluster you may still need to **retry** the `vault-integration` app once CRDs exist.

**Git deploy key in Vault** (KV v2, field **`privateKey`**):

```bash
kubectl exec -i -n vault vault-0 -- vault kv put secret/argocd/credentials privateKey=- < /path/to/git-deploy-key.pem
```

Use a deploy key with **read + write** to **`k8s-sample-app-of-apps`** (image-updater commits on **`main`**).

**Optional demo secret** (unrelated to Git):

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
