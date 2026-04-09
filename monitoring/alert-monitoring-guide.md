# AKS Alert Monitoring 통합 가이드 (Unified Alert Monitoring Guide)

> **대상 독자 (Audience)**: AKS 클러스터 운영자 및 모니터링 담당자  
> **환경 (Environment)**: AKS + Managed Prometheus + Managed Grafana + Azure Monitor + Log Analytics

---

## 1. 개요 (Overview)

AKS 모니터링 환경에서는 알림(Alert)이 **네 가지 서로 다른 리소스 타입**으로 관리됩니다.
이 문서는 각 알림 유형의 특성과 확인 방법을 설명하고,
**"발생한 알림(Fired Alert)"은 한 화면에서 볼 수 있지만 "알림 규칙(Alert Rule)"은 별도 메뉴에서 관리해야 하는 이유**를 안내합니다.
마지막으로, 알림 규칙을 하나의 화면에서 조회하기 위한 대안을 제시합니다.

In an AKS monitoring environment, alerts are managed across **four distinct resource types**.
This guide explains the characteristics of each alert type, why **fired alerts** are viewable in a single pane while **alert rules** require separate navigation, and presents alternatives for unified alert rule visibility.

---

## 2. 테스트 시나리오 (Test Scenarios)

본 환경에는 알림 동작을 End-to-End로 검증하기 위한 5가지 데모 시나리오가 구성되어 있습니다.
아래 표는 각 시나리오가 트리거하는 알림 규칙을 유형별로 정리한 것입니다.

| # | 시나리오 (Scenario) | Prometheus Alert | Log Query Alert | Metric Alert |
|---|-------------------|-----------------|-----------------|--------------|
| 1 | **CPU 과부하** (CPU Overload) | `NodeCPUHighUtilization`<br>`ContainerCPUThrottled` | `alert-node-cpu-high` | `alert-aks-cluster-health` |
| 2 | **OOMKilled** (Memory Exceeded) | `PodOOMKilled` | `alert-oom-killed-pods` | - |
| 3 | **HTTP 5xx 급증** (Error Rate Spike) | `HighHTTPErrorRate`<br>`OrderFailureRateHigh` | - | - |
| 4 | **CrashLoopBackOff** (Restart Loop) | `PodCrashLoopBackOff` | `alert-container-restart-anomaly` | - |
| 5 | **Node Drain** (Node Failure) | `NodeNotReady`<br>`PodPendingTooLong` | `alert-failed-pod-scheduling` | - |

### 시나리오별 상세 (Scenario Details)

#### 시나리오 1: CPU 과부하 (CPU Overload)

- **목적**: 노드/컨테이너 CPU 과부하 시 Prometheus → Azure Monitor 알림 경로 검증
- **방법**: `polinux/stress` 이미지로 CPU 4코어를 5분간 점유하는 Job 배포
- **예상 타임라인**: 배포 후 ~5분 내 `NodeCPUHighUtilization` Prometheus Alert firing → Action Group → Email 수신

#### 시나리오 2: OOMKilled (Memory Exceeded)

- **목적**: 메모리 초과(OOMKilled) 감지 및 이중 알림 경로(Prometheus + Log Query) 확인
- **방법**: 메모리 limit(128Mi)보다 큰 512MB를 할당 시도하는 Job 배포
- **특징**: Prometheus(`PodOOMKilled`)와 Log Query(`alert-oom-killed-pods`)가 **동시에** 트리거됨

#### 시나리오 3: HTTP 5xx 에러 급증 (Error Rate Spike)

- **목적**: 애플리케이션 커스텀 메트릭 기반 알림 확인
- **방법**: sample-app의 에러 모드를 활성화(50% 에러율)한 뒤 트래픽 주입
- **특징**: Prometheus 전용 알림 (Log Query 대상 아님)

#### 시나리오 4: CrashLoopBackOff (Restart Loop)

- **목적**: 반복 crash 감지 및 이중 알림 경로(Prometheus + Log Query) 확인
- **방법**: 5초 후 exit 1로 종료하는 컨테이너를 replicas=2로 배포
- **특징**: ~15분 후 Prometheus(`PodCrashLoopBackOff`)와 Log Query(`alert-container-restart-anomaly`) 동시 발생

#### 시나리오 5: Node Drain (Node Failure)

- **목적**: 노드 장애 시 알림 및 워크로드 자동 재배치 확인
- **방법**: 워커 노드를 cordon + drain하여 스케줄링 차단
- **주의**: 운영 환경에 영향을 줄 수 있으므로 수동 확인 필요

### 실행 방법 (How to Run)

```bash
# 개별 시나리오 실행 (Run individual scenario)
./scripts/trigger-alerts.sh <1|2|3|4|5|cpu|oom|errors|crashloop|node>

# 시나리오 1~4 순차 실행 (Run scenarios 1-4 sequentially)
./scripts/trigger-alerts.sh all

# 현재 상태 확인 (Check current status)
./scripts/trigger-alerts.sh status

# 테스트 리소스 정리 (Cleanup test resources)
./scripts/trigger-alerts.sh cleanup
```

---

## 3. Alert Rule이 별도 메뉴에서 관리되는 이유 (Why Alert Rules Live in Separate Menus)

### 4가지 Alert Rule 리소스 타입

Azure에서 AKS 관련 알림 규칙은 네 가지 **서로 다른 Azure Resource Provider** 에 의해 관리됩니다.
이는 Azure 플랫폼의 설계에 기인하며, 각각의 데이터 소스와 평가 엔진이 다르기 때문입니다.

| 유형 (Type) | Azure Resource Type | 데이터 소스 (Data Source) | 관리 위치 (Portal Location) |
|------------|--------------------|--------------------------|-----------------------------|
| **Prometheus Alert** | `Microsoft.AlertsManagement/`<br>`prometheusRuleGroups` | Azure Monitor Workspace<br>(Managed Prometheus) | Azure Monitor → **Prometheus rule groups** |
| **Log Query Alert** | `Microsoft.Insights/`<br>`scheduledQueryRules` | Log Analytics Workspace<br>(Container Insights, KQL) | Azure Monitor → **Alert rules** |
| **Metric Alert** | `Microsoft.Insights/`<br>`metricAlerts` | AKS Platform Metrics<br>(ARM metric namespace) | Azure Monitor → **Alert rules** |
| **Smart Detector** | `Microsoft.AlertsManagement/`<br>`smartDetectorAlertRules` | Application Insights<br>(AI/ML 기반 이상 탐지) | Azure Monitor → **Alert rules** |

### 왜 분리되어 있는가? (Why Are They Separated?)

```
┌──────────────────────────────────────────────────────────────────────┐
│                      AKS Cluster                                     │
│  ┌─────────┐   ┌──────────────────┐   ┌────────────────────────┐    │
│  │ App Pod  │──▶│ ama-metrics      │──▶│ Azure Monitor          │    │
│  │ (metrics)│   │ (DaemonSet)      │   │ Workspace (Prometheus) │    │
│  └─────────┘   └──────────────────┘   └────────┬───────────────┘    │
│                                                 │                    │
│  ┌─────────┐   ┌──────────────────┐   ┌────────▼───────────────┐    │
│  │ kubelet  │──▶│ ama-logs         │──▶│ Log Analytics          │    │
│  │ (logs)   │   │ (DaemonSet)      │   │ Workspace              │    │
│  └─────────┘   └──────────────────┘   └────────┬───────────────┘    │
│                                                 │                    │
│  ┌─────────┐                          ┌────────▼───────────────┐    │
│  │ AKS     │─────────────────────────▶│ ARM Platform Metrics   │    │
│  │ (API)   │                          │ (node_cpu_usage_% etc) │    │
│  └─────────┘                          └────────────────────────┘    │
└──────────────────────────────────────────────────────────────────────┘
```

1. **데이터 소스가 다르다 (Different data sources)**
   - Prometheus Alert → PromQL로 시계열 메트릭 평가 (time-series metric evaluation via PromQL)
   - Log Query Alert → KQL로 로그 테이블 쿼리 (log table query via KQL)
   - Metric Alert → ARM 메트릭 네임스페이스의 집계 값 평가 (aggregated ARM metric evaluation)

2. **평가 엔진이 다르다 (Different evaluation engines)**
   - Prometheus Rule Group은 Azure Monitor Workspace에 바인딩되어 PromQL 엔진으로 평가
   - Scheduled Query Rule은 Log Analytics에 바인딩되어 KQL 엔진으로 평가
   - Metric Alert은 ARM Metrics Pipeline에서 직접 평가

3. **Azure Portal의 리소스 기반 네비게이션 (Resource-based Portal navigation)**
   - Azure Portal은 ARM Resource Type 단위로 UI를 구성하므로,
     서로 다른 Resource Provider에 속한 규칙들은 자연스럽게 다른 메뉴에 표시됩니다.
   - Prometheus Rule Group: `Monitor → Prometheus rule groups`
   - Log/Metric Alert Rule: `Monitor → Alert rules` (이 둘은 같은 메뉴에 표시)

> **핵심 (Key Point)**: 이것은 기능적 제약이 아니라 Azure가 각 데이터 소스에 최적화된 별도 엔진을
> 제공하기 때문입니다. 각 엔진이 해당 데이터 형식에 가장 효율적인 평가를 수행합니다.

---

## 4. 발생한 Alert은 한 화면에서 볼 수 있다 (Fired Alerts Are Viewable in One Place)

**Alert Rule(규칙)**은 분산되어 있지만, **실제 발생한 Alert(알림 인스턴스)**는 유형에 관계없이 한 화면에서 확인할 수 있습니다.

### Azure Monitor → Alerts (통합 알림 뷰)

```
Azure Portal → Monitor → Alerts
```

이 화면에서는 Prometheus Alert, Log Query Alert, Metric Alert, Smart Detector Alert 모두 **단일 리스트**로 표시됩니다.

| 확인 가능 항목 (Available Information) | 설명 (Description) |
|--------------------------------------|---------------------|
| Alert 이름 (Alert Name) | 발생한 알림의 이름 |
| Severity (심각도) | Sev 0 ~ Sev 4 |
| Signal Type (신호 유형) | Prometheus / Log / Metric 구분 |
| Target Resource (대상 리소스) | 알림이 바인딩된 리소스 |
| Fired Time (발생 시각) | 알림이 트리거된 시간 |
| State (상태) | New / Acknowledged / Closed |

**필터링 팁 (Filtering Tips)**:
- **Signal type** 필터로 `Prometheus`, `Log`, `Metric` 유형별 분류 가능
- **Severity** 필터로 긴급도별 분류 가능
- **Resource group** / **Resource** 필터로 범위 한정 가능
- **Time range** 조정으로 특정 기간의 알림만 조회 가능

> ✅ **결론**: 운영 중 "지금 뭐가 터졌는가?"를 확인하는 것은 **`Monitor → Alerts` 한 화면으로 충분**합니다.

---

## 5. Alert Rule을 하나의 화면에서 조회하기 위한 대안 (Alternatives for Unified Alert Rule View)

"어떤 규칙들이 정의되어 있는가?"를 한 눈에 파악하기 위한 방법을 소개합니다.

### 대안 1: Azure Resource Graph 쿼리 (Recommended)

Azure Resource Graph Explorer(`portal → Resource Graph Explorer`)에서 아래 쿼리를 실행하면
모든 Alert Rule을 **단일 테이블**로 조회할 수 있습니다.

> **⚠️ 주의: Recording Rule Group vs Alert Rule Group**
>
> AKS에서 Managed Prometheus를 활성화하면 Azure가 Grafana 대시보드용 **Recording Rule Group**을
> 자동으로 생성합니다. 이 그룹들은 `alert`이 아닌 `record` 규칙만 포함하므로 알림과 무관하지만,
> 동일한 리소스 타입(`prometheusRuleGroups`)을 사용하기 때문에 **필터 없이 조회하면 함께 표시**됩니다.
>
> | 자동 생성 Recording Rule Group | 용도 |
> |-------------------------------|------|
> | `KubernetesRecordingRulesRuleGroup-*` | K8s 핵심 메트릭 사전 집계 |
> | `NodeRecordingRulesRuleGroup-*` | 노드 메트릭 사전 집계 |
> | `NodeRecordingRulesRuleGroup-Win-*` | Windows 노드 메트릭 |
> | `NodeAndKubernetesRecordingRulesRuleGroup-Win-*` | Windows 통합 메트릭 |
> | `UXRecordingRulesRuleGroup-*` | Azure Portal UX용 메트릭 |
> | `UXRecordingRulesRuleGroup-Win-*` | Windows Portal UX용 메트릭 |
>
> 또한 Resource Graph는 **구독 전체를 스캔**하므로, 다른 리소스 그룹의 Alert Rule도 결과에 포함됩니다.
> 아래 쿼리에서는 이 두 가지를 모두 필터링합니다.

#### 기본 쿼리: 그룹 단위 조회 (Group-level View)

```kusto
resources
| where type in~ (
    'microsoft.alertsmanagement/prometheusrulegroups',
    'microsoft.insights/scheduledqueryrules',
    'microsoft.insights/metricalerts',
    'microsoft.alertsmanagement/smartdetectoralertrules'
  )
// (선택) 특정 리소스 그룹으로 범위 한정 — 다른 RG의 rule 제외
// (선택) 특정 리소스 그룹으로 범위 한정 — 생략하면 구독 전체 조회
| where resourceGroup =~ 'rg-aks-monitoring-demo'
| extend alertType = case(
    type =~ 'microsoft.alertsmanagement/prometheusrulegroups', 'Prometheus',
    type =~ 'microsoft.insights/scheduledqueryrules',          'LogQuery',
    type =~ 'microsoft.insights/metricalerts',                 'Metric',
    type =~ 'microsoft.alertsmanagement/smartdetectoralertrules', 'SmartDetector',
    'Unknown'
  )
// Prometheus: Recording Rule Group 제외 (alert 필드가 있는 rule이 1개 이상인 그룹만)
| where alertType != 'Prometheus'
    or array_length(properties.rules) > 0
       and isnotnull(properties.rules[0].alert)
| extend severity = case(
    alertType == 'Prometheus', tostring(properties.rules[0].severity),
    alertType == 'SmartDetector', tostring(properties.severity),
    tostring(properties.severity)
  )
| extend enabled = case(
    alertType == 'SmartDetector', tostring(properties.state),
    tostring(properties.enabled)
  )
| extend displayName = case(
    alertType == 'Prometheus', name,
    coalesce(tostring(properties.displayName), name)
  )
| extend ruleCount = iff(alertType == 'Prometheus', array_length(properties.rules), 1)
| extend evaluationFrequency = case(
    alertType == 'Prometheus',     tostring(properties.interval),
    alertType == 'LogQuery',       tostring(properties.evaluationFrequency),
    alertType == 'Metric',         tostring(properties.evaluationFrequency),
    alertType == 'SmartDetector',  tostring(properties.frequency),
    ''
  )
| project displayName, alertType, severity, enabled, ruleCount,
          evaluationFrequency, resourceGroup, id
| order by alertType asc, severity asc
```

#### 상세 쿼리: Prometheus 개별 Rule까지 전개 (Expanded View with mv-expand)

```kusto
resources
| where type in~ (
    'microsoft.alertsmanagement/prometheusrulegroups',
    'microsoft.insights/scheduledqueryrules',
    'microsoft.insights/metricalerts',
    'microsoft.alertsmanagement/smartdetectoralertrules'
  )
// (선택) 특정 리소스 그룹으로 범위 한정 — 생략하면 구독 전체 조회
| where resourceGroup =~ 'rg-aks-monitoring-demo'
| extend alertType = case(
    type =~ 'microsoft.alertsmanagement/prometheusrulegroups', 'Prometheus',
    type =~ 'microsoft.insights/scheduledqueryrules',          'LogQuery',
    type =~ 'microsoft.insights/metricalerts',                 'Metric',
    type =~ 'microsoft.alertsmanagement/smartdetectoralertrules', 'SmartDetector',
    'Unknown'
  )
| mv-expand rule = iff(alertType == 'Prometheus', properties.rules, pack_array(properties))
// Prometheus recording rule 제외: alert 필드가 비어있으면 recording rule
| where alertType != 'Prometheus' or isnotempty(tostring(rule.alert))
| extend ruleName = case(
    alertType == 'Prometheus', tostring(rule.alert),
    alertType == 'LogQuery',   coalesce(tostring(properties.displayName), name),
    alertType == 'Metric',     name,
    alertType == 'SmartDetector', coalesce(tostring(properties.displayName), name),
    name
  )
| extend severity    = toint(coalesce(rule.severity, properties.severity))
| extend expression  = case(
    alertType == 'Prometheus', tostring(rule.expression),
    alertType == 'LogQuery',   tostring(properties.criteria.allOf[0].query),
    alertType == 'Metric',     tostring(properties.criteria.allOf[0].metricName),
    alertType == 'SmartDetector', tostring(properties.detector.id),
    ''
  )
| project ruleName, alertType, severity, name, resourceGroup, expression
| order by alertType asc, severity asc
```

> 이 쿼리를 실행하면 Prometheus Alert 12개 + Log Query 4개 + Metric 1개 + Smart Detector 2개 = **총 19개 Alert Rule**이 표시됩니다.
> Recording Rule Group(6개)과 다른 리소스 그룹의 무관한 Alert은 제외됩니다.

#### CLI로 실행 (Run via Azure CLI)

```bash
az graph query -q "resources \
  | where type in~ ( \
      'microsoft.alertsmanagement/prometheusrulegroups', \
      'microsoft.insights/scheduledqueryrules', \
      'microsoft.insights/metricalerts', \
      'microsoft.alertsmanagement/smartdetectoralertrules') \
  | where resourceGroup =~ 'rg-aks-monitoring-demo' \
  | extend alertType = case( \
      type =~ 'microsoft.alertsmanagement/prometheusrulegroups', 'Prometheus', \
      type =~ 'microsoft.insights/scheduledqueryrules', 'LogQuery', \
      type =~ 'microsoft.insights/metricalerts', 'Metric', \
      type =~ 'microsoft.alertsmanagement/smartdetectoralertrules', 'SmartDetector', 'Unknown') \
  | where alertType != 'Prometheus' \
      or isnotnull(properties.rules[0].alert) \
  | extend severity = case( \
      alertType == 'Prometheus', tostring(properties.rules[0].severity), \
      tostring(properties.severity)) \
  | extend displayName = case( \
      alertType == 'Prometheus', name, \
      coalesce(tostring(properties.displayName), name)) \
  | extend ruleCount = iff(alertType == 'Prometheus', array_length(properties.rules), 1) \
  | project displayName, alertType, severity, ruleCount, resourceGroup \
  | order by alertType, severity" \
  --output table
```

### 대안 2: Azure Workbook

Azure Monitor Workbook을 활용하면 **시각적으로 풍부한 통합 대시보드**를 구성할 수 있습니다.
본 환경에는 바로 사용 가능한 Workbook 템플릿(`monitoring/workbooks/aks-alert-monitoring-workbook.json`)이 포함되어 있습니다.

#### Workbook 구성 (3개 탭)

| 탭 (Tab) | 내용 (Content) |
|----------|---------------|
| **📋 개요 (Overview)** | 유형별/Severity별 원형 그래프, 아키텍처 설명 |
| **📐 Alert Rules (통합 조회)** | 리소스 유형별 개별 테이블 (Prometheus / Log Query / Metric / Smart Detector) |
| **🔥 Fired Alerts** | 실시간 발생 알림 현황, Severity/State 요약 |

#### 주요 기능

- **Resource Group 필터**: `All (Subscription)` 선택 시 구독 전체 조회, 특정 RG 선택 시 해당 RG만 조회
- **리소스 유형별 개별 테이블**: 각 타입에 맞는 고유 컬럼 표시
  - 🟠 Prometheus: PromQL Expression, Rule Group, For
  - 🔵 Log Query: KQL Query, Frequency, Window
  - 🟢 Metric: Metric, Condition, Scope
  - 🟣 Smart Detector: Detector, State, Scope
- **Severity 컬러코딩, 필터, Excel 내보내기** 지원

#### 임포트 방법 (How to Import)

1. Azure Portal → **Monitor → Workbooks → New**
2. **Advanced Editor** (`</>` 아이콘) 클릭
3. `monitoring/workbooks/aks-alert-monitoring-workbook.json` 내용을 붙여넣기
4. **Apply → Done Editing → Save**

**장점**: Portal 내 네이티브 환경, 팀 공유 용이, 자동 새로고침  
**적합한 경우**: 운영팀이 주기적으로 규칙 현황을 리뷰할 때

### 대안 3: Grafana 대시보드 (Azure Resource Graph Plugin)

Managed Grafana에서 **Azure Resource Graph** 데이터 소스를 추가하면
기존 Grafana 대시보드 안에 Alert Rule 현황 패널을 함께 배치할 수 있습니다.

1. Grafana → Configuration → Data Sources → **Azure Resource Graph** 추가
2. 위 쿼리를 패널에 삽입하여 테이블 또는 차트로 시각화
3. 기존 메트릭 대시보드와 같은 화면에 배치 가능

**장점**: 메트릭 대시보드 + Alert Rule 현황을 단일 화면에서 확인  
**적합한 경우**: Grafana 중심으로 모니터링을 운영하는 팀

---

## 6. 요약 (Summary)

```
                          ┌─────────────────────────┐
                          │   Alert Rule 정의        │
                          │   (규칙 관리)             │
                          └────────┬────────────────┘
                                   │
          ┌──────────────┬─────────┼──────────┬──────────────────┐
          ▼              ▼         ▼          ▼                  │
┌────────────────┐ ┌──────────┐ ┌────────┐ ┌────────────────┐   │
│ Prometheus Rule│ │ Scheduled│ │ Metric │ │ Smart Detector │   │
│ Groups         │ │ Query    │ │ Alert  │ │ Alert Rules    │   │
│                │ │ Rules    │ │ Rules  │ │                │   │
│ Monitor →      │ │ Monitor →│ │Monitor→│ │ Monitor →      │   │
│ Prometheus rule│ │ Alert    │ │ Alert  │ │ Alert rules    │   │
│ groups         │ │ rules    │ │ rules  │ │                │   │
└───────┬────────┘ └────┬─────┘ └───┬────┘ └───────┬────────┘   │
        │               │          │               │            │
        │        ┌──────┘          │               │            │
        ▼        ▼                 ▼               ▼            │
┌───────────────────────────────────────────────────────────────┐
│              Azure Monitor → Alerts                            │
│              (발생한 Alert 통합 조회 / Unified Fired View)       │
└───────────────────────────────────────────────────────────────┘
```

| 구분 (Category) | 현황 (Current State) | 대안 (Alternative) |
|-----------------|---------------------|-------------------|
| **발생한 Alert 조회** (Fired Alerts) | ✅ `Monitor → Alerts` 한 화면에서 통합 조회 가능 | - |
| **Alert Rule 조회** (Alert Rules) | ⚠️ Prometheus Rule Group / Smart Detector는 별도 메뉴 | ✅ Resource Graph 쿼리로 통합 조회 |
| **Alert Rule 시각화** (Rule Visualization) | ⚠️ 유형별 분산 | ✅ Workbook (리소스 유형별 테이블) 또는 Grafana |

---

## 부록: 현재 환경의 전체 Alert Rule 목록 (Appendix: Complete Alert Rule Inventory)

### Prometheus Alert Rules (12 rules in 3 groups)

| Group | Alert Name | Severity | 조건 (Condition) | For |
|-------|-----------|----------|-----------------|-----|
| aks-node-alerts | `NodeCPUHighUtilization` | Sev 3 | CPU 사용률 > 85% | 5m |
| aks-node-alerts | `NodeMemoryHighUtilization` | Sev 2 | 메모리 사용률 > 90% | 5m |
| aks-node-alerts | `NodeDiskPressure` | Sev 2 | 디스크 사용률 > 85% | 5m |
| aks-node-alerts | `NodeNotReady` | Sev 1 | 노드 Ready=false | 2m |
| aks-pod-alerts | `PodCrashLoopBackOff` | Sev 2 | 15분 내 재시작 > 3회 | 5m |
| aks-pod-alerts | `PodOOMKilled` | Sev 2 | OOMKilled 종료 감지 | 1m |
| aks-pod-alerts | `PodPendingTooLong` | Sev 3 | Pending 상태 지속 | 10m |
| aks-pod-alerts | `ContainerCPUThrottled` | Sev 3 | CPU throttle > 50% | 10m |
| aks-app-alerts | `HighHTTPErrorRate` | Sev 2 | 5xx 에러율 > 5% | 5m |
| aks-app-alerts | `HighRequestLatency` | Sev 3 | P95 레이턴시 > 2초 | 5m |
| aks-app-alerts | `HighOrderQueueDepth` | Sev 3 | 주문 큐 > 30 | 5m |
| aks-app-alerts | `OrderFailureRateHigh` | Sev 2 | 주문 실패율 > 10% | 5m |

### Log Query Alert Rules (4 rules)

| Alert Name | Severity | 데이터 소스 (Source) | 평가 주기 (Frequency) |
|-----------|----------|---------------------|----------------------|
| `alert-container-restart-anomaly` | Sev 2 | KubePodInventory (RestartCount > 5) | 5m / 15m window |
| `alert-oom-killed-pods` | Sev 2 | KubeEvents (Reason=OOMKilling) | 5m / 15m window |
| `alert-failed-pod-scheduling` | Sev 3 | KubeEvents (Reason=FailedScheduling) | 5m / 15m window |
| `alert-node-cpu-high` | Sev 3 | Perf (cpuUsageNanoCores > 800M) | 5m / 30m window |

### Metric Alert Rules (1 rule)

| Alert Name | Severity | 메트릭 (Metric) | 임계값 (Threshold) |
|-----------|----------|-----------------|-------------------|
| `alert-aks-cluster-health` | Sev 1 | node_cpu_usage_percentage | > 80% (5m avg) |

### Smart Detector Alert Rules (2 rules)

| Alert Name | Severity | Detector | Scope |
|-----------|----------|----------|-------|
| `Failure Anomalies - 273483f8-...` | Sev4 | FailureAnomaliesDetector | Application Insights |
| `Failure Anomalies - aiappinsightstest` | Sev4 | FailureAnomaliesDetector | Application Insights |

> **참고**: Smart Detector 규칙은 Application Insights가 있는 리소스 그룹(`aoaitest`)에 위치합니다.
> AKS 리소스 그룹과 다를 수 있으므로, Workbook에서 `All (Subscription)` 옵션을 사용하여 조회하세요.
