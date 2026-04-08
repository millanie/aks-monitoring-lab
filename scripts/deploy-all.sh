#!/usr/bin/env bash
set -euo pipefail

###############################################################################
# deploy-all.sh
# 샘플 앱, Prometheus 알림 규칙, Azure Monitor 알림 규칙, Grafana 대시보드 배포
###############################################################################

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# Load environment if available
if [[ -f /tmp/aks-monitoring-env.sh ]]; then
  source /tmp/aks-monitoring-env.sh
  echo "✅ Loaded environment from /tmp/aks-monitoring-env.sh"
else
  echo "⚠️  /tmp/aks-monitoring-env.sh not found."
  echo "   Run infra/setup-monitoring-infra.sh first, or set these variables:"
  echo "   RESOURCE_GROUP, ACR_NAME, ACR_LOGIN_SERVER, AMW_ID, AMW_NAME, LAW_ID, ACTION_GROUP_ID, GRAFANA_NAME"
  exit 1
fi

# Get AKS cluster resource ID
AKS_CLUSTER_ID=$(az aks show \
  --name "$AKS_CLUSTER_NAME" \
  --resource-group "$RESOURCE_GROUP" \
  --query id -o tsv)

echo ""
echo "=============================================="
echo " Deploying Monitoring Demo Resources"
echo "=============================================="

# ─── 1. Build & Push Sample App Image ──────────────────────────────────────
echo ""
echo "▶ [1/5] Building sample app image with ACR..."
az acr build \
  --registry "$ACR_NAME" \
  --resource-group "$RESOURCE_GROUP" \
  --image sample-app:latest \
  "$ROOT_DIR/app/" \
  --output none

echo "  ✅ Image built: $ACR_LOGIN_SERVER/sample-app:latest"

# ─── 2. Deploy Sample Application ──────────────────────────────────────────
echo ""
echo "▶ [2/5] Deploying sample application to AKS..."
sed "s|ACR_LOGIN_SERVER_PLACEHOLDER|$ACR_LOGIN_SERVER|g" "$ROOT_DIR/app/deployment.yaml" | kubectl apply -f -
kubectl rollout status deployment/sample-app -n demo-app --timeout=180s
echo "  ✅ Sample app deployed."

# ─── 2. Deploy Prometheus Alert Rules ──────────────────────────────────────
echo ""
echo "▶ [3/5] Deploying Prometheus Alert Rule Groups..."
az deployment group create \
  --resource-group "$RESOURCE_GROUP" \
  --template-file "$ROOT_DIR/monitoring/prometheus-rules/aks-prometheus-rules.json" \
  --parameters \
    azureMonitorWorkspaceResourceId="$AMW_ID" \
    clusterName="$AKS_CLUSTER_NAME" \
    actionGroupId="$ACTION_GROUP_ID" \
  --name "prometheus-rules-$(date +%Y%m%d%H%M%S)" \
  --output none

echo "  ✅ Prometheus Rule Groups deployed:"
echo "     - aks-node-alerts (CPU, Memory, Disk, NotReady)"
echo "     - aks-pod-alerts (CrashLoop, OOM, Pending, CPU Throttle)"
echo "     - aks-app-alerts (HTTP Errors, Latency, Business Metrics)"

# ─── 3. Deploy Azure Monitor Alert Rules ───────────────────────────────────
echo ""
echo "▶ [4/5] Deploying Azure Monitor Alert Rules..."
az deployment group create \
  --resource-group "$RESOURCE_GROUP" \
  --template-file "$ROOT_DIR/monitoring/azure-alerts/azure-monitor-alerts.json" \
  --parameters \
    logAnalyticsWorkspaceId="$LAW_ID" \
    aksClusterResourceId="$AKS_CLUSTER_ID" \
    actionGroupId="$ACTION_GROUP_ID" \
  --name "azure-alerts-$(date +%Y%m%d%H%M%S)" \
  --output none

echo "  ✅ Azure Monitor Alert Rules deployed:"
echo "     - alert-container-restart-anomaly"
echo "     - alert-oom-killed-pods"
echo "     - alert-failed-pod-scheduling"
echo "     - alert-node-cpu-high"
echo "     - alert-aks-cluster-health"

# ─── 4. Import Grafana Dashboard ──────────────────────────────────────────
echo ""
echo "▶ [5/5] Importing Grafana Dashboard..."
az grafana dashboard create \
  --name "$GRAFANA_NAME" \
  --resource-group "$RESOURCE_GROUP" \
  --title "AKS Monitoring Demo - 클러스터 개요" \
  --folder "AKS Monitoring Demo" \
  --definition @"$ROOT_DIR/monitoring/grafana-dashboards/aks-overview.json" \
  --output none 2>/dev/null || \
az grafana dashboard import \
  --name "$GRAFANA_NAME" \
  --resource-group "$RESOURCE_GROUP" \
  --definition @"$ROOT_DIR/monitoring/grafana-dashboards/aks-overview.json" \
  --output none

echo "  ✅ Grafana dashboard imported."

# ─── Summary ───────────────────────────────────────────────────────────────
echo ""
echo "=============================================="
echo " ✅ All Monitoring Resources Deployed"
echo "=============================================="
echo ""
echo " Prometheus Rule Groups:"
az rest --method get \
  --uri "https://management.azure.com/subscriptions/$(az account show --query id -o tsv)/resourceGroups/$RESOURCE_GROUP/providers/Microsoft.AlertsManagement/prometheusRuleGroups?api-version=2023-03-01" \
  --query 'value[].name' -o tsv 2>/dev/null | sed 's/^/   - /' || echo "   (query skipped)"

echo ""
echo " Azure Monitor Alert Rules:"
az monitor scheduled-query list \
  --resource-group "$RESOURCE_GROUP" \
  --query '[].{Name:name, Severity:severity, Enabled:enabled}' \
  --output table 2>/dev/null || echo "   (query skipped)"

echo ""
echo " Grafana: $GRAFANA_URL"
echo ""
echo " Next: Run ./scripts/trigger-alerts.sh to test alert scenarios"
