#!/usr/bin/env bash
# Installs OpenShift Logging (Loki-based) so pod logs survive scale-to-zero
# (or any pod deletion) instead of disappearing with the pod -- needed for
# scenario 10 (monitoring a KEDA scale-to-zero InferenceService) but wired
# into `all` as a default so every fresh cluster has it from the start.
#
# LokiStack has no PVC-only mode -- it requires S3-compatible object
# storage. This lab has no real cloud object storage, so MinIO runs
# in-cluster to fill that role (the officially documented Red Hat approach
# for object-storage-less test/demo environments). Runs ON the bastion.
#
# NOT YET LIVE-VALIDATED on this cluster as of the day this was written
# (2026-08-20) -- written from documented Loki Operator / OpenShift Logging
# 6.x patterns, to be verified against the real cluster during scenario 10's
# build. If field names below don't match what this cluster's operator
# versions actually expect, fix here and update this comment.
set -euo pipefail
export KUBECONFIG="$HOME/ocp-install/auth/kubeconfig"

MINIO_NAMESPACE="${MINIO_NAMESPACE:-minio}"
LOGGING_NAMESPACE="${LOGGING_NAMESPACE:-openshift-logging}"
MINIO_ACCESS_KEY="${MINIO_ACCESS_KEY:-minioadmin}"
MINIO_SECRET_KEY="${MINIO_SECRET_KEY:-minioadmin123}"
MINIO_BUCKET="${MINIO_BUCKET:-loki-logs}"

echo "=== MinIO (in-cluster S3 for LokiStack) ==="
oc apply -f - <<YAML
apiVersion: v1
kind: Namespace
metadata:
  name: ${MINIO_NAMESPACE}
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: minio-data
  namespace: ${MINIO_NAMESPACE}
spec:
  accessModes: ["ReadWriteOnce"]
  resources:
    requests:
      storage: 20Gi
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: minio
  namespace: ${MINIO_NAMESPACE}
spec:
  replicas: 1
  selector:
    matchLabels:
      app: minio
  template:
    metadata:
      labels:
        app: minio
    spec:
      containers:
      - name: minio
        image: quay.io/minio/minio:latest
        args: ["server", "/data", "--console-address", ":9090"]
        env:
        - name: MINIO_ROOT_USER
          value: "${MINIO_ACCESS_KEY}"
        - name: MINIO_ROOT_PASSWORD
          value: "${MINIO_SECRET_KEY}"
        - name: MINIO_DEFAULT_BUCKETS
          value: "${MINIO_BUCKET}"
        ports:
        - containerPort: 9000
          name: api
        - containerPort: 9090
          name: console
        volumeMounts:
        - name: data
          mountPath: /data
        readinessProbe:
          httpGet:
            path: /minio/health/ready
            port: 9000
          initialDelaySeconds: 10
      volumes:
      - name: data
        persistentVolumeClaim:
          claimName: minio-data
---
apiVersion: v1
kind: Service
metadata:
  name: minio
  namespace: ${MINIO_NAMESPACE}
spec:
  selector:
    app: minio
  ports:
  - name: api
    port: 9000
    targetPort: 9000
  - name: console
    port: 9090
    targetPort: 9090
YAML

echo "Waiting for MinIO pod to be Ready..."
oc wait --for=condition=Available deployment/minio -n "${MINIO_NAMESPACE}" --timeout=180s

# MINIO_DEFAULT_BUCKETS auto-creates the bucket on first startup, so no
# separate `mc mb` job is needed.

echo "=== Loki Operator + Red Hat OpenShift Logging Operator ==="
oc apply -f - <<YAML
apiVersion: v1
kind: Namespace
metadata:
  name: openshift-operators-redhat
  labels:
    openshift.io/cluster-monitoring: "true"
---
apiVersion: operators.coreos.com/v1
kind: OperatorGroup
metadata:
  name: openshift-operators-redhat
  namespace: openshift-operators-redhat
spec: {}
---
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: loki-operator
  namespace: openshift-operators-redhat
spec:
  channel: stable
  name: loki-operator
  source: redhat-operators
  sourceNamespace: openshift-marketplace
---
apiVersion: v1
kind: Namespace
metadata:
  name: ${LOGGING_NAMESPACE}
---
apiVersion: operators.coreos.com/v1
kind: OperatorGroup
metadata:
  name: ${LOGGING_NAMESPACE}
  namespace: ${LOGGING_NAMESPACE}
spec:
  targetNamespaces:
  - ${LOGGING_NAMESPACE}
---
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: cluster-logging
  namespace: ${LOGGING_NAMESPACE}
spec:
  channel: stable
  name: cluster-logging
  source: redhat-operators
  sourceNamespace: openshift-marketplace
YAML

echo "Waiting for Loki Operator + Cluster Logging Operator CSVs..."
for _ in $(seq 1 40); do
  loki_ok=$(oc get csv -n openshift-operators-redhat 2>/dev/null | grep -i loki | grep -qi succeeded && echo yes || echo no)
  cl_ok=$(oc get csv -n "${LOGGING_NAMESPACE}" 2>/dev/null | grep -i cluster-logging | grep -qi succeeded && echo yes || echo no)
  [ "$loki_ok" = "yes" ] && [ "$cl_ok" = "yes" ] && break
  sleep 15
done

echo "=== LokiStack (backed by MinIO) ==="
oc create secret generic logging-loki-s3 -n "${LOGGING_NAMESPACE}" \
  --from-literal=bucketnames="${MINIO_BUCKET}" \
  --from-literal=endpoint="http://minio.${MINIO_NAMESPACE}.svc.cluster.local:9000" \
  --from-literal=access_key_id="${MINIO_ACCESS_KEY}" \
  --from-literal=access_key_secret="${MINIO_SECRET_KEY}" \
  --from-literal=region="us-east-1" \
  --dry-run=client -o yaml | oc apply -f -

oc apply -f - <<YAML
apiVersion: loki.grafana.com/v1
kind: LokiStack
metadata:
  name: logging-loki
  namespace: ${LOGGING_NAMESPACE}
spec:
  size: 1x.demo
  storage:
    schemas:
    - version: v13
      effectiveDate: "2024-01-01"
    secret:
      name: logging-loki-s3
      type: s3
  storageClassName: gp3-csi
  tenants:
    mode: openshift-logging
YAML

echo "Waiting for LokiStack pods..."
for _ in $(seq 1 40); do
  oc get pods -n "${LOGGING_NAMESPACE}" -l app.kubernetes.io/name=lokistack 2>/dev/null | grep -q Running && break
  sleep 15
done

echo "=== ClusterLogForwarder (ship application logs to LokiStack) ==="
oc apply -f - <<YAML
apiVersion: v1
kind: ServiceAccount
metadata:
  name: logging-collector
  namespace: ${LOGGING_NAMESPACE}
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: logging-collector-logs
subjects:
- kind: ServiceAccount
  name: logging-collector
  namespace: ${LOGGING_NAMESPACE}
roleRef:
  kind: ClusterRole
  name: collect-application-logs
  apiGroup: rbac.authorization.k8s.io
---
apiVersion: observability.openshift.io/v1
kind: ClusterLogForwarder
metadata:
  name: instance
  namespace: ${LOGGING_NAMESPACE}
spec:
  serviceAccount:
    name: logging-collector
  outputs:
  - name: default-loki
    type: lokiStack
    lokiStack:
      target:
        name: logging-loki
        namespace: ${LOGGING_NAMESPACE}
      authentication:
        token:
          from: serviceAccount
  pipelines:
  - name: application-logs
    inputRefs:
    - application
    outputRefs:
    - default-loki
YAML

echo "OpenShift Logging installed: MinIO (${MINIO_NAMESPACE}) -> LokiStack (${LOGGING_NAMESPACE}) -> ClusterLogForwarder."
echo "Query logs via the OpenShift console's Observe -> Logs tab, or add a Loki datasource"
echo "(http://logging-loki-gateway-http.${LOGGING_NAMESPACE}.svc.cluster.local:8080/api/logs/v1/application) to Grafana."
