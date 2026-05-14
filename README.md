# Mindsec app-of-apps (POC)

This repository is a minimal GitOps base for a local Kubernetes cluster and Argo CD.

## Why k3s/k3d (instead of minikube)

This POC defaults to **k3s via k3d** because it is lightweight, fast to start, and works well for local GitOps iterations.

## Prerequisites

- NixOS with `direnv`
- `devenv`

## Configure the repo URL

Replace `REPO_URL_PLACEHOLDER` in:

- `bootstrap/root-application.yaml`
- `argocd/root/application-set.yaml`

with the Git URL of this repository (reachable from inside the cluster).

## Create cluster and bootstrap Argo CD

From the repository root:

```bash
direnv allow
devenv shell
cluster-create
argocd-bootstrap
```

## Directory-driven Helm layout

Applications are discovered automatically from:

`helm/<cluster-name>/<namespace>/<app-name>`

Example:

- `helm/in-cluster/argocd/argocd`
- `helm/in-cluster/default/hello`

