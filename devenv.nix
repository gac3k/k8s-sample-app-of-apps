{
  pkgs,
  lib,
  config,
  inputs,
  ...
}: {
  env.DEFAULT_CLUSTER_NAME = "in-cluster";
  env.DEFAULT_K3S_KUBECONFIG_SRC = "/etc/rancher/k3s/k3s.yaml";
  env.DEFAULT_K3S_CONTEXT = "default";
  env.KUBECONFIG = "/home/dom/.kube/config-k3s";
  env.ARGOCD_NAMESPACE = "argocd";
  env.ARGOCD_SERVER_LOCAL = "127.0.0.1:8080";

  packages = [
    pkgs.git
    pkgs.kubectl
    pkgs.kubernetes-helm
    pkgs.argocd
    pkgs.kustomize
  ];

  scripts.cluster-create.exec = ''
    set -euo pipefail

    KUBECONFIG_SRC="''${K3S_KUBECONFIG_SRC_OVERRIDE:-$DEFAULT_K3S_KUBECONFIG_SRC}"
    CONTEXT_NAME="''${K3S_CONTEXT_OVERRIDE:-$DEFAULT_K3S_CONTEXT}"
    KUBECONFIG_PATH="''${PWD}/.kube/k3s.yaml"

    if ! command -v systemctl >/dev/null 2>&1; then
      echo "systemctl not found. This script expects k3s to run as a systemd service on the host."
      exit 1
    fi

    if ! systemctl is-active --quiet k3s; then
      echo "k3s systemd service is not active."
      echo "Enable it on the host (e.g. services.k3s.enable = true in your NixOS configuration) and rebuild."
      exit 1
    fi

    echo "Using host-managed k3s cluster (context: ''${CONTEXT_NAME})"
    echo "Importing kubeconfig from: ''${KUBECONFIG_SRC}"
    mkdir -p "''${PWD}/.kube"

    if [ -r "''${KUBECONFIG_SRC}" ]; then
      install -m 600 "''${KUBECONFIG_SRC}" "''${KUBECONFIG_PATH}"
    else
      echo "Source kubeconfig is not readable by the current user; using sudo to copy it."
      echo "Tip: set services.k3s.extraFlags = [ \"--write-kubeconfig-mode=644\" ]; to avoid sudo."
      sudo install -m 600 -o "$(id -u)" -g "$(id -g)" "''${KUBECONFIG_SRC}" "''${KUBECONFIG_PATH}"
    fi

    echo "Waiting for kube-apiserver to be ready"
    KUBECONFIG="''${KUBECONFIG_PATH}" kubectl --context "''${CONTEXT_NAME}" wait --for=condition=Ready nodes --all --timeout=180s
    echo "Cluster ready. KUBECONFIG=''${KUBECONFIG_PATH}, context=''${CONTEXT_NAME}"
  '';

  scripts.cluster-delete.exec = ''
    set -euo pipefail

    KUBECONFIG_PATH="''${PWD}/.kube/k3s.yaml"
    echo "Removing local kubeconfig: ''${KUBECONFIG_PATH}"
    rm -f "''${KUBECONFIG_PATH}"
    echo "Note: the k3s cluster itself is managed by systemd on the host."
    echo "To stop the cluster: sudo systemctl stop k3s"
    echo "To fully remove it: disable services.k3s in your NixOS configuration and rebuild."
  '';

  scripts.argocd-bootstrap.exec = ''
    set -euo pipefail

    CONTEXT_NAME="''${K3S_CONTEXT_OVERRIDE:-$DEFAULT_K3S_CONTEXT}"
    KUBECONFIG_PATH="/home/dom/.kube/config-k3s"

    if [ ! -f "''${KUBECONFIG_PATH}" ]; then
      echo "Missing kubeconfig: ''${KUBECONFIG_PATH}. Run cluster-create first."
      exit 1
    fi

    echo "Bootstrapping Argo CD into context: ''${CONTEXT_NAME}"
    KUBECONFIG="''${KUBECONFIG_PATH}" kubectl --context "''${CONTEXT_NAME}" create namespace "''${ARGOCD_NAMESPACE}" --dry-run=client -o yaml | KUBECONFIG="''${KUBECONFIG_PATH}" kubectl --context "''${CONTEXT_NAME}" apply -f -

    echo "Installing Argo CD (helm) as initial bootstrap"
    # Use the same umbrella chart that Argo CD will self-manage later, so the
    # bootstrap state matches the steady state -- no separate bootstrap values file.
    helm dependency build ./helm/in-cluster/argocd/argocd >/dev/null
    helm upgrade --install argocd ./helm/in-cluster/argocd/argocd \
      --kube-context "''${CONTEXT_NAME}" \
      --namespace "''${ARGOCD_NAMESPACE}" \
      --create-namespace

    echo "Applying root application (Argo manages itself + everything else)"
    KUBECONFIG="''${KUBECONFIG_PATH}" kubectl --context "''${CONTEXT_NAME}" apply -f ./bootstrap/root-application.yaml

    echo "Done. You can port-forward Argo CD with: devenv shell -c 'argocd-port-forward'"
  '';

  scripts.argocd-port-forward.exec = ''
    set -euo pipefail

    CONTEXT_NAME="''${K3S_CONTEXT_OVERRIDE:-$DEFAULT_K3S_CONTEXT}"
    KUBECONFIG_PATH="''${PWD}/.kube/k3s.yaml"

    echo "Port-forwarding Argo CD server to http://''${ARGOCD_SERVER_LOCAL}"
    KUBECONFIG="''${KUBECONFIG_PATH}" kubectl --context "''${CONTEXT_NAME}" -n "''${ARGOCD_NAMESPACE}" port-forward svc/argocd-server 8080:443
  '';

  scripts.argocd-admin-password.exec = ''
    set -euo pipefail

    CONTEXT_NAME="''${K3S_CONTEXT_OVERRIDE:-$DEFAULT_K3S_CONTEXT}"
    KUBECONFIG_PATH="''${PWD}/.kube/k3s.yaml"

    KUBECONFIG="''${KUBECONFIG_PATH}" kubectl --context "''${CONTEXT_NAME}" -n "''${ARGOCD_NAMESPACE}" get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d
    echo
  '';

  enterShell = ''
    git --version
    kubectl version --client=true --output=yaml | head -n 5 || true
    helm version || true
    systemctl is-active --quiet k3s && echo "k3s: active" || echo "k3s: inactive"
  '';
}
