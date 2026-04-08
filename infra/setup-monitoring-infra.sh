#!/usr/bin/env bash
set -euo pipefail

###############################################################################
# AKS Monitoring Infrastructure Setup
# - Azure Container Registry (ACR)
# - Azure Monitor Workspace (Managed Prometheus)
# - Azure Managed Grafana
# - AKS Cluster with monitoring enabled + ACR attached
# - Action Group for alert notifications
###############################################################################

# ─── Configuration ──────────────────────────────────────────────────────────
RESOURCE_GROUP="${RESOURCE_GROUP:-rg-aks-monitoring-demo}"
LOCATION="${LOCATION:-koreacentral}"
AKS_CLUSTER_NAME="${AKS_CLUSTER_NAME:-aks-monitoring-demo}"
ACR_NAME="${ACR_NAME:-acraksmonitoring$RANDOM}"
AMW_NAME="${AMW_NAME:-amw-monitoring-demo}"
GRAFANA_NAME="${GRAFANA_NAME:-grafana-monitoring-demo}"
LOG_ANALYTICS_NAME="${LOG_ANALYTICS_NAME:-law-monitoring-demo}"
ACTION_GROUP_NAME="${ACTION_GROUP_NAME:-ag-aks-monitoring}"
ALERT_EMAIL="${ALERT_EMAIL:-admin@example.com}"
NODE_COUNT="${NODE_COUNT:-3}"
K8S_VERSION="${K8S_VERSION:-1.34}"

echo "=============================================="
echo " AKS Monitoring Demo - Infrastructure Setup"
echo "=============================================="
echo "Resource Group : $RESOURCE_GROUP"
echo "Location       : $LOCATION"
echo "AKS Cluster    : $AKS_CLUSTER_NAME"
echo "ACR            : $ACR_NAME"
echo "AMW            : $AMW_NAME"
echo "Grafana        : $GRAFANA_NAME"
echo ""

# ─── 1. Resource Group ─────────────────────────────────────────────────────
echo "▶ [1/8] Creating Resource Group..."
az group create \
  --name "$RESOURCE_GROUP" \
  --location "$LOCATION" \
  --output none

# ─── 2. Azure Container Registry ──────────────────────────────────────────
echo "▶ [2/8] Creating Azure Container Registry..."
az acr create \
  --name "$ACR_NAME" \
  --resource-group "$RESOURCE_GROUP" \
  --location "$LOCATION" \
  --sku Basic \
  --output none

ACR_LOGIN_SERVER=$(az acr show \
  --name "$ACR_NAME" \
  --resource-group "$RESOURCE_GROUP" \
  --query loginServer -o tsv)

echo "  ACR Login Server: $ACR_LOGIN_SERVER"

# ─── 3. Log Analytics Workspace ────────────────────────────────────────────
echo "▶ [3/8] Creating Log Analytics Workspace..."
az monitor log-analytics workspace create \
  --resource-group "$RESOURCE_GROUP" \
  --workspace-name "$LOG_ANALYTICS_NAME" \
  --location "$LOCATION" \
  --output none

LAW_ID=$(az monitor log-analytics workspace show \
  --resource-group "$RESOURCE_GROUP" \
  --workspace-name "$LOG_ANALYTICS_NAME" \
  --query id -o tsv)

echo "  Log Analytics Workspace ID: $LAW_ID"

# ─── 3. Azure Monitor Workspace (Managed Prometheus) ──────────────────────
echo "▶ [4/8] Creating Azure Monitor Workspace (Managed Prometheus)..."
az monitor account create \
  --name "$AMW_NAME" \
  --resource-group "$RESOURCE_GROUP" \
  --location "$LOCATION" \
  --output none

AMW_ID=$(az monitor account show \
  --name "$AMW_NAME" \
  --resource-group "$RESOURCE_GROUP" \
  --query id -o tsv)

echo "  Azure Monitor Workspace ID: $AMW_ID"

# ─── 4. Azure Managed Grafana ─────────────────────────────────────────────
echo "▶ [5/8] Creating Azure Managed Grafana..."
az grafana create \
  --name "$GRAFANA_NAME" \
  --resource-group "$RESOURCE_GROUP" \
  --location "$LOCATION" \
  --output none

GRAFANA_ID=$(az grafana show \
  --name "$GRAFANA_NAME" \
  --resource-group "$RESOURCE_GROUP" \
  --query id -o tsv)

echo "  Grafana ID: $GRAFANA_ID"

# Link Azure Monitor Workspace to Grafana as Prometheus datasource
echo "  Linking AMW to Grafana..."
az grafana data-source create \
  --name "$GRAFANA_NAME" \
  --resource-group "$RESOURCE_GROUP" \
  --definition '{
    "name": "Azure Managed Prometheus",
    "type": "prometheus",
    "access": "proxy",
    "url": "'"$(az monitor account show --name "$AMW_NAME" --resource-group "$RESOURCE_GROUP" --query "metrics.prometheusQueryEndpoint" -o tsv)"'",
    "jsonData": {
      "azureAuthentication": {
        "enabled": true
      },
      "httpMethod": "POST"
    }
  }' --output none 2>/dev/null || echo "  (Datasource may be auto-linked via AKS integration)"

# ─── 5. AKS Cluster with Monitoring ───────────────────────────────────────
echo "▶ [6/8] Creating AKS Cluster with Monitoring enabled..."
az aks create \
  --name "$AKS_CLUSTER_NAME" \
  --resource-group "$RESOURCE_GROUP" \
  --location "$LOCATION" \
  --node-count "$NODE_COUNT" \
  --zones 2 3 \
  --network-plugin azure \
  --network-plugin-mode overlay \
  --kubernetes-version "$K8S_VERSION" \
  --generate-ssh-keys \
  --enable-managed-identity \
  --enable-oidc-issuer \
  --enable-azure-monitor-metrics \
  --azure-monitor-workspace-resource-id "$AMW_ID" \
  --enable-addons monitoring \
  --workspace-resource-id "$LAW_ID" \
  --grafana-resource-id "$GRAFANA_ID" \
  --attach-acr "$ACR_NAME" \
  --output none

echo "  AKS Cluster created with Managed Prometheus, Grafana & ACR linked."

# Get credentials
az aks get-credentials \
  --name "$AKS_CLUSTER_NAME" \
  --resource-group "$RESOURCE_GROUP" \
  --overwrite-existing

# ─── 6. Action Group ──────────────────────────────────────────────────────
echo "▶ [7/8] Creating Action Group for Alerts..."
az monitor action-group create \
  --name "$ACTION_GROUP_NAME" \
  --resource-group "$RESOURCE_GROUP" \
  --short-name "AKSAlerts" \
  --action email admin-email "$ALERT_EMAIL" \
  --output none

ACTION_GROUP_ID=$(az monitor action-group show \
  --name "$ACTION_GROUP_NAME" \
  --resource-group "$RESOURCE_GROUP" \
  --query id -o tsv)

echo "  Action Group ID: $ACTION_GROUP_ID"

# ─── 7. Verify ────────────────────────────────────────────────────────────
echo "▶ [8/8] Verifying deployment..."

echo ""
echo "  Checking ama-metrics pods in kube-system..."
kubectl get pods -n kube-system -l rsName=ama-metrics --no-headers 2>/dev/null || echo "  (Pods may take a few minutes to appear)"

echo ""
GRAFANA_URL=$(az grafana show --name "$GRAFANA_NAME" --resource-group "$RESOURCE_GROUP" --query "properties.endpoint" -o tsv)

echo "=============================================="
echo " ✅ Infrastructure Setup Complete"
echo "=============================================="
echo ""
echo " Grafana URL     : $GRAFANA_URL"
echo " AKS Cluster     : $AKS_CLUSTER_NAME"
echo " Monitor Workspace: $AMW_NAME"
echo " Action Group    : $ACTION_GROUP_NAME"
echo ""
echo " Next steps:"
echo "   1. Run ./scripts/deploy-all.sh to deploy sample app & alert rules"
echo "   2. Run ./scripts/trigger-alerts.sh to test alerts"
echo ""

# Export resource IDs for downstream scripts
cat > /tmp/aks-monitoring-env.sh <<EOF
export RESOURCE_GROUP="$RESOURCE_GROUP"
export AKS_CLUSTER_NAME="$AKS_CLUSTER_NAME"
export ACR_NAME="$ACR_NAME"
export ACR_LOGIN_SERVER="$ACR_LOGIN_SERVER"
export AMW_ID="$AMW_ID"
export AMW_NAME="$AMW_NAME"
export GRAFANA_ID="$GRAFANA_ID"
export GRAFANA_NAME="$GRAFANA_NAME"
export LAW_ID="$LAW_ID"
export ACTION_GROUP_ID="$ACTION_GROUP_ID"
export GRAFANA_URL="$GRAFANA_URL"
EOF

echo " Environment exported to /tmp/aks-monitoring-env.sh"
echo " Run: source /tmp/aks-monitoring-env.sh"
