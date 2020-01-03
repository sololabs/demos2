#!/usr/bin/env bash
#
# Starts up a Kubernetes cluster based on settings in working_environment.sh

# Expects
# brew install kubernetes-cli helm

# Optional
# brew install kind k3d minikube skaffold openshift-cli; brew cask install minishift

GLOO_NAMESPACE="${GLOO_NAMESPACE:-gloo-system}"

K8S_VERSION='latest'

# Get directory this script is located in to access script local files
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"

source "${SCRIPT_DIR}/common_scripts.sh"
source "${SCRIPT_DIR}/working_environment.sh"

# Will exit script if we would use an uninitialised variable (nounset) or when a
# simple command (not a control structure) fails (errexit)
set -eu
trap print_error ERR

K8S_TOOL="${K8S_TOOL:-kind}" # kind, minikube, minishift, gke, eks, custom

case "${K8S_TOOL}" in
  kind)
    DEMO_CLUSTER_NAME="${DEMO_CLUSTER_NAME:-kind}"

    # Delete existing cluster, i.e. restart cluster
    if [[ "$(kind get clusters)" == *"${DEMO_CLUSTER_NAME}"* ]]; then
      kind delete cluster --name="${DEMO_CLUSTER_NAME}"
    fi

    # Setup local Kubernetes cluster using kind (Kubernetes IN Docker) with
    # control plane and worker nodes
    if [[ "${K8S_VERSION}" == 'latest' ]]; then
      kind create cluster --name="${DEMO_CLUSTER_NAME}" \
        --wait='60s'
    else
      kind create cluster --name="${DEMO_CLUSTER_NAME}" \
        --image=kindest/node:"${K8S_VERSION}" \
        --wait='60s'
    fi

    # Tell skaffold how to connect to local Kubernetes cluster running in
    # non-default profile name
    skaffold config set --kube-context="$(kubectl config current-context)" \
      local-cluster true

    ;; # end kind

  minikube)
    DEMO_CLUSTER_NAME="${DEMO_CLUSTER_NAME:-minikube}"

    # for Mac (can also use Virtual Box)
    # brew install minikube
    # minikube config set vm-driver hyperkit

    # minikube config set cpus 4
    # minikube config set memory 4096

    minikube delete --profile="${DEMO_CLUSTER_NAME}" && true # Ignore errors

    if [[ "${K8S_VERSION}" == 'latest' ]]; then
      minikube start --profile="${DEMO_CLUSTER_NAME}" \
        --cpus='4' \
        --memory='8192mb' \
        --wait='true'
    else
      minikube start --profile="${DEMO_CLUSTER_NAME}" \
        --cpus='4' \
        --memory='8192mb' \
        --wait='true' \
        --kubernetes-version="${K8S_VERSION}"
    fi

    source <(minikube docker-env --profile="${DEMO_CLUSTER_NAME}")

    # Tell skaffold how to connect to local Kubernetes cluster running in
    # non-default profile name
    skaffold config set --kube-context="$(kubectl config current-context)" \
      local-cluster true

    ;; # end minikube

  k3d)
    DEMO_CLUSTER_NAME="${DEMO_CLUSTER_NAME:-k3s-default}"

    # Delete existing cluster, i.e. restart cluster
    if [[ "$(k3d list)" == *"${DEMO_CLUSTER_NAME}"* ]]; then
      k3d delete --name="${DEMO_CLUSTER_NAME}"
    fi

    # Setup local Kubernetes cluster using k3d
    if [[ "${K8S_VERSION}" == 'latest' ]]; then
      k3d create --name="${DEMO_CLUSTER_NAME}" \
        --wait='60'
    else
      k3d create --name="${DEMO_CLUSTER_NAME}" \
        --image="docker.io/rancher/k3s:${K8S_VERSION}" \
        --wait='60'
    fi

    KUBECONFIG=$(k3d get-kubeconfig --name="${DEMO_CLUSTER_NAME}")
    export KUBECONFIG

    # Tell skaffold how to connect to local Kubernetes cluster running in
    # non-default profile name
    skaffold config set --kube-context="$(kubectl config current-context)" \
      local-cluster true

    ;; # end k3d

  minishift)
    DEMO_CLUSTER_NAME="${DEMO_CLUSTER_NAME:-minishift}"

    # for Mac (can also use Virtual Box)
    # brew install hyperkit; brew cask install minishift
    # minishift config set vm-driver hyperkit

    # minishift config set cpus 4
    # minishift config set memory 4096

    minishift delete --profile "${DEMO_CLUSTER_NAME}" --force && true # Ignore errors
    minishift start --profile "${DEMO_CLUSTER_NAME}"

    minishift addons install --defaults
    minishift addons apply admin-user

    # Login as administrator
    oc login --username='system:admin'

    # Add security context constraint to users or a service account
    oc --namespace "${GLOO_NAMESPACE}" adm policy add-scc-to-user anyuid \
      --serviceaccount='glooe-prometheus-server'
    oc --namespace "${GLOO_NAMESPACE}" adm policy add-scc-to-user anyuid \
      --serviceaccount='glooe-prometheus-kube-state-metrics'
    oc --namespace "${GLOO_NAMESPACE}" adm policy add-scc-to-user anyuid \
      --serviceaccount='glooe-grafana'
    oc --namespace "${GLOO_NAMESPACE}" adm policy add-scc-to-user anyuid \
      --serviceaccount='default'

    source <(minishift docker-env --profile "${DEMO_CLUSTER_NAME}")

    # Tell skaffold how to connect to local Kubernetes cluster running in
    # non-default profile name
    skaffold config set --kube-context="$(kubectl config current-context)" \
      local-cluster true

    ;; # end minishift

  gke)
    DEMO_CLUSTER_NAME="$(whoami)-${DEMO_CLUSTER_NAME:-gke-gloo}"

    gcloud container clusters delete "${DEMO_CLUSTER_NAME}" --quiet && true # Ignore errors
    gcloud beta container clusters create "${DEMO_CLUSTER_NAME}" \
      --release-channel='regular' \
      --machine-type='n1-standard-4' \
      --num-nodes='3' \
      --no-enable-basic-auth \
      --enable-ip-alias \
      --enable-stackdriver-kubernetes \
      --addons='HorizontalPodAutoscaling,HttpLoadBalancing' \
      --metadata='disable-legacy-endpoints=true' \
      --labels="creator=$(whoami)"
      # --preemptible \
      # --max-pods-per-node='30' \

    gcloud container clusters get-credentials "${DEMO_CLUSTER_NAME}"

    kubectl create clusterrolebinding cluster-admin-binding \
      --clusterrole='cluster-admin' \
      --user="$(gcloud config get-value account)"

    # Helm requires metrics API to be available, and GKE can be slow to start that
    wait_for_k8s_metrics_server

    ;; # end gke

  eks)
    DEMO_CLUSTER_NAME="$(whoami)-${DEMO_CLUSTER_NAME:-eks-gloo}"

    eksctl delete cluster --name="${DEMO_CLUSTER_NAME}" && true # Ignore errors
    eksctl create cluster \
      --name="${DEMO_CLUSTER_NAME}" \
      --tags="creator=$(whoami)" \
      --nodes='3'
      # --region='us-east-2' \
      # --version='1.14'

    ;; # end eks

  # aks)
  #   DEMO_CLUSTER_NAME="$(whoami)-${DEMO_CLUSTER_NAME:-aks-gloo}"
  #   RESOURCE_GROUP_NAME="${DEMO_CLUSTER_NAME}-resource-group"

  #   az group create \
  #     --name "${RESOURCE_GROUP_NAME}" \
  #     --location eastus

  #   az aks delete --name "${DEMO_CLUSTER_NAME}" --resource-group "${RESOURCE_GROUP_NAME}" && true # Ignore errors
  #   az aks create \
  #     --name "${DEMO_CLUSTER_NAME}" \
  #     --resource-group "${RESOURCE_GROUP_NAME}" \
  #     --node-count '1' \
  #     --enable-addons monitoring \
  #     --generate-ssh-keys

  #   # The --admin option logs us in with cluster admin rights needed to install Gloo
  #   az aks get-credentials \
  #     --name "${DEMO_CLUSTER_NAME}" \
  #     --resource-group "${RESOURCE_GROUP_NAME}" \
  #     --admin

  #   ;; # end aks

  custom) ;;

esac
