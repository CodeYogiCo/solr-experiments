#!/bin/bash
# Universal provision + deploy entry point.
# Picks the right Terraform module, applies it, reads the standard outputs,
# then runs deploy-to-vm.sh against each node.  Same interface for every cloud.
#
# Usage:
#   ./infra/provision.sh <cloud> [action] [options]
#
# Clouds:     aws | gcp | azure
# Actions:    apply (default) | plan | destroy | deploy-only
#
# Options:
#   --tag <image-tag>   Image tag to deploy (default: latest)
#   --nodes <1,2>       Solr nodes to start (default: 1,2)
#   --ssh-key <path>    SSH private key (default: ~/.ssh/id_rsa)
#   --ssh-user <user>   SSH user (default: ubuntu / azureuser)
#   --install           Pass --install to deploy-to-vm.sh (first run)
#
# Examples:
#   First deploy on GCP:
#     ./infra/provision.sh gcp apply --tag latest --nodes 1,2 --install
#
#   Add a node on AWS:
#     ./infra/provision.sh aws deploy-only --nodes 3
#
#   Roll out a new image on Azure:
#     ./infra/provision.sh azure deploy-only --tag v1.2.3 --update
#
#   Destroy all GCP resources:
#     ./infra/provision.sh gcp destroy
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

CLOUD="${1:-}"
ACTION="${2:-apply}"
shift 2 || true

IMAGE_TAG="latest"
NODES="1,2"
SSH_KEY="$HOME/.ssh/id_rsa"
SSH_USER=""
INSTALL_FLAG=""
UPDATE_FLAG=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --tag)     IMAGE_TAG="$2"; shift 2 ;;
    --nodes)   NODES="$2";     shift 2 ;;
    --ssh-key) SSH_KEY="$2";   shift 2 ;;
    --ssh-user)SSH_USER="$2";  shift 2 ;;
    --install) INSTALL_FLAG="--install"; shift ;;
    --update)  UPDATE_FLAG="--update";   shift ;;
    *) echo "Unknown option: $1"; exit 1 ;;
  esac
done

# ── Validate cloud ─────────────────────────────────────────────────────────────
case "${CLOUD}" in
  aws)   TF_DIR="${SCRIPT_DIR}/terraform/aws-ec2"; SSH_USER="${SSH_USER:-ec2-user}" ;;
  gcp)   TF_DIR="${SCRIPT_DIR}/terraform/gcp";    SSH_USER="${SSH_USER:-ubuntu}" ;;
  azure) TF_DIR="${SCRIPT_DIR}/terraform/azure";  SSH_USER="${SSH_USER:-azureuser}" ;;
  *)
    echo "Usage: $0 <aws|gcp|azure> [apply|plan|destroy|deploy-only] [options]"
    echo ""
    echo "Clouds:"
    echo "  aws    – AWS EC2 + NLB + EFS (us-east-1 default)"
    echo "  gcp    – GCP Compute Engine + ILB + Filestore (us-central1 default)"
    echo "  azure  – Azure VMs + LB + Azure Files (eastus default)"
    echo ""
    echo "First-time setup for each cloud:"
    echo "  aws:   aws configure  (or set AWS_ACCESS_KEY_ID / AWS_SECRET_ACCESS_KEY)"
    echo "  gcp:   gcloud auth application-default login"
    echo "  azure: az login"
    exit 1
    ;;
esac

cd "${TF_DIR}"

# ── Terraform actions ──────────────────────────────────────────────────────────
if [ "${ACTION}" != "deploy-only" ]; then
  echo "═══ Terraform ${ACTION} (${CLOUD}) ═══"
  terraform init -upgrade -input=false

  case "${ACTION}" in
    plan)    terraform plan; exit 0 ;;
    destroy)
      echo "WARNING: This will DESTROY all ${CLOUD} infrastructure."
      read -rp "Type 'yes' to confirm: " ans
      [ "${ans}" = "yes" ] || exit 1
      terraform destroy -auto-approve
      exit 0
      ;;
    apply)
      terraform apply -auto-approve -var="image_tag=${IMAGE_TAG}"
      ;;
  esac
fi

# ── Read standard outputs ──────────────────────────────────────────────────────
echo ""
echo "═══ Reading Terraform outputs ═══"
SOLR_NODE_IPS=$(terraform output -json solr_node_ips | python3 -c "
import json, sys; ips = json.load(sys.stdin); print(' '.join(ips))")
REDIS_IP=$(terraform output -raw redis_ip 2>/dev/null || echo "")
ZK_LB=$(terraform output -raw zk_lb_address 2>/dev/null || echo "")
SOLR_URL=$(terraform output -raw solr_lb_url 2>/dev/null || echo "")

echo "  Solr+ZK nodes : ${SOLR_NODE_IPS}"
echo "  Redis         : ${REDIS_IP}"
echo "  ZK LB address : ${ZK_LB}"
echo "  Solr URL      : ${SOLR_URL}"

# ── Deploy to each VM using the universal script ───────────────────────────────
echo ""
echo "═══ Deploying to ${CLOUD} nodes ═══"
DEPLOY_SCRIPT="${REPO_ROOT}/scripts/deploy-to-vm.sh"

for IP in ${SOLR_NODE_IPS}; do
  echo ""
  echo "── Deploying to ${IP} ──"
  bash "${DEPLOY_SCRIPT}" "${IP}" \
    --user    "${SSH_USER}" \
    --key     "${SSH_KEY}" \
    --tag     "${IMAGE_TAG}" \
    --nodes   "${NODES}" \
    ${INSTALL_FLAG} \
    ${UPDATE_FLAG}
done

echo ""
echo "═══ Deployment complete ═══"
echo ""
echo "  Solr UI:          ${SOLR_URL}"
echo "  ZooKeeper LB:     ${ZK_LB}"
echo ""
echo "Next steps:"
echo "  Add a Solr node:  ssh ${SSH_USER}@<node-ip> 'cd /opt/solr-stack && make node-add NODE=3'"
echo "  Cluster status:   ssh ${SSH_USER}@<node-ip> 'cd /opt/solr-stack && make cluster-status'"
echo "  Load data:        SOLR_URL=${SOLR_URL} make data-load"
