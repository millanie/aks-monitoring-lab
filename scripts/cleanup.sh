#!/usr/bin/env bash
set -euo pipefail

###############################################################################
# cleanup.sh - 전체 데모 리소스 정리
###############################################################################

RESOURCE_GROUP="${RESOURCE_GROUP:-rg-aks-monitoring-demo}"

echo "=============================================="
echo " AKS Monitoring Demo - Resource Cleanup"
echo "=============================================="
echo ""
echo "⚠️  This will DELETE the entire resource group: $RESOURCE_GROUP"
echo "    and ALL resources within it!"
echo ""

read -p "Are you sure? Type the resource group name to confirm: " confirm

if [[ "$confirm" != "$RESOURCE_GROUP" ]]; then
  echo "Cancelled."
  exit 0
fi

echo ""
echo "▶ Cleaning up Kubernetes test resources first..."
kubectl delete job cpu-stress-test memory-bomb -n demo-app --ignore-not-found=true 2>/dev/null || true
kubectl delete deployment crashloop-demo -n demo-app --ignore-not-found=true 2>/dev/null || true
kubectl delete pod load-gen -n demo-app --ignore-not-found=true 2>/dev/null || true

echo ""
echo "▶ Deleting resource group: $RESOURCE_GROUP"
echo "  (This may take several minutes...)"
az group delete \
  --name "$RESOURCE_GROUP" \
  --yes \
  --no-wait

echo ""
echo "✅ Resource group deletion initiated (running in background)."
echo "   Check status: az group show --name $RESOURCE_GROUP --query properties.provisioningState -o tsv"
echo ""

# Cleanup environment file
rm -f /tmp/aks-monitoring-env.sh
echo "✅ Removed /tmp/aks-monitoring-env.sh"
