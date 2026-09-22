# Disconnected 설치를 위한 오퍼레이터 목록

이 하네스(`openshift-aws-harness`)가 현재 구성대로 클러스터를 설치할 때 사용하는
모든 OLM 오퍼레이터 목록. Disconnected(에어갭) 환경에서는 이 목록을 `oc-mirror`
(v2, `ImageSetConfiguration`)의 `mirror.operators`에 그대로 넣어서 사설
레지스트리로 반입(mirror)한 뒤, 클러스터에 `ImageContentSourcePolicy`/
`ICSP`+`CatalogSource`를 그 사설 레지스트리를 가리키도록 설정해야 함.

**주의**: 이 문서의 1~5번 섹션은 어디까지나 *추가로 설치한 OLM 오퍼레이터*
목록이다. OpenShift 자체의 릴리스 페이로드(`openshift-install`이 쓰는 release
image)에 이미 포함된 핵심 오퍼레이터는 아래 0번 섹션 참고. 컨테이너 이미지
(vLLM, Qwen 모델 등)는 어느 쪽에도 안 들어가며 이 문서 범위 밖.

## 0. OpenShift 자체에 내장된 오퍼레이터 (release payload, 별도 반입 불필요)

`sandbox5462`에 이번에 설치한 **OpenShift 4.22.13**(`bootstrap.sh`가
`mirror.openshift.com/.../latest/`에서 받아온 최신 버전) 클러스터에서
`oc get clusteroperators`로 확인한 32개 — 전부 `openshift-install`이 쓰는
release image 안에 이미 포함돼 있어서, **OLM 카탈로그 반입과는 무관**하고
1~5번 섹션의 `oc-mirror` 절차 대상이 아니다. Disconnected에서는 이것들
대신 `oc adm release mirror`로 release image 자체를 통째로 사설
레지스트리에 반입하면 전부 같이 들어온다(맨 아래 "disconnected 설치 시
추가로 확인할 것" 4번 참고).

| ClusterOperator | 버전 | 역할 |
|---|---|---|
| `authentication` | 4.22.13 | OAuth/로그인 |
| `baremetal` | 4.22.13 | 베어메탈 프로비저닝 (이 클러스터는 AWS라 사실상 idle) |
| `cloud-controller-manager` | 4.22.13 | AWS 클라우드 프로바이더 연동 |
| `cloud-credential` | 4.22.13 | AWS IAM 자격증명 발급/관리 |
| `cluster-autoscaler` | 4.22.13 | ClusterAutoscaler/MachineAutoscaler 리소스 처리 |
| `config-operator` | 4.22.13 | 클러스터 전역 `config.openshift.io` 리소스 관리 |
| `console` | 4.22.13 | OpenShift 웹 콘솔 |
| `control-plane-machine-set` | 4.22.13 | 컨트롤플레인 노드(마스터) MachineSet 관리 |
| `csi-snapshot-controller` | 4.22.13 | CSI 볼륨 스냅샷 |
| `dns` | 4.22.13 | 클러스터 내부 DNS(CoreDNS) |
| `etcd` | 4.22.13 | etcd 클러스터 운영 |
| `image-registry` | 4.22.13 | 내부 컨테이너 레지스트리 |
| `ingress` | 4.22.13 | Router/IngressController (지금 self-signed 인증서 이슈가 걸린 그 컴포넌트) |
| `insights` | 4.22.13 | Red Hat Insights 원격 진단 (disconnected에서는 사실상 무의미, 비활성 권장) |
| `kube-apiserver` | 4.22.13 | Kubernetes API 서버 |
| `kube-controller-manager` | 4.22.13 | Kubernetes 컨트롤러 매니저 |
| `kube-scheduler` | 4.22.13 | Kubernetes 스케줄러 |
| `kube-storage-version-migrator` | 4.22.13 | etcd 저장 포맷 마이그레이션 |
| `machine-api` | 4.22.13 | Machine/MachineSet CRD 처리 — GPU MachineSet도 이걸 통함 |
| `machine-approver` | 4.22.13 | 신규 노드 CSR 자동 승인 |
| `machine-config` | 4.22.13 | MachineConfig/노드 OS 설정 적용 |
| `marketplace` | 4.22.13 | OperatorHub 카탈로그 소스 관리 — 1~5번 섹션 오퍼레이터들이 이걸 통해 설치됨 |
| `monitoring` | 4.22.13 | 클러스터 기본 모니터링(UWM 포함) — 우리 독립형 Prometheus/Grafana와는 별개 |
| `network` | 4.22.13 | OVN-Kubernetes CNI |
| `node-tuning` | 4.22.13 | 노드 튜닝 프로파일(PerformanceProfile 등) |
| `olm` | 4.22.13 | Operator Lifecycle Manager 본체 |
| `openshift-apiserver` | 4.22.13 | OpenShift 확장 API 서버 |
| `openshift-controller-manager` | 4.22.13 | Route/BuildConfig 등 OpenShift 전용 컨트롤러 |
| `openshift-samples` | 4.22.13 | 샘플 ImageStream/템플릿 |
| `operator-lifecycle-manager` | 4.22.13 | OLM 컨트롤러 |
| `operator-lifecycle-manager-catalog` | 4.22.13 | OLM 카탈로그 오퍼레이터 |
| `operator-lifecycle-manager-packageserver` | 4.22.13 | OLM PackageManifest API |
| `service-ca` | 4.22.13 | 클러스터 내부 서비스용 TLS 인증서 자동 발급 |
| `storage` | 4.22.13 | 기본 StorageClass(이 클러스터는 `gp3-csi`) 관리 |

## 카탈로그 소스별 요약

| 카탈로그 소스 | 오퍼레이터 개수 | 비고 |
|---|---|---|
| `redhat-operators` | 8개 | Red Hat 공식 지원 오퍼레이터 (대부분) |
| `certified-operators` | 1개 | NVIDIA GPU Operator (NVIDIA 인증) |
| `community-operators` | 2개 | Grafana Operator, 독립형 Prometheus Operator |

3개 카탈로그 소스(`redhat-operators`, `certified-operators`,
`community-operators`) 모두 `oc-mirror`로 반입 대상에 포함해야 함 — 하나라도
빠지면 해당 소스의 오퍼레이터 설치가 disconnected 환경에서 실패함.

---

## 1. 기본 클러스터 구성 (GPU 인식 + 기본 가속기)

`gpu-operator.sh`에서 설치. `harness.sh all`의 기본 경로.

| 패키지명 | 채널 | 카탈로그 소스 | 설치 네임스페이스 | 용도 |
|---|---|---|---|---|
| `nfd` | `stable` | `redhat-operators` | `openshift-nfd` | Node Feature Discovery — GPU/가속기 하드웨어 라벨링 |
| `gpu-operator-certified` | `stable` | `certified-operators` | `nvidia-gpu-operator` | NVIDIA GPU Operator (드라이버/디바이스플러그인/DCGM) |

## 2. (선택) AWS Neuron/Inferentia·Trainium NPU

`neuron-operator.sh`에서 설치. **Neuron 시나리오를 쓰지 않으면 반입 불필요.**

| 패키지명 | 채널 | 카탈로그 소스 | 설치 네임스페이스 | 용도 |
|---|---|---|---|---|
| `kernel-module-management` | `stable` | `redhat-operators` | `openshift-kmm` | KMM — 커널 모듈(Neuron 드라이버) 로더 |
| `aws-neuron-operator` | `Stable` | `community-operators` | `aws-neuron-operator` | AWS Neuron(Inferentia2/Trainium) 디바이스플러그인 |

## 3. RHOAI 3.5 + MaaS 스택

`rhoai.sh` + `maas.sh`(RHOAI-Toolkit `install-rhoai-35.sh` 위임)에서 설치.
전부 `redhat-operators` 카탈로그.

| 패키지명 | 채널 | 설치 네임스페이스 | 용도 |
|---|---|---|---|
| `rhods-operator` | `stable-3.5` (`RHOAI_CHANNEL`) | `redhat-ods-operator` | Red Hat OpenShift AI 본체 |
| `kueue-operator` | `stable-v1.3` | `openshift-operators` | Red Hat Build of Kueue — 워크로드 큐잉/스케줄링 |
| `openshift-cert-manager-operator` | `stable-v1` | `cert-manager-operator` | cert-manager — RHCL/Gateway TLS 인증서 자동화에 필수 |
| `leader-worker-set` | `stable-v1.0` | `openshift-lws-operator` | LWS — 분산 추론(멀티노드 vLLM 등) 워크로드 그룹 |
| `servicemeshoperator3` | `stable` (Manual approval) | `openshift-operators` | OpenShift Service Mesh 3 (Istio 기반) — Gateway API/MaaS 트래픽 처리 |
| `rhcl-operator` | `stable` (Manual approval) | `openshift-operators` | Red Hat Connectivity Link — Kuadrant 배선. 아래 3개를 OLM 의존성으로 자동 반입 |
| ┗ `authorino-operator` | (RHCL 의존성으로 자동 해석) | `kuadrant-system` | MaaS 인증(SubjectAccessReview 기반 API 키 검증) |
| ┗ `limitador-operator` | (RHCL 의존성으로 자동 해석) | `kuadrant-system` | MaaS 레이트리미팅 |
| ┗ `dns-operator` | (RHCL 의존성으로 자동 해석) | `kuadrant-system` | RHCL 자체 DNS 라우팅 보조 |

**주의**: `rhcl-operator`/`servicemeshoperator3`는 `installPlanApproval: Manual`로
고정돼 있음(v1.4.0의 WASM 플러그인 버그 회피를 위한 임시 핀). `oc-mirror`로 반입할
때 최신 버전만 받지 말고, 스크립트가 기대하는 특정 채널 전체(또는 최소한 현재
운영 중인 버전 근처)를 포함하도록 `ImageSetConfiguration`을 구성할 것 — Manual
approval 오퍼레이터는 사설 카탈로그에 해당 버전의 번들 이미지가 없으면 그냥
InstallPlan이 안 뜨고 조용히 멈춘다.

## 4. 모니터링

`grafana-operator.sh` + `dcgm-alerts.sh`에서 설치 (`harness.sh monitoring-all`).

| 패키지명 | 채널 | 카탈로그 소스 | 설치 네임스페이스 | 용도 |
|---|---|---|---|---|
| `grafana-operator` | `v5` | `community-operators` | `gpu-monitoring` | GrafanaDashboard CR 기반 대시보드 |
| `prometheus` | `beta` | `community-operators` | `gpu-monitoring` | 독립형 Prometheus Operator — GPU 온도/XID 알림용 (UWM 테넌트 격리와 분리) |

## 5. 로깅

`openshift-logging.sh`에서 설치 (`harness.sh openshift-logging`).

| 패키지명 | 채널 | 카탈로그 소스 | 설치 네임스페이스 | 용도 |
|---|---|---|---|---|
| `loki-operator` | `stable-6.6` | `redhat-operators` | `openshift-operators-redhat` | LokiStack 운영 |
| `cluster-logging` | `stable-6.6` | `redhat-operators` | `openshift-logging` | ClusterLogForwarder — Pod 삭제 후에도 로그 보존 |

---

## disconnected 설치 시 추가로 확인할 것

1. **카탈로그 소스 자체의 반입**: `redhat-operators`/`certified-operators`/
   `community-operators` 인덱스 이미지 3개를 전부 미러링하고, 사설
   `CatalogSource` 3개(각 소스별로 하나씩)를 클러스터에 등록해야 함. 위
   표의 `source:` 필드가 정확히 이 3개 중 하나를 가리키므로, 하나만
   빠뜨려도 그 카탈로그 소속 오퍼레이터가 전부 설치 실패함.
2. **NVIDIA GPU Operator 추가 이미지**: `certified-operators`의 오퍼레이터
   번들 자체 말고도, `ClusterPolicy`가 나중에 당겨오는 드라이버 컨테이너
   이미지(NVIDIA 드라이버, DCGM exporter, container-toolkit 등)는
   오퍼레이터 미러링과 별개로 추가 반입이 필요함 (오퍼레이터 미러링은
   OLM 번들/카탈로그만 포함, 오퍼레이터가 나중에 배포하는 워크로드
   이미지는 미포함).
3. **RHOAI-Toolkit(`install-rhoai-35.sh`) 자체의 외부 리소스 의존성**:
   Let's Encrypt(외부 ACME 서버 접근), SearXNG MCP 컨테이너 이미지 등
   오퍼레이터가 아닌 별도 컨테이너/외부 API 의존성이 있음 — disconnected
   환경에서는 Let's Encrypt 단계가 원천적으로 불가능하므로 self-signed
   인증서 경로만 쓰게 되고(`lessonlearn.md` #4/#5 참고), SearXNG 등 부가
   이미지도 별도로 반입해야 함.
4. **OpenShift 릴리스 페이로드**: `bootstrap.sh`가 지금은
   `mirror.openshift.com`에서 "latest"를 받아오는데, disconnected에서는
   `oc adm release mirror`로 원하는 정확한 버전을 먼저 사설 레지스트리에
   반입하고 `install-config.yaml`의 `imageContentSources`를 그에 맞게
   구성해야 함 — 이 하네스는 현재 이 부분을 자동화하지 않으므로 수동
   준비 필요.
