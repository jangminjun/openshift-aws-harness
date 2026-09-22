# RHCL 기반 MaaS(Models-as-a-Service) 가이드

이 하네스로 설치한 RHOAI 3.5 클러스터에서 RHCL(Red Hat Connectivity Link)을
이용한 MaaS 기능을 어떻게 준비하고, 어떤 구조로 동작하고, 어떤 스크립트로
설치/검증하는지 정리한 문서. 설치 자체는 `harness.sh rhoai` + `harness.sh maas`
두 명령으로 끝나지만, 그 뒤에 이어지는 "모델을 MaaS로 공개하고 API 키를
발급하는" 단계는 현재 이 하네스가 자동화하지 않고 RHOAI 대시보드에서 수동으로
해야 한다 — 이 문서 마지막에 그 절차도 정리해뒀다.

---

## 1. 준비사항 (관련 오퍼레이터)

MaaS는 RHOAI 오퍼레이터 하나로 끝나지 않고, 아래 6개 오퍼레이터가 전부
필요하다. 전부 `redhat-operators` 카탈로그에서 온다 (`harness/operator-list.md`
3번 섹션과 동일 — 여기서는 MaaS 관점에서 각각이 왜 필요한지만 짚는다).

| 오퍼레이터 | 채널 | 설치 네임스페이스 | MaaS에서의 역할 |
|---|---|---|---|
| `rhods-operator` (RHOAI 본체) | `stable-3.5` | `redhat-ods-operator` | `DataScienceCluster`의 `aigateway` 컴포넌트로 MaaS를 켬 |
| `openshift-cert-manager-operator` | `stable-v1` | `cert-manager-operator` | Gateway TLS 인증서 자동 발급 (Let's Encrypt 또는 self-signed) |
| `kueue-operator` | `stable-v1.3` | `openshift-operators` | 서빙/학습 워크로드 큐잉·쿼터 |
| `leader-worker-set` | `stable-v1.0` | `openshift-lws-operator` | 분산(멀티노드) 추론 워크로드 그룹 관리 |
| `servicemeshoperator3` | `stable` (Manual approval) | `openshift-operators` | Istio 기반 Gateway API 구현체 — RHCL이 실제 트래픽을 처리하는 데이터플레인 |
| `rhcl-operator` | `stable` (Manual approval) | `openshift-operators` | Kuadrant 배선 — 아래 3개를 OLM 의존성으로 자동 반입 |
| ┗ `authorino-operator` | (RHCL 의존성) | `kuadrant-system` | API 키/토큰 인증 (AuthPolicy) |
| ┗ `limitador-operator` | (RHCL 의존성) | `kuadrant-system` | 요금제/등급별 레이트리미팅 (RateLimitPolicy) |
| ┗ `dns-operator` | (RHCL 의존성) | `kuadrant-system` | RHCL 자체 DNS 라우팅 보조 |

**전제조건**: GPU 기반 모델을 서빙할 거라면 `nfd` + `gpu-operator-certified`
(NVIDIA GPU Operator)가 먼저 설치돼 있어야 함 — 이 하네스에서는
`harness.sh gpu-operator`가 `rhoai`/`maas`보다 먼저 실행됨.

**버전 주의 (RHOAI 3.4 → 3.5)**: 3.4는 MaaS를
`DataScienceCluster.spec.components.kserve.modelsAsService`로 켰지만, 3.5는
`aigateway`라는 별도 DSC 컴포넌트로 바뀌었다(External OIDC 인증, body-based
모델 라우팅 등 추가). 오퍼레이터 목록 자체는 동일하고 DSC 스키마만 바뀐 것 —
자세한 비교는 `harness/disconnected-rhoai-operator-list.md` 참고.

---

## 2. 아키텍처

### 2.1 컴포넌트 배치

```
                          ┌─────────────────────────────┐
  클라이언트(API 키)  ───▶│  Gateway (Istio/Service Mesh 3) │  namespace: openshift-ingress
                          │  - maas-default-gateway          │
                          │  - openshift-ai-inference         │
                          └──────────────┬────────────────┘
                                         │
                          ┌──────────────▼────────────────┐
                          │  Kuadrant (RHCL)                │  namespace: kuadrant-system
                          │  - AuthPolicy → Authorino        │  (API 키 검증)
                          │  - RateLimitPolicy → Limitador   │  (등급별 요청 제한)
                          └──────────────┬────────────────┘
                                         │ 인증/제한 통과한 요청만
                          ┌──────────────▼────────────────┐
                          │  KServe InferenceService (vLLM)  │  namespace: (모델별)
                          │  - LLMInferenceService CR         │
                          └─────────────────────────────────┘

  DataScienceCluster.spec.components.aigateway   ── 위 전체를 RHOAI가
  (namespace: redhat-ods-operator가 관리)            "MaaS"로 묶어서 관리하는 지점
```

### 2.2 요청 처리 흐름

1. 클라이언트가 API 키를 헤더에 넣어 Gateway(`maas.apps.<domain>` 또는
   `inference-gateway.apps.<domain>`)로 요청을 보냄.
2. Gateway(Istio)가 요청을 Kuadrant의 `AuthPolicy`로 넘김 — Authorino가
   API 키의 유효성 **+** 해당 `LLMInferenceService`에 대한 접근 권한
   (SubjectAccessReview)을 함께 검증. 토큰이 유효해도 그 모델에 대한 권한이
   없으면 403 (이 하네스 세션 초반에 겪었던 "토큰은 맞는데 403" 패턴이 바로
   이 지점).
3. 인증 통과 후 `RateLimitPolicy`(Limitador)가 API 키의 요금제(tier)에 따라
   초당/분당 요청 수를 제한.
4. 통과한 요청만 실제 모델을 서빙하는 KServe `InferenceService`(vLLM 파드)로
   라우팅됨.

### 2.3 확인된 실제 리소스 (2026-09-11 sandbox5462 빌드 기준)

라이브 설치 직후 실제로 존재를 확인한 리소스들:

```bash
oc get gateway -A
# openshift-ingress   data-science-gateway     data-science-gateway-class
# openshift-ingress   maas-default-gateway     maas-gateway-class
# openshift-ingress   openshift-ai-inference   openshift-ai-inference

oc get datasciencecluster default-dsc -o jsonpath='{.spec.components.aigateway}'
# {"managementState":"Managed","modelsAaService":{"managementState":"Managed"}}
```

- **MaaS Gateway**: `https://maas.apps.<cluster-domain>`
- **Inference Gateway**: `https://inference-gateway.apps.<cluster-domain>`
- **RHOAI(ODS) Dashboard**: `https://data-science-gateway.apps.<cluster-domain>`
  (여기서 실제 구독/API 키 발급을 함 — 3.4의 §5.1)

---

## 3. 스크립트

이 하네스에서 MaaS까지 가는 경로는 딱 두 단계다. **순서를 반드시 지킬 것**
(rhoai 없이 maas만 실행하면 DSC를 만들 오퍼레이터 자체가 없어서 실패).

### 3.1 `harness.sh rhoai` — RHOAI 오퍼레이터만 설치

```bash
cd harness
ADMIN_PASSWORD=<htpasswd 비번> ./harness.sh rhoai
```

`remote/rhoai.sh`가 하는 일 (DSC는 안 건드림, 오퍼레이터만):
1. `RHOAI_CHANNEL`(기본 `stable-3.5`)로 `Subscription/rhods-operator` 생성
2. 기존 구독이 **다른 채널**(예: 2.x)이면 — OLM이 메이저 버전 경계를
   넘는 채널 전환을 못 하므로 — Subscription+CSV를 지우고 새로 설치
   (`basic-demo/lessonlearn.md` #7에서 확인된 버그의 예방 코드)
3. CSV가 `Succeeded`될 때까지 대기

### 3.2 `harness.sh maas` — DataScienceCluster + MaaS 스택 전체

```bash
ADMIN_PASSWORD=<htpasswd 비번> ./harness.sh maas
```

`remote/maas.sh`가 하는 일:
1. `RHOAI-Toolkit`(`https://github.com/hyogrin/RHOAI-Toolkit.git`, `MAAS_TOOLKIT_REF`로
   커밋 고정 가능)을 bastion의 `~/RHOAI-Toolkit`에 클론/업데이트
2. 이미 DSC가 있는데 MaaS 필드가 없으면(구버전에서 마이그레이션하는 경우)
   전체 재생성 대신 `aigateway`/`modelsAsService` 필드만 merge-patch
   (전체 삭제는 한 번 시도했다가 `rhods-operator` 파드를 잠깐
   크래시루프시켰던 전례가 있어서 지금은 안 씀)
3. `install-rhoai-35.sh --skip-admin-user --skip-node-scaling --channel "$RHOAI_CHANNEL"`을
   `yes ""`로 감싸서 실행 — 대화형 프롬프트(SearXNG 배포 방식 등)를 전부
   기본값으로 통과시킴. 실제로 이 스크립트 하나가 위 6개 오퍼레이터 설치,
   Kuadrant/Istio 배선, Gateway 생성, TLS 인증서 발급, DSC 생성까지 전부 함
   (자세한 순서는 `harness/disconnected-rhoai-operator-list.md`의
   "라이브 설치 로그" 참고)
4. `yes`가 SIGPIPE(141)로 죽는 것과 실제 설치 실패를 구분하기 위해
   `set +e` + `PIPESTATUS[1]`로 `install-rhoai-35.sh` 자신의 종료 코드만 봄

### 3.3 설치 후 검증 명령 (install-rhoai-35.sh 자체 안내)

```bash
oc get datasciencecluster                                    # DSC Ready 확인
oc get csv -n redhat-ods-operator                             # rhods-operator CSV
oc get hardwareprofiles -n redhat-ods-applications            # GPU 하드웨어 프로필
oc get crd | grep maas.opendatahub.io                         # MaaS CRD 설치 확인
oc get tenant -n models-as-a-service                          # MaaS 테넌트
oc get maassubscriptions -n models-as-a-service                # 발급된 구독
oc get gateway maas-default-gateway -n openshift-ingress       # Gateway Programmed 확인
oc get authorino authorino -n kuadrant-system -o jsonpath='{.spec.listener.tls}'
```

### 3.4 (수동, 스크립트화 안 됨) 모델을 MaaS로 공개하고 API 키 발급하기

`install-rhoai-35.sh`가 끝나면 플랫폼만 준비된 상태고, 아래는 RHOAI
대시보드(`https://data-science-gateway.apps.<domain>`)에서 직접 해야 한다 —
이 하네스는 특정 모델을 자동으로 MaaS에 올리지 않는다:

1. Dashboard → Settings에서 MaaS 활성화 상태 확인
2. 모델을 `InferenceService`로 배포한 뒤 MaaS로 공개 (`MaaSModelRef` 생성)
3. Dashboard → Settings → Subscriptions에서 MaaS Subscription 생성
4. Dashboard → Settings → Authorization Policies에서 인증 정책 생성
5. Dashboard 또는 self-service로 사용자별 API 키 발급
6. 발급된 키로 `https://inference-gateway.apps.<domain>/v1/chat/completions` 호출

이 5~6단계를 스크립트로 자동화하고 싶다면 `harness/remote/`에
`maas-publish-model.sh` 같은 새 스크립트를 추가하는 게 다음 단계가 될 것 —
현재는 없음.
