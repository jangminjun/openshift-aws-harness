#!/usr/bin/env bash
# Reusable harness for standing up self-managed OpenShift + OpenShift AI on AWS
# via a bastion jump host. Idempotent: safe to re-run any subcommand.
#
# Usage: ./harness.sh <subcommand> [args]
#   bastion-up          create VPC/subnet/IGW/SG/keypair/EC2 bastion (or reuse existing)
#   bastion-bootstrap    install openshift-install/oc on the bastion
#   push-pull-secret     copy your Red Hat pull secret to the bastion
#   install-config       generate install-config.yaml on the bastion
#   create-cluster        start `openshift-install create cluster` in the background
#   wait-cluster            block and tail until install completes or fails
#   create-admin-user        add an HTPasswd cluster-admin user (ADMIN_USERNAME/ADMIN_PASSWORD)
#   status                    show bastion + cluster status
#   kubeconfig                  fetch kubeconfig to ./harness/state/<cluster>-kubeconfig
#   gpu-machineset                add a GPU worker MachineSet
#   gpu-operator                    install NFD + NVIDIA GPU Operator
#   neuron-machineset                 add an AWS Neuron (Inferentia2/Trainium) worker MachineSet
#   neuron-operator                     install KMM + AWS Neuron Operator + DeviceConfig
#   cluster-autoscaler                    enable the cluster-wide ClusterAutoscaler (MAX_NODES_TOTAL)
#   machine-autoscaler                      MachineAutoscaler for one MachineSet (MACHINESET_NAME/MIN_REPLICAS/MAX_REPLICAS)
#   rhoai                              install OpenShift AI operator + DataScienceCluster
#   enable-monitoring                    enable User Workload Monitoring + user Alertmanager config
#   grafana                                install Grafana Operator + Thanos-querier datasource
#   dcgm-alerts                              GPU temp/XID PrometheusRule + Slack AlertmanagerConfig
#   dashboards                                  apply Tier1 (infra) / Tier2 (tenant) Grafana dashboards
#   monitoring-all                                enable-monitoring + grafana + dcgm-alerts + dashboards
#   all                                    run the full cluster+GPU+RHOAI sequence, end to end
#   destroy-cluster                          openshift-install destroy cluster
#   destroy-bastion --yes                      tear down bastion + its network (destructive)
#
# Config is read from config.env; override any variable via environment, e.g.:
#   CLUSTER_NAME=demo2 AWS_REGION=us-west-2 ./harness.sh bastion-up
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"

source ./config.env
source ./lib.sh

cmd="${1:-}"; shift || true

cmd_bastion_up() {
  load_state
  aws ec2 describe-key-pairs --key-names "${CLUSTER_NAME}-bastion-key" --region "$AWS_REGION" >/dev/null 2>&1 || {
    [ -f "${SSH_KEY_PATH}" ] || { mkdir -p "$(dirname "$SSH_KEY_PATH")"; ssh-keygen -t ed25519 -f "$SSH_KEY_PATH" -N "" -C "${CLUSTER_NAME}-bastion" -q; }
    aws ec2 import-key-pair --key-name "${CLUSTER_NAME}-bastion-key" \
      --public-key-material "fileb://${SSH_KEY_PATH}.pub" --region "$AWS_REGION" >/dev/null
    log "Imported key pair ${CLUSTER_NAME}-bastion-key"
  }

  if [ -z "${VPC_ID:-}" ] || ! aws ec2 describe-vpcs --vpc-ids "$VPC_ID" --region "$AWS_REGION" >/dev/null 2>&1; then
    VPC_ID=$(aws ec2 create-vpc --cidr-block "$VPC_CIDR" \
      --tag-specifications "ResourceType=vpc,Tags=[{Key=Name,Value=${CLUSTER_NAME}-bastion-vpc}]" \
      --query 'Vpc.VpcId' --output text --region "$AWS_REGION")
    aws ec2 modify-vpc-attribute --vpc-id "$VPC_ID" --enable-dns-support --region "$AWS_REGION"
    aws ec2 modify-vpc-attribute --vpc-id "$VPC_ID" --enable-dns-hostnames --region "$AWS_REGION"
    save_state VPC_ID "$VPC_ID"
    log "Created VPC $VPC_ID"
  else
    log "Reusing VPC $VPC_ID"
  fi

  if [ -z "${SUBNET_ID:-}" ] || ! aws ec2 describe-subnets --subnet-ids "$SUBNET_ID" --region "$AWS_REGION" >/dev/null 2>&1; then
    SUBNET_ID=$(aws ec2 create-subnet --vpc-id "$VPC_ID" --cidr-block "$SUBNET_CIDR" \
      --availability-zone "$AVAILABILITY_ZONE" \
      --tag-specifications "ResourceType=subnet,Tags=[{Key=Name,Value=${CLUSTER_NAME}-bastion-subnet}]" \
      --query 'Subnet.SubnetId' --output text --region "$AWS_REGION")
    aws ec2 modify-subnet-attribute --subnet-id "$SUBNET_ID" --map-public-ip-on-launch --region "$AWS_REGION"
    save_state SUBNET_ID "$SUBNET_ID"
    log "Created subnet $SUBNET_ID"
  else
    log "Reusing subnet $SUBNET_ID"
  fi

  if [ -z "${IGW_ID:-}" ] || ! aws ec2 describe-internet-gateways --internet-gateway-ids "$IGW_ID" --region "$AWS_REGION" >/dev/null 2>&1; then
    IGW_ID=$(aws ec2 create-internet-gateway \
      --tag-specifications "ResourceType=internet-gateway,Tags=[{Key=Name,Value=${CLUSTER_NAME}-bastion-igw}]" \
      --query 'InternetGateway.InternetGatewayId' --output text --region "$AWS_REGION")
    aws ec2 attach-internet-gateway --vpc-id "$VPC_ID" --internet-gateway-id "$IGW_ID" --region "$AWS_REGION"
    save_state IGW_ID "$IGW_ID"
    log "Created + attached IGW $IGW_ID"
  else
    log "Reusing IGW $IGW_ID"
  fi

  if [ -z "${RTB_ID:-}" ] || ! aws ec2 describe-route-tables --route-table-ids "$RTB_ID" --region "$AWS_REGION" >/dev/null 2>&1; then
    RTB_ID=$(aws ec2 create-route-table --vpc-id "$VPC_ID" \
      --tag-specifications "ResourceType=route-table,Tags=[{Key=Name,Value=${CLUSTER_NAME}-bastion-rtb}]" \
      --query 'RouteTable.RouteTableId' --output text --region "$AWS_REGION")
    aws ec2 create-route --route-table-id "$RTB_ID" --destination-cidr-block 0.0.0.0/0 --gateway-id "$IGW_ID" --region "$AWS_REGION" >/dev/null
    aws ec2 associate-route-table --subnet-id "$SUBNET_ID" --route-table-id "$RTB_ID" --region "$AWS_REGION" >/dev/null
    save_state RTB_ID "$RTB_ID"
    log "Created route table $RTB_ID"
  else
    log "Reusing route table $RTB_ID"
  fi

  if [ -z "${SG_ID:-}" ] || ! aws ec2 describe-security-groups --group-ids "$SG_ID" --region "$AWS_REGION" >/dev/null 2>&1; then
    SG_ID=$(aws ec2 create-security-group --group-name "${CLUSTER_NAME}-bastion-sg" \
      --description "Bastion SSH access" --vpc-id "$VPC_ID" --query 'GroupId' --output text --region "$AWS_REGION")
    aws ec2 authorize-security-group-ingress --group-id "$SG_ID" --protocol tcp --port 22 \
      --cidr "$SSH_CIDR" --region "$AWS_REGION" >/dev/null
    save_state SG_ID "$SG_ID"
    log "Created security group $SG_ID (SSH from $SSH_CIDR)"
  else
    log "Reusing security group $SG_ID"
  fi

  load_state
  if [ -z "${INSTANCE_ID:-}" ] || [ "$(aws ec2 describe-instances --instance-ids "$INSTANCE_ID" --region "$AWS_REGION" \
        --query 'Reservations[0].Instances[0].State.Name' --output text 2>/dev/null)" != "running" ] && \
     [ "$(aws ec2 describe-instances --instance-ids "${INSTANCE_ID:-x}" --region "$AWS_REGION" \
        --query 'Reservations[0].Instances[0].State.Name' --output text 2>/dev/null)" != "pending" ]; then
    AMI_ID=$(aws ssm get-parameter --name "$BASTION_AMI_SSM_PARAM" --query 'Parameter.Value' --output text --region "$AWS_REGION")
    INSTANCE_ID=$(aws ec2 run-instances --image-id "$AMI_ID" --instance-type "$BASTION_INSTANCE_TYPE" \
      --key-name "${CLUSTER_NAME}-bastion-key" --subnet-id "$SUBNET_ID" --security-group-ids "$SG_ID" \
      --associate-public-ip-address \
      --block-device-mappings '[{"DeviceName":"/dev/xvda","Ebs":{"VolumeSize":50,"VolumeType":"gp3"}}]' \
      --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=${CLUSTER_NAME}-bastion}]" \
      --query 'Instances[0].InstanceId' --output text --region "$AWS_REGION")
    save_state INSTANCE_ID "$INSTANCE_ID"
    log "Launched bastion instance $INSTANCE_ID"
    aws ec2 wait instance-running --instance-ids "$INSTANCE_ID" --region "$AWS_REGION"
  else
    log "Reusing bastion instance $INSTANCE_ID"
  fi

  PUBLIC_IP=$(aws ec2 describe-instances --instance-ids "$INSTANCE_ID" --region "$AWS_REGION" \
    --query 'Reservations[0].Instances[0].PublicIpAddress' --output text)
  save_state PUBLIC_IP "$PUBLIC_IP"
  save_state KEY_NAME "${CLUSTER_NAME}-bastion-key"
  log "Bastion ready at ${PUBLIC_IP}"
  wait_for_ssh
}

cmd_bastion_bootstrap() { ssh_bastion 'bash -s' < ./remote/bootstrap.sh; }

cmd_push_pull_secret() {
  local src="${1:-$PULL_SECRET_FILE}"
  [ -f "$src" ] || err "Pull secret not found at $src. Download it from console.redhat.com/openshift/install/pull-secret"
  ssh_bastion "mkdir -p ~/ocp-install"
  scp_to_bastion "$src" "~/ocp-install/pull-secret.json"
  ssh_bastion "chmod 600 ~/ocp-install/pull-secret.json && jq -e . ~/ocp-install/pull-secret.json >/dev/null && echo 'pull secret OK'"
}

cmd_install_config() {
  ssh_bastion "CLUSTER_NAME='$CLUSTER_NAME' AWS_REGION='$AWS_REGION' BASE_DOMAIN='$BASE_DOMAIN' \
    MASTER_TYPE='$MASTER_TYPE' MASTER_REPLICAS='$MASTER_REPLICAS' \
    WORKER_TYPE='$WORKER_TYPE' WORKER_REPLICAS='$WORKER_REPLICAS' bash -s" < ./remote/gen-install-config.sh
}

cmd_create_cluster() { ssh_bastion 'bash -s' < ./remote/create-cluster.sh; }

cmd_create_admin_user() {
  ssh_bastion "ADMIN_USERNAME='$ADMIN_USERNAME' ADMIN_PASSWORD='$ADMIN_PASSWORD' \
    CLUSTER_NAME='$CLUSTER_NAME' BASE_DOMAIN='$BASE_DOMAIN' bash -s" < ./remote/create-admin-user.sh
}

cmd_wait_cluster() {
  ssh_bastion '
    until grep -qE "Install complete|level=fatal|failed to fetch" ~/ocp-install/install.log 2>/dev/null; do
      sleep 30
    done
    tail -40 ~/ocp-install/install.log
  '
}

cmd_status() {
  load_state
  echo "cluster:     $CLUSTER_NAME"
  echo "bastion ip:  ${PUBLIC_IP:-<none>}"
  echo "instance id: ${INSTANCE_ID:-<none>}"
  [ -n "${PUBLIC_IP:-}" ] || { echo "no bastion in state"; return 0; }
  ssh_bastion '
    echo "---- install.log tail ----"
    tail -n 15 ~/ocp-install/install.log 2>/dev/null || echo "(not started)"
    if [ -f ~/ocp-install/auth/kubeconfig ]; then
      export KUBECONFIG=~/ocp-install/auth/kubeconfig
      echo "---- nodes ----"; oc get nodes 2>/dev/null
      echo "---- clusterversion ----"; oc get clusterversion 2>/dev/null
    fi
  ' || true
}

cmd_kubeconfig() {
  load_state
  mkdir -p ./state
  scp -o StrictHostKeyChecking=accept-new -i "$SSH_KEY_PATH" \
    "ec2-user@${PUBLIC_IP}:~/ocp-install/auth/kubeconfig" "./state/${CLUSTER_NAME}-kubeconfig"
  log "Saved to ./state/${CLUSTER_NAME}-kubeconfig -- export KUBECONFIG=$(pwd)/state/${CLUSTER_NAME}-kubeconfig"
}

cmd_gpu_machineset() {
  ssh_bastion "GPU_INSTANCE_TYPE='$GPU_INSTANCE_TYPE' GPU_REPLICAS='$GPU_REPLICAS' \
    GPU_MACHINESET_AZ='$GPU_MACHINESET_AZ' bash -s" < ./remote/gpu-machineset.sh
}

cmd_neuron_machineset() {
  ssh_bastion "NEURON_INSTANCE_TYPE='$NEURON_INSTANCE_TYPE' NEURON_REPLICAS='$NEURON_REPLICAS' \
    NEURON_MACHINESET_AZ='$NEURON_MACHINESET_AZ' bash -s" < ./remote/neuron-machineset.sh
}

cmd_neuron_operator() { ssh_bastion 'bash -s' < ./remote/neuron-operator.sh; }

cmd_gpu_operator() { ssh_bastion 'bash -s' < ./remote/gpu-operator.sh; }
cmd_rhoai()        { ssh_bastion 'bash -s' < ./remote/rhoai.sh; }

cmd_cluster_autoscaler() {
  ssh_bastion "MAX_NODES_TOTAL='${MAX_NODES_TOTAL:-20}' bash -s" < ./remote/cluster-autoscaler.sh
}

cmd_machine_autoscaler() {
  ssh_bastion "MACHINESET_NAME='${MACHINESET_NAME:?set MACHINESET_NAME}' MIN_REPLICAS='${MIN_REPLICAS:?set MIN_REPLICAS}' \
    MAX_REPLICAS='${MAX_REPLICAS:?set MAX_REPLICAS}' AUTOSCALER_NAME='${AUTOSCALER_NAME:-}' bash -s" < ./remote/machine-autoscaler.sh
}

cmd_enable_monitoring() {
  ssh_bastion "MONITORING_NAMESPACE='$MONITORING_NAMESPACE' bash -s" < ./remote/enable-monitoring.sh
}

cmd_grafana() {
  ssh_bastion "MONITORING_NAMESPACE='$MONITORING_NAMESPACE' bash -s" < ./remote/grafana-operator.sh
}

cmd_dcgm_alerts() {
  ssh_bastion "MONITORING_NAMESPACE='$MONITORING_NAMESPACE' GPU_TEMP_THRESHOLD_C='$GPU_TEMP_THRESHOLD_C' \
    SLACK_WEBHOOK_URL='$SLACK_WEBHOOK_URL' SLACK_CHANNEL='$SLACK_CHANNEL' bash -s" < ./remote/dcgm-alerts.sh
}

cmd_dashboards() {
  ssh_bastion "mkdir -p ~/ocp-install"
  scp_to_bastion ./remote/dashboards/tier1-global.json "~/ocp-install/tier1-global.json"
  scp_to_bastion ./remote/dashboards/tier2-tenant.json "~/ocp-install/tier2-tenant.json"
  ssh_bastion "MONITORING_NAMESPACE='$MONITORING_NAMESPACE' bash -s" < ./remote/apply-dashboards.sh
}

cmd_monitoring_all() {
  cmd_enable_monitoring
  cmd_grafana
  cmd_dcgm_alerts
  cmd_dashboards
}

cmd_destroy_cluster() {
  ssh_bastion 'export PATH=$PATH:/usr/local/bin; cd ~/ocp-install && openshift-install destroy cluster --dir=. --log-level=info'
}

cmd_destroy_bastion() {
  [ "${1:-}" = "--yes" ] || err "This terminates the bastion + its network. Re-run with --yes to confirm."
  load_state
  [ -n "${INSTANCE_ID:-}" ] && aws ec2 terminate-instances --instance-ids "$INSTANCE_ID" --region "$AWS_REGION" >/dev/null && \
    aws ec2 wait instance-terminated --instance-ids "$INSTANCE_ID" --region "$AWS_REGION" && log "Terminated $INSTANCE_ID"
  [ -n "${SG_ID:-}" ] && aws ec2 delete-security-group --group-id "$SG_ID" --region "$AWS_REGION" && log "Deleted SG $SG_ID"
  if [ -n "${RTB_ID:-}" ]; then
    assoc=$(aws ec2 describe-route-tables --route-table-ids "$RTB_ID" --region "$AWS_REGION" \
      --query 'RouteTables[0].Associations[?Main==`false`].RouteTableAssociationId' --output text)
    [ -n "$assoc" ] && aws ec2 disassociate-route-table --association-id "$assoc" --region "$AWS_REGION"
    aws ec2 delete-route-table --route-table-id "$RTB_ID" --region "$AWS_REGION" && log "Deleted route table $RTB_ID"
  fi
  [ -n "${IGW_ID:-}" ] && aws ec2 detach-internet-gateway --internet-gateway-id "$IGW_ID" --vpc-id "$VPC_ID" --region "$AWS_REGION" && \
    aws ec2 delete-internet-gateway --internet-gateway-id "$IGW_ID" --region "$AWS_REGION" && log "Deleted IGW $IGW_ID"
  [ -n "${SUBNET_ID:-}" ] && aws ec2 delete-subnet --subnet-id "$SUBNET_ID" --region "$AWS_REGION" && log "Deleted subnet $SUBNET_ID"
  [ -n "${VPC_ID:-}" ] && aws ec2 delete-vpc --vpc-id "$VPC_ID" --region "$AWS_REGION" && log "Deleted VPC $VPC_ID"
  aws ec2 delete-key-pair --key-name "${CLUSTER_NAME}-bastion-key" --region "$AWS_REGION" || true
  rm -f "$STATE_FILE"
  log "Bastion + network torn down."
}

cmd_all() {
  cmd_bastion_up
  cmd_bastion_bootstrap
  cmd_push_pull_secret
  cmd_install_config
  cmd_create_cluster
  cmd_wait_cluster
  cmd_gpu_machineset
  cmd_gpu_operator
  cmd_rhoai
}

case "$cmd" in
  bastion-up)        cmd_bastion_up ;;
  bastion-bootstrap)  cmd_bastion_bootstrap ;;
  push-pull-secret)    cmd_push_pull_secret "$@" ;;
  install-config)       cmd_install_config ;;
  create-cluster)         cmd_create_cluster ;;
  wait-cluster)             cmd_wait_cluster ;;
  create-admin-user)         cmd_create_admin_user ;;
  status)                     cmd_status ;;
  kubeconfig)                  cmd_kubeconfig ;;
  gpu-machineset)                cmd_gpu_machineset ;;
  gpu-operator)                     cmd_gpu_operator ;;
  neuron-machineset)                  cmd_neuron_machineset ;;
  neuron-operator)                      cmd_neuron_operator ;;
  cluster-autoscaler)                     cmd_cluster_autoscaler ;;
  machine-autoscaler)                       cmd_machine_autoscaler ;;
  rhoai)                              cmd_rhoai ;;
  enable-monitoring)                    cmd_enable_monitoring ;;
  grafana)                                cmd_grafana ;;
  dcgm-alerts)                              cmd_dcgm_alerts ;;
  dashboards)                                 cmd_dashboards ;;
  monitoring-all)                               cmd_monitoring_all ;;
  destroy-cluster)                     cmd_destroy_cluster ;;
  destroy-bastion)                      cmd_destroy_bastion "$@" ;;
  all)                                    cmd_all ;;
  *) err "Unknown subcommand '$cmd'. See header comment in $0 for the list." ;;
esac
