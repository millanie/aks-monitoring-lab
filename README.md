# AKS Monitoring Demo

> **Azure Managed Prometheus + Managed Grafana + Azure Monitor** 를 활용한 AKS 중앙집중식 모니터링 & 알림 데모

[![Azure](https://img.shields.io/badge/Azure-Managed_Prometheus-0078D4?logo=microsoftazure)](https://learn.microsoft.com/azure/azure-monitor/essentials/prometheus-metrics-overview)
[![Grafana](https://img.shields.io/badge/Grafana-Managed-F46800?logo=grafana)](https://learn.microsoft.com/azure/managed-grafana/overview)
[![Kubernetes](https://img.shields.io/badge/Kubernetes-AKS-326CE5?logo=kubernetes)](https://learn.microsoft.com/azure/aks/)

---

## 📌 소개

AKS 클러스터에서 수집되는 메트릭과 로그를 **Azure Managed Prometheus** 로 수집하고,
**Azure Managed Grafana** 대시보드로 시각화하며, **Azure Monitor Alert** 로 중앙에서 알림을 관리하는
End-to-End 모니터링 파이프라인 데모입니다.

**5가지 장애 시나리오** 를 재현하여 알림이 정상적으로 발생하고 전달되는지 검증할 수 있습니다.

---

## 🏗️ 아키텍처

```
┌──────────────────────────────────────────────────────────────────────┐
│                          Azure Monitor                               │
│                                                                      │
│  ┌──────────────────┐  ┌───────────────────┐  ┌──────────────────┐  │
│  │ Prometheus Rule   │  │ Azure Monitor     │  │ Action Group     │  │
│  │ Groups (metrics)  │  │ Alert Rules (log) │  │ (Email / Slack)  │  │
│  └────────┬─────────┘  └────────┬──────────┘  └───────┬──────────┘  │
│           │                     │                      │             │
│  ┌────────▼─────────────────────▼──────────────────────▼──────────┐  │
│  │              Azure Monitor Workspace (AMW)                     │  │
│  │              = Managed Prometheus Backend                      │  │
│  └──────────────────────────┬─────────────────────────────────────┘  │
│                             │                                        │
│  ┌──────────────────────────▼─────────────────────────────────────┐  │
│  │              Azure Managed Grafana                             │  │
│  │  • Prometheus 데이터소스 자동 연결                               │  │
│  │  • 사전 구성 + 커스텀 대시보드                                   │  │
│  └────────────────────────────────────────────────────────────────┘  │
└──────────────────────────────────────────────────────────────────────┘
                              ▲
                              │ metrics scrape (ama-metrics)
┌─────────────────────────────┴────────────────────────────────────────┐
│                          AKS Cluster                                 │
│                                                                      │
│  ┌──────────────┐  ┌────────────────┐  ┌──────────────────────────┐  │
│  │ ama-metrics   │  │ sample-app     │  │ stress-test Jobs         │  │
│  │ (DaemonSet)   │  │ (Deployment)   │  │ CPU / Memory / Error     │  │
│  └──────────────┘  └────────────────┘  └──────────────────────────┘  │
└──────────────────────────────────────────────────────────────────────┘
```

**알림 흐름 요약**:
```
AKS Pod 메트릭 → ama-metrics → Azure Monitor Workspace (Managed Prometheus)
  ├─→ Prometheus Rule Group  ─→ firing ─→ Action Group ─→ Email/Webhook
  └─→ Log Analytics (KQL)   ─→ Azure Monitor Alert     ─→ Action Group ─→ Email/Webhook
```

---

## 📁 디렉토리 구조

```
.
├── README.md                                   ← 이 파일
│
├── infra/                                      🔧 인프라 프로비저닝
│   └── setup-monitoring-infra.sh               # Azure 리소스 생성 (AMW, Grafana, AKS, ActionGroup)
│
├── app/                                        🚀 샘플 애플리케이션
│   ├── app.py                                  # Flask 앱 + Prometheus 커스텀 메트릭 노출
│   ├── Dockerfile                              # 컨테이너 이미지 빌드
│   └── deployment.yaml                         # K8s 매니페스트 (Deployment, Service, PodMonitor, Scrape Config)
│
├── monitoring/                                 📊 모니터링 규칙 & 대시보드
│   ├── prometheus-rules/
│   │   └── aks-prometheus-rules.json           # Prometheus Rule Groups (ARM 템플릿, 3그룹 12규칙)
│   ├── azure-alerts/
│   │   └── azure-monitor-alerts.json           # Azure Monitor Alert Rules (ARM 템플릿, 5규칙)
│   └── grafana-dashboards/
│       └── aks-overview.json                   # Grafana 대시보드 JSON (4섹션: 클러스터/노드/앱/비즈니스)
│
├── demo-scenarios/                             📋 데모 시나리오 상세 가이드
│   └── scenarios.md                            # 5개 시나리오별 실행 방법 및 확인 포인트
│
└── scripts/                                    ⚡ 실행 스크립트
    ├── deploy-all.sh                           # 샘플 앱 + 알림 규칙 + 대시보드 일괄 배포
    ├── trigger-alerts.sh                       # 시나리오별 알림 트리거 (인터랙티브)
    └── cleanup.sh                              # 전체 Azure 리소스 삭제
```

### 주요 파일 상세

| 파일 | 설명 |
|------|------|
| **`infra/setup-monitoring-infra.sh`** | Resource Group, Log Analytics Workspace, Azure Monitor Workspace(Managed Prometheus), Managed Grafana, AKS 클러스터(모니터링 연동), Action Group을 순차 생성합니다. 생성된 리소스 ID를 `/tmp/aks-monitoring-env.sh`로 export합니다. |
| **`app/app.py`** | Prometheus `Counter`, `Histogram`, `Gauge` 메트릭을 노출하는 Flask 앱. `/api/order`(주문 처리), `/api/error`(에러 발생), `/api/toggle-errors`(에러 주입 ON/OFF), `/api/memory-leak`(메모리 누수 시뮬레이션) 등의 엔드포인트를 제공합니다. |
| **`app/deployment.yaml`** | Deployment(3 replicas) + Service + PodMonitor + `ama-metrics-prometheus-config` ConfigMap을 포함합니다. `prometheus.io/scrape` 어노테이션과 PodMonitor 두 가지 방식으로 메트릭 수집을 설정합니다. |
| **`monitoring/prometheus-rules/`** | ARM 템플릿으로 3개 Prometheus Rule Group을 배포합니다: **aks-node-alerts** (CPU/Memory/Disk/NotReady), **aks-pod-alerts** (CrashLoop/OOM/Pending/Throttle), **aks-app-alerts** (HTTP에러율/레이턴시/비즈니스메트릭). |
| **`monitoring/azure-alerts/`** | ARM 템플릿으로 5개 Azure Monitor Alert를 배포합니다: Container 재시작 이상, OOMKilled, 스케줄링 실패, 노드 CPU(KQL 기반), API서버 가용성(Metric 기반). |
| **`monitoring/grafana-dashboards/`** | 4개 섹션(클러스터 개요, 노드 리소스, 앱 메트릭, 비즈니스 메트릭)으로 구성된 Grafana 대시보드 JSON. namespace/node 변수 템플릿 포함. |
| **`scripts/trigger-alerts.sh`** | 5가지 시나리오를 대화형으로 실행: `cpu`, `oom`, `errors`, `crashloop`, `node`. `all` 옵션으로 일괄 실행도 가능합니다. |

---

## ✅ 사전 요구 사항

| 도구 | 최소 버전 | 확인 명령 |
|------|----------|----------|
| Azure CLI | 2.60+ | `az version` |
| kubectl | 1.28+ | `kubectl version --client` |
| kubelogin | 0.2+ | `kubelogin --version` |
| Azure 구독 | - | `az account show` |
| Bash | 4.0+ | `bash --version` |

### kubectl / kubelogin 설치

kubectl이 설치되어 있지 않다면 Azure CLI를 통해 설치할 수 있습니다:

```bash
# 시스템 전역 설치 (sudo 권한 필요)
sudo az aks install-cli

# 또는 사용자 로컬 설치 (sudo 없이)
mkdir -p ~/.local/bin
az aks install-cli \
  --install-location ~/.local/bin/kubectl \
  --kubelogin-install-location ~/.local/bin/kubelogin

# PATH에 추가 (영구 적용)
echo 'export PATH="$HOME/.local/bin:$PATH"' >> ~/.bashrc
source ~/.bashrc
```

### Azure CLI 확장 설치

```bash
az extension add --name amg          # Managed Grafana
az extension add --name aks-preview  # AKS preview features
```

### Azure 로그인 및 구독 설정

```bash
az login
az account set --subscription "<구독 ID>"
```

---

## 🚀 실행 순서

### Step 1: 인프라 생성

Azure Monitor Workspace, Managed Grafana, AKS 클러스터, Action Group을 생성합니다.

```bash
# 기본값 사용
./infra/setup-monitoring-infra.sh

# 또는 환경변수로 커스터마이징
RESOURCE_GROUP=my-rg \
LOCATION=koreacentral \
ALERT_EMAIL=myteam@company.com \
./infra/setup-monitoring-infra.sh
```

| 환경변수 | 기본값 | 설명 |
|---------|-------|------|
| `RESOURCE_GROUP` | `rg-aks-monitoring-demo` | Azure Resource Group 이름 |
| `LOCATION` | `koreacentral` | Azure 리전 |
| `AKS_CLUSTER_NAME` | `aks-monitoring-demo` | AKS 클러스터 이름 |
| `AMW_NAME` | `amw-monitoring-demo` | Azure Monitor Workspace 이름 |
| `GRAFANA_NAME` | `grafana-monitoring-demo` | Managed Grafana 이름 |
| `ALERT_EMAIL` | `admin@example.com` | 알림 수신 이메일 |
| `NODE_COUNT` | `3` | AKS 노드 수 |

> ⏱️ 인프라 생성에 약 10-15분 소요됩니다.

### Step 2: 샘플 앱 & 모니터링 규칙 배포

```bash
# 환경변수 로드 (Step 1에서 자동 생성됨)
source /tmp/aks-monitoring-env.sh

# 샘플 앱 + Prometheus Rule Groups + Azure Monitor Alerts + Grafana 대시보드 배포
./scripts/deploy-all.sh
```

배포되는 리소스:
- ✅ `demo-app` namespace에 샘플 앱 (3 replicas)
- ✅ Prometheus Rule Group 3개 (노드/Pod/앱 알림 총 12개)
- ✅ Azure Monitor Alert Rule 5개 (Log 기반 4개 + Metric 기반 1개)
- ✅ Grafana 대시보드 1개

### Step 3: 알림 트리거 테스트

```bash
# 개별 시나리오 실행
./scripts/trigger-alerts.sh cpu        # 시나리오 1: CPU 과부하
./scripts/trigger-alerts.sh oom        # 시나리오 2: OOMKilled
./scripts/trigger-alerts.sh errors     # 시나리오 3: HTTP 5xx 에러 급증
./scripts/trigger-alerts.sh crashloop  # 시나리오 4: CrashLoopBackOff
./scripts/trigger-alerts.sh node       # 시나리오 5: Node Drain (수동 확인)

# 시나리오 1~4 일괄 실행
./scripts/trigger-alerts.sh all

# 현재 상태 확인
./scripts/trigger-alerts.sh status

# 테스트 리소스만 정리 (인프라 유지)
./scripts/trigger-alerts.sh cleanup
```

### Step 4: 결과 확인

| 확인 위치 | URL / 명령 |
|----------|-----------|
| **Grafana 대시보드** | `$GRAFANA_URL` (setup 스크립트 출력 참조) |
| **Azure Monitor Alerts** | Azure Portal → Monitor → Alerts |
| **Prometheus 메트릭 쿼리** | Azure Portal → Monitor → Metrics → Prometheus 선택 |
| **Pod 상태** | `kubectl get pods -n demo-app -w` |
| **K8s 이벤트** | `kubectl get events -n demo-app --sort-by='.lastTimestamp'` |
| **알림 이메일** | Action Group에 설정된 이메일 수신함 확인 |

### Step 5: 정리

```bash
# 전체 Azure 리소스 삭제 (Resource Group 단위)
./scripts/cleanup.sh
```

---

## 🎯 데모 시나리오 요약

| # | 시나리오 | 트리거 | Prometheus Alert | Azure Monitor Alert | 예상 소요 |
|---|---------|-------|-----------------|--------------------|---------:|
| 1 | **CPU 과부하** | `stress --cpu 4` Job | `NodeCPUHighUtilization` `ContainerCPUThrottled` | `alert-node-cpu-high` | ~5분 |
| 2 | **OOMKilled** | 메모리 초과 할당 Job | `PodOOMKilled` | `alert-oom-killed-pods` | ~2분 |
| 3 | **HTTP 5xx 급증** | 에러 주입 + 트래픽 생성 | `HighHTTPErrorRate` `OrderFailureRateHigh` | - | ~5분 |
| 4 | **CrashLoopBackOff** | exit 1 반복 Deployment | `PodCrashLoopBackOff` | `alert-container-restart-anomaly` | ~5분 |
| 5 | **Node 장애** | cordon + drain | `NodeNotReady` | `alert-failed-pod-scheduling` | ~3분 |

> 📋 각 시나리오의 상세 실행 방법과 확인 포인트는 [demo-scenarios/scenarios.md](demo-scenarios/scenarios.md) 를 참고하세요.

---

## 📊 알림 규칙 목록

### Prometheus Rule Groups (Managed Prometheus)

| 그룹 | 규칙 | Severity | 조건 |
|------|------|:--------:|------|
| **aks-node-alerts** | `NodeCPUHighUtilization` | 3 | 노드 CPU > 85% (5분) |
| | `NodeMemoryHighUtilization` | 2 | 노드 메모리 > 90% (5분) |
| | `NodeDiskPressure` | 2 | 디스크 사용률 > 85% (5분) |
| | `NodeNotReady` | 1 | 노드 NotReady 상태 (2분) |
| **aks-pod-alerts** | `PodCrashLoopBackOff` | 2 | 15분 내 3회 이상 재시작 |
| | `PodOOMKilled` | 2 | OOMKilled 종료 감지 |
| | `PodPendingTooLong` | 3 | 10분 이상 Pending |
| | `ContainerCPUThrottled` | 3 | CPU throttle > 50% (10분) |
| **aks-app-alerts** | `HighHTTPErrorRate` | 2 | 5xx 에러율 > 5% (5분) |
| | `HighRequestLatency` | 3 | P95 레이턴시 > 2초 (5분) |
| | `HighOrderQueueDepth` | 3 | 큐 깊이 > 30 (5분) |
| | `OrderFailureRateHigh` | 2 | 주문 실패율 > 10% (5분) |

### Azure Monitor Alert Rules (Log Analytics + Metric)

| 규칙 | 타입 | 조건 |
|------|------|------|
| `alert-container-restart-anomaly` | Log (KQL) | 컨테이너 재시작 > 5회 |
| `alert-oom-killed-pods` | Log (KQL) | OOMKilling 이벤트 감지 |
| `alert-failed-pod-scheduling` | Log (KQL) | FailedScheduling 이벤트 감지 |
| `alert-node-cpu-high` | Log (KQL) | 노드 CPU > 800M nanocores |
| `alert-aks-cluster-health` | Metric | API 서버 가용성 < 99% |

---

## 🖥️ 샘플 앱 API

| Endpoint | Method | 설명 |
|----------|--------|------|
| `/` | GET | 서비스 상태 |
| `/health` | GET | Liveness probe |
| `/ready` | GET | Readiness probe |
| `/metrics` | GET | Prometheus 메트릭 엔드포인트 |
| `/api/order` | POST | 주문 생성 (에러 주입 가능) |
| `/api/error` | GET | 강제 500 에러 |
| `/api/slow?delay=3` | GET | 지연 응답 (레이턴시 테스트) |
| `/api/toggle-errors?rate=0.5` | POST | 에러 주입 ON/OFF |
| `/api/memory-leak?size=10` | GET | 메모리 누수 시뮬레이션 |

### 노출하는 Prometheus 메트릭

| 메트릭 | 타입 | 설명 |
|--------|------|------|
| `http_requests_total` | Counter | HTTP 요청 수 (method, endpoint, status) |
| `http_request_duration_seconds` | Histogram | 요청 레이턴시 |
| `http_active_requests` | Gauge | 현재 활성 요청 수 |
| `http_errors_total` | Counter | HTTP 에러 수 (error_type) |
| `orders_processed_total` | Counter | 주문 처리 수 (status) |
| `order_queue_depth` | Gauge | 주문 큐 깊이 |

---

## 🔧 커스터마이징

### 알림 수신 채널 추가

`infra/setup-monitoring-infra.sh`의 Action Group에 Webhook, Logic App, Teams 등을 추가할 수 있습니다:

```bash
# Slack Webhook 추가 예시
az monitor action-group update \
  --name ag-aks-monitoring \
  --resource-group rg-aks-monitoring-demo \
  --add-action webhook slack-webhook "https://hooks.slack.com/services/YOUR/WEBHOOK/URL"
```

### Prometheus 알림 임계값 변경

`monitoring/prometheus-rules/aks-prometheus-rules.json`에서 각 규칙의 `expression`과 `for` 값을 수정하세요:

```json
{
  "alert": "NodeCPUHighUtilization",
  "expression": "avg by (instance) (...) > 0.85",  // ← 임계값 조정
  "for": "PT5M"                                     // ← 지속 시간 조정
}
```

### 새 Grafana 대시보드 추가

```bash
az grafana dashboard import \
  --name grafana-monitoring-demo \
  --resource-group rg-aks-monitoring-demo \
  --definition @monitoring/grafana-dashboards/your-dashboard.json
```

---

## 📚 참고 자료

- [Azure Monitor Managed Prometheus 개요](https://learn.microsoft.com/azure/azure-monitor/essentials/prometheus-metrics-overview)
- [Azure Managed Grafana 개요](https://learn.microsoft.com/azure/managed-grafana/overview)
- [AKS에서 Prometheus 메트릭 수집](https://learn.microsoft.com/azure/azure-monitor/containers/kubernetes-monitoring-enable)
- [Prometheus Rule Groups (Azure)](https://learn.microsoft.com/azure/azure-monitor/essentials/prometheus-rule-groups)
- [Azure Monitor 알림 규칙](https://learn.microsoft.com/azure/azure-monitor/alerts/alerts-overview)
- [Container Insights 개요](https://learn.microsoft.com/azure/azure-monitor/containers/container-insights-overview)

---

## 📄 License

This project is for demonstration purposes only.
