# RHOAI 3.4 → 3.5 오퍼레이터 비교 & Disconnected 반입 목록

사용자가 제공한 RHOAI 3.4 공식 오퍼레이터 목록(①~⑧ 카테고리)을, 이번에
`sandbox5462`에 실제로 설치한 **RHOAI 3.5** 클러스터의 라이브 상태
(`oc get subscription -A`, `oc get csv -A`, `oc get kedacontroller -A` 등으로
직접 확인)와 항목별로 대조한 결과.

## 카테고리별 비교

| # | 오퍼레이터 | 3.4 문서상 분류 | 우리 3.5 빌드 실치 여부 | 비고 |
|---|---|---|---|---|
| ① | Red Hat OpenShift AI Operator (`rhods-operator`) | 필수 | ✅ 설치 (`stable-3.5`, `redhat-ods-operator`) | 문서는 예시로 `fast-3.x` 채널을 들었지만, 우리는 `stable-3.5`로 고정 설치(빠른 업그레이드보다 검증된 채널 선택). |
| ② | cert-manager Operator for Red Hat OpenShift | 필수 | ✅ 설치 (`stable-v1`, `cert-manager-operator`) | 문서와 동일. |
| ③ | Red Hat OpenShift Service Mesh Operator 3.x | 조건부 | ✅ 설치 (`stable`, `openshift-operators`) | RHCL 설치 시 OLM 의존성으로 자동 반입됨. |
| ③ | Red Hat - Authorino Operator | 조건부(RHCL 경유) | ✅ 설치 (RHCL 의존성, `kuadrant-system`) | 구독명이 `authorino-operator-stable-redhat-operators-openshift-marketplace`처럼 OLM이 자동 생성한 이름으로 붙음 — 별도로 직접 구독을 만든 게 아니라 RHCL의 종속성 해석 결과. |
| ③ | RHCL(Kuadrant) Operator | 조건부 | ✅ 설치 (`stable`, `openshift-operators`, Manual approval) | Limitador·DNS Operator도 같은 방식(RHCL 의존성)으로 함께 설치됨. |
| ③ | Leader Worker Set Operator | 조건부 | ✅ 설치 (`stable-v1.0`, `openshift-lws-operator`) | 문서와 동일. |
| ③ | OpenShift Serverless (Knative) | 선택, 3.x 기본 아님 | ❌ RHOAI/MaaS 경로에는 미설치 | 문서 설명대로 3.x 기본 단일모델(RawDeployment) 경로엔 불필요해서 MaaS 스택엔 없음. **단, 이 하네스의 시나리오 9는 별도 목적(KServe Serverless 데모)으로 Service Mesh 2.x + Serverless를 독립적으로 설치함** — RHOAI 3.5 MaaS 스택과는 무관한 별도 설치 경로. |
| ④ | Red Hat build of Kueue | 조건부 | ✅ 설치 (`stable-v1.3`, `openshift-operators`) | 문서와 동일, 임베디드 Kueue 아니라 별도 Operator로 확인됨. |
| ④ | JobSet Operator | 조건부 | ❌ 별도 구독 없음 | 문서 설명대로 Kueue 1.3에 통합돼서 별도 Operator 불필요 — 라이브 확인 결과 별도 subscription/CSV 없음. |
| ④ | KubeRay / CodeFlare (컴포넌트) | 조건부(DSC 컴포넌트) | ❌ 미사용 | DSC의 `ray` 컴포넌트로 켜야 하는데, 이번 빌드는 기본 DSC 설정이라 비활성 상태. Operator 자체가 아니라 DSC 필드라 별도 반입 대상 아님. |
| ⑤ | Node Feature Discovery (NFD) | 가속기 | ✅ 설치 (`stable`, `redhat-operators`, `openshift-nfd`) | `gpu-operator.sh`에서 설치(RHOAI/MaaS 이전 단계). |
| ⑤ | NVIDIA GPU Operator | 가속기 | ✅ 설치 (`stable`, `certified-operators`, `nvidia-gpu-operator`) | 동일. |
| ⑤ | AMD / Intel Gaudi / IBM Spyre Operator | 가속기 | ❌ 미사용 | 이 클러스터는 NVIDIA GPU(g5/g6)만 사용 — 해당 하드웨어 없음. |
| ⑥ | Llama Stack Operator | 조건부(TP) | ❌ 미사용 | RAG/Agentic 기능 안 씀. |
| ⑥ | PostgreSQL Operator | 조건부 | ❌ Operator 아님 — POC PostgreSQL은 그냥 raw Pod | 라이브 확인: `redhat-ods-applications`에 `postgres-...` 파드가 그냥 Deployment로 떠있음(Operator 통한 관리 아님). 문서에도 "Operator 아님"으로 명시돼 있어 일치. |
| ⑦ | AI Pipelines / Argo Workflows (컴포넌트) | 조건부(DSC 컴포넌트) | ❌ 미사용 | `--setup-pipelines` 플래그를 안 줬음. |
| ⑦ | OpenShift Data Foundation (ODF) | 선택 | ❌ 미사용 | 대신 자체 in-cluster MinIO(`openshift-logging.sh`) + `gp3-csi` StorageClass 사용. |
| ⑧ | Cluster Observability Operator (COO) | 선택(TP) | ✅ **설치됨** (`openshift-cluster-observability-operator`) | **3.4→3.5 변경점**: 3.4 문서엔 "선택"이라고 돼 있지만, 3.5는 `--enable-observability` 플래그 없이도 기본으로 자동 설치됨(설치 로그의 "Updating DSCInitialization with observability metrics config" 단계). |
| ⑧ | Red Hat build of OpenTelemetry Operator | 선택(TP) | ✅ **설치됨** (`openshift-opentelemetry-operator`) | 위와 동일한 이유로 3.5부터 기본 설치. |
| ⑧ | Tempo Operator | 선택(TP) | ✅ **설치됨** (`openshift-tempo-operator`) | 위와 동일. |
| ⑧ | OpenShift Custom Metrics Autoscaler (CMA/KEDA) | 선택 | ⚠️ **미설치 — 실제로 필요한데 빠짐** | 아래 "발견된 갭" 참고. |

## 3.4 → 3.5 주요 변경점 정리

1. **관측성(Observability) 스택이 기본 설치로 바뀜**: 3.4는 COO/OpenTelemetry/
   Tempo가 전부 "선택(TP)"이라 `--enable-observability` 플래그로 켜야
   했는데, 3.5는 플래그 없이 설치해도 자동으로 셋 다 설치됨(`llm-d`용
   관측 대시보드가 기본 활성화되는 3.5의 변경사항과 일치).
2. **MaaS 구현 필드명 변경**: 3.4는 `DataScienceCluster.spec.components.
   kserve.modelsAsService`, 3.5는 `aigateway`라는 별도 DSC 컴포넌트로
   대체됨(External OIDC 인증, body-based 모델 라우팅 등 추가). 이건
   오퍼레이터 목록 변화가 아니라 같은 `rhods-operator`가 관리하는
   DSC 스키마 변화임 — 별도 오퍼레이터 반입은 불필요.
3. **CodeFlare Operator는 3.4에서 이미 제거됨** (사용자 문서에도 명시)
   — 3.5에서도 당연히 없음, 신경 쓸 필요 없음.
4. **HabanaAI(Intel Gaudi) workbench 이미지가 3.4에서 제거됨** — 애초에
   이 하네스는 NVIDIA만 쓰므로 영향 없음.

## ⚠️ 발견된 갭: KEDA(Custom Metrics Autoscaler) 미설치

라이브 클러스터에서 `oc get subscription -A`, `oc get csv -A`,
`oc get kedacontroller -A`, `oc get ns openshift-keda`를 전부 확인했지만
**KEDA/CMA 관련 리소스가 단 하나도 없음** — 이 하네스의 어떤 스크립트도
KEDA(Custom Metrics Autoscaler) 오퍼레이터를 설치하지 않는다.

그런데 `harness/remote/scenario8-kserve-vllm-start.sh`(KServe+vLLM+KEDA
오토스케일링 데모)는 `ScaledObject`(KEDA CRD)를 직접 생성하는 구조라서, KEDA
오퍼레이터 없이는 **CRD 자체가 없어서 즉시 실패**한다. 지금까지 이 시나리오가
동작했던 건 과거 어느 시점에 콘솔이나 별도 수동 명령으로 설치돼 있었기
때문일 가능성이 높고(스크립트로 캡처 안 됨), 이번 `sandbox5462` 처음부터의
재구축에서는 그 수동 설치가 빠졌다.

**Disconnected 준비 시 반드시 포함할 것**: `openshift-custom-metrics-autoscaler-operator`
(OperatorHub 표시명 "Custom Metrics Autoscaler", `redhat-operators` 카탈로그,
보통 `stable` 채널) — `openshift-keda` 네임스페이스에 설치 후 `KedaController`
CR을 하나 생성해야 실제로 동작함. 이 하네스 자체에도 설치 스크립트를
추가하는 게 근본 수정이지만, 이 문서 범위는 disconnected 반입 목록 정리이므로
우선 반입 대상에만 추가해둠.

## Disconnected 환경 최종 반입 목록 (RHOAI 3.5 기준)

`harness/operator-list.md`의 3번 섹션(RHOAI+MaaS)에 아래 두 가지를 추가/보강한
최종 목록:

| 패키지명 | 채널 | 카탈로그 소스 | 상태 |
|---|---|---|---|
| `rhods-operator` | `stable-3.5` | `redhat-operators` | 기존 목록에 있음 |
| `kueue-operator` | `stable-v1.3` | `redhat-operators` | 기존 목록에 있음 |
| `openshift-cert-manager-operator` | `stable-v1` | `redhat-operators` | 기존 목록에 있음 |
| `leader-worker-set` | `stable-v1.0` | `redhat-operators` | 기존 목록에 있음 |
| `servicemeshoperator3` | `stable` | `redhat-operators` | 기존 목록에 있음 |
| `rhcl-operator` (+ `authorino-operator`, `limitador-operator`, `dns-operator`) | `stable` | `redhat-operators` | 기존 목록에 있음 |
| `cluster-observability-operator` | (3.5 기본 설치 채널 확인 필요) | `redhat-operators` | **신규 추가 — 3.5부터 기본 설치됨** |
| `opentelemetry-product` | `stable` | `redhat-operators` | **신규 추가 — 3.5부터 기본 설치됨** |
| `tempo-product` | `stable` | `redhat-operators` | **신규 추가 — 3.5부터 기본 설치됨** |
| `openshift-custom-metrics-autoscaler-operator` (KEDA) | `stable` | `redhat-operators` | **신규 추가 — Scenario 8 실행에 필요하지만 현재 하네스에 설치 로직 없음, 수동/추가 스크립트 필요** |

즉 disconnected 환경에서는 `harness/operator-list.md`의 3번 섹션 8개 항목에
더해 위 4개(COO, OpenTelemetry, Tempo, KEDA)를 반드시 추가로 미러링해야
RHOAI 3.5 MaaS + 전체 시나리오(8번 포함)가 정상 동작한다.
