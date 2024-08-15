#!/bin/bash

RETRY_SEC=${RETRY_SEC:-1}
RETRY_TIMES=${RETRY_TIMES:-10}

retry() {
  local -r cmd="$@"
  local -i retries=1
  until $cmd; do
    sleep $RETRY_SEC
    [[ retries -eq $RETRY_TIMES ]] && echo "Something went wrong, please try again. If issue persists please notify CAST AI team" && return 1
    echo "Still executing..."
    let retries=current_nsretries+1
  done
}

fatal() {
  echo -e "\033[31m\033[1m$1\033[0m"
  exit 1
}

CASTAI_API_URL="${CASTAI_API_URL:-https://api.cast.ai}"
CASTAI_GRPC_URL="${CASTAI_GRPC_URL:-grpc.cast.ai:443}"
CASTAI_API_GRPC_URL="${CASTAI_API_GRPC_URL:-api-grpc.cast.ai:443}"

kubectl get namespace castai-agent >/dev/null 2>&1
if [ $? -eq 1 ]; then
  fatal "Cast AI namespace not found. Please run phase1 of the onboarding script first."
fi

if [ -z $CASTAI_API_TOKEN ] || [ -z $CASTAI_API_URL ] || [ -z $CASTAI_CLUSTER_ID ]; then
  fatal "CASTAI_API_TOKEN, CASTAI_API_URL or CASTAI_CLUSTER_ID variables were not provided"
fi

if ! [ -x "$(command -v az)" ]; then
  fatal "Error: azure cli is not installed"
fi

if ! [ -x "$(command -v helm)" ]; then
  fatal "Error: helm is not installed. (helm is required to install castai-cluster-controller)"
fi

if [ -z $REGION ]; then
  fatal "REGION environment variable was not provided"
fi

function enable_base_components() {
  echo "Installing castai-cluster-controller."
  helm upgrade -i cluster-controller castai-helm/castai-cluster-controller -n castai-agent \
    --set castai.apiKey=$CASTAI_API_TOKEN \
    --set castai.apiURL=$CASTAI_API_URL \
    --set castai.clusterID=$CASTAI_CLUSTER_ID \
    --set aks.enabled=true \
    --set autoscaling.enabled=$INSTALL_AUTOSCALER
  echo "Finished installing castai-cluster-controller."
}

function enable_autoscaler_agent() {
  echo "Installing autoscaler"

  echo "Installing autoscaler cluster components"

  echo "Installing castai-spot-handler."
  helm upgrade -i castai-spot-handler castai-helm/castai-spot-handler -n castai-agent \
    --set castai.apiURL=$CASTAI_API_URL \
    --set castai.clusterID=$CASTAI_CLUSTER_ID \
    --set castai.provider=azure
  echo "Finished installing castai-azure-spot-handler."

  echo "Installing castai-evictor."
  helm upgrade -i castai-evictor castai-helm/castai-evictor -n castai-agent --set replicaCount=0
  echo "Finished installing castai-evictor."

  if [[ $INSTALL_POD_PINNER = "true" ]]; then
    echo "Installing castai-pod-pinner."
    helm upgrade -i castai-pod-pinner castai-helm/castai-pod-pinner -n castai-agent \
      --set castai.apiURL=$CASTAI_API_URL \
      --set castai.grpcURL=$CASTAI_GRPC_URL \
      --set castai.apiKey=$CASTAI_API_TOKEN \
      --set castai.clusterID=$CASTAI_CLUSTER_ID \
      --set replicaCount=0
    echo "Finished installing castai-pod-pinner."
  fi

  if [[ $INSTALL_NVIDIA_DEVICE_PLUGIN = "true" ]]; then
    kubectl apply -f - <<EOF
apiVersion: apps/v1
kind: DaemonSet
metadata:
name: nvidia-device-plugin-daemonset
namespace: kube-system
spec:
selector:
matchLabels:
name: nvidia-device-plugin-ds
updateStrategy:
type: RollingUpdate
template:
metadata:
labels:
name: nvidia-device-plugin-ds
spec:
tolerations:
- key: nvidia.com/gpu
operator: Exists
effect: NoSchedule
# Mark this pod as a critical add-on; when enabled, the critical add-on
# scheduler reserves resources for critical add-on pods so that they can
# be rescheduled after a failure.
# See https://kubernetes.io/docs/tasks/administer-cluster/guaranteed-scheduling-critical-addon-pods/
priorityClassName: "system-node-critical"
containers:
- image: nvcr.io/nvidia/k8s-device-plugin:v0.15.0-rc.2
name: nvidia-device-plugin-ctr
env:
- name: FAIL_ON_INIT_ERROR
  value: "false"
securityContext:
allowPrivilegeEscalation: false
capabilities:
  drop: ["ALL"]
volumeMounts:
- name: device-plugin
mountPath: /var/lib/kubelet/device-plugins
volumes:
- name: device-plugin
hostPath:
path: /var/lib/kubelet/device-plugins
EOF
  fi

}

function enable_security_agent() {
  echo "Installing security agent"

  echo "Installing autoscaling cluster components"
  echo "Installing castai-kvisor."
  helm upgrade -i castai-kvisor castai-helm/castai-kvisor -n castai-agent \
    --set castai.grpcAddr=$CASTAI_API_GRPC_URL \
    --set castai.apiKey=$CASTAI_API_TOKEN \
    --set castai.clusterID=$CASTAI_CLUSTER_ID \
    --set controller.extraArgs.kube-linter-enabled=true \
    --set controller.extraArgs.image-scan-enabled=true \
    --set controller.extraArgs.kube-bench-enabled=true \
    --set controller.extraArgs.kube-bench-cloud-provider=aks
  echo "Finished installing castai-kvisor."
}

helm repo add castai-helm https://castai.github.io/helm-charts
helm repo update castai-helm

enable_base_components

if [[ $INSTALL_AUTOSCALER = "true" ]]; then
  enable_autoscaler_agent
fi

if [[ $INSTALL_SECURITY_AGENT = "true" ]]; then
  enable_security_agent
fi

if [[ $INSTALL_GPU_METRICS_EXPORTER = "true" ]]; then
  SKIP_HELM_UPDATE="true"
  K8S_PROVIDER="aks"
  #!/bin/bash

  ######################################################################################################
  # This script installs the gpu-metrics-exporter chart from the CAST AI helm repository.              #
  # It checks the cluster for the presence of dcgm-exporter and nv-hostengine and configures the       #
  # gpu-metrics-exporter chart accordingly.                                                            #
  # If both dcgm-exporter and nv-hostengine are present, it configures the chart to use nv-hostengine. #
  # If only dcgm-exporter is present, it configures the chart to use it.                               #
  # If neither is present, it deploys a new dcgm-exporter with an embedded nv-hostengine.              #
  # The script requires the following environment variables to be set:                                 #
  #   CASTAI_API_TOKEN - the API token for the CAST AI API                                             #
  #   CASTAI_CLUSTER_ID - the ID of the CAST AI cluster                                                #
  # The script also requires the helm command to be installed.                                         #
  ######################################################################################################

  set -e

  # Constants used throughout the script
  DCGM_EXPORTER_COMMAND_SUBSTRING="dcgm-exporter"
  NV_HOSTENGINE_COMMAND_SUBSTRING="nv-hostengine"
  DCGM_EXPORTER_IMAGES=("nvcr.io/nvidia/k8s/dcgm-exporter" "nvidia/dcgm-exporter")
  DCGM_IMAGES=("nvcr.io/nvidia/cloud-native/dcgm" "nvidia/dcgm")
  CASTAI_AGENT_NAMESPACE="castai-agent"
  CASTAI_GPU_METRICS_EXPORTER_DAEMONSET="castai-gpu-metrics-exporter"
  CASTAI_API_URL="${CASTAI_API_URL:-https://api.cast.ai}"
  SKIP_HELM_UPDATE="${SKIP_HELM_UPDATE:-false}"

  # Global vars populated by the functions
  #   Which daemon set is running dcgm-exporter
  DCGM_EXPORTER_DAEMONSET=""
  DCGM_EXPORTER_NAMESPACE=""
  #   Which ds is running nv-hostengine
  NV_HOSTENGINE_DAEMONSET=""
  NV_HOSTENGINE_NAMESPACE=""

  #### Functions start here ####

  # check_pods_command - check the command of a given ds if it contains dcgm-exporter or nv-hostengine
  #                      results are stored in the global vars DCGM_EXPORTER_DAEMONSET and NV_HOSTENGINE_DAEMONSET
  check_daemonset_command() {
    namespace=$1
    ds=$2

    all_container_commands=$(kubectl -n $namespace get daemonsets -o=jsonpath-as-json='{$.spec.template.spec.containers[*].command[*]}' $ds)
    for image in $(echo $all_container_commands | tr " " "\n"); do
      if [[ $image == *$DCGM_EXPORTER_COMMAND_SUBSTRING* ]]; then
        DCGM_EXPORTER_DAEMONSET=$ds
        DCGM_EXPORTER_NAMESPACE=$namespace
      elif [[ $image == *$NV_HOSTENGINE_COMMAND_SUBSTRING* ]]; then
        NV_HOSTENGINE_DAEMONSET=$ds
        NV_HOSTENGINE_NAMESPACE=$namespace
      fi
    done
  }

  # check_pod_args - check the arguments of a given ds if it contains dcgm-exporter
  #                  results are stored in the global vars DCGM_EXPORTER_DAEMONSET
  check_pod_args() {
    namespace=$1
    ds=$2

    all_container_commands=$(kubectl -n $namespace get daemonsets -o=jsonpath-as-json='{$.spec.template.spec.containers[*].args[*]}' $ds)
    for image in $(echo $all_container_commands | tr " " "\n"); do
      if [[ $image == *$DCGM_EXPORTER_COMMAND_SUBSTRING* ]]; then
        DCGM_EXPORTER_DAEMONSET=$ds
        DCGM_EXPORTER_NAMESPACE=$namespace
      fi
    done
  }

  check_daemonset_image() {
    namespace=$1
    ds=$2
    all_container_images=$(kubectl -n $namespace get daemonsets -o=jsonpath-as-json='{$.spec.template.spec.containers[*].image}' $ds)
    for image in $(echo $all_container_images | tr " " "\n"); do
      for required_image in "${DCGM_EXPORTER_IMAGES[@]}"; do
        if [[ $image == *$required_image* ]]; then
          DCGM_EXPORTER_DAEMONSET=$ds
          DCGM_EXPORTER_NAMESPACE=$namespace
        fi
      done
      for required_image in "${DCGM_IMAGES[@]}"; do
        if [[ $image == *$required_image* ]]; then
          NV_HOSTENGINE_DAEMONSET=$ds
          NV_HOSTENGINE_NAMESPACE=$namespace
        fi
      done
    done
  }

  # check_all_daemonsets_in_namespace - check all daemonsets in a given namespace whether they contain dcgm-exporter or nv-hostengine
  #                                     results are stored in the global vars DCGM_EXPORTER_DAEMONSET and NV_HOSTENGINE_DAEMONSET
  check_all_daemonsets_in_namespace() {
    namespace=$1
    all_ds=$(kubectl get daemonsets -n $namespace --ignore-not-found | cut -d ' ' -f 1)
    all_ds=($all_ds)
    num_ds=${#all_ds[@]}
    [[ ! -z "$DEBUG" ]] && echo "    Found $num_ds daemonsets"
    for ds in "${all_ds[@]:1}"; do
      if [[ $ds = "$CASTAI_GPU_METRICS_EXPORTER_DAEMONSET" ]]; then
        # Skip our own daemonset
        continue
      fi
      [[ ! -z "$DEBUG" ]] && echo "    Checking daemonset $ds"
      # if any of the global vars are empty, we check by image first
      if [[ -z "$DCGM_EXPORTER_DAEMONSET" ]] || [[ -z "$NV_HOSTENGINE_DAEMONSET" ]]; then
        check_daemonset_image $namespace $ds
      fi
      # if any of the global vars are still empty, we check by command
      if [[ -z "$DCGM_EXPORTER_DAEMONSET" ]] || [[ -z "$NV_HOSTENGINE_DAEMONSET" ]]; then
        check_daemonset_command $namespace $ds
      fi
      # dcgm command can be in args because command is /bin/bash -c $args
      if [[ -z "$DCGM_EXPORTER_DAEMONSET" ]]; then
        check_pod_args $namespace $ds
      # we found both dcgm-exporter and nv-hostengine, no need to look further
      fi
      if [[ ! -z "$DCGM_EXPORTER_DAEMONSET" ]] && [[ ! -z "$NV_HOSTENGINE_DAEMONSET" ]]; then
        return
      fi
    done
  }

  unquote_string() {
    local str=$1
    temp="${str%\"}"
    temp="${temp#\"}"
    echo $temp
  }

  find_dcgm_exporter_label_value() {
    local namespace=$1
    local ds=$2
    label_value=$(kubectl -n $namespace get daemonsets -o=jsonpath-as-json='{$.metadata.labels.app\.kubernetes\.io\/name}' $ds | tr -d ' []\n')
    label_value=$(unquote_string $label_value)
    if [[ ! -z $label_value ]]; then
      echo "app.kubernetes.io/name:$label_value"
    else
      label_value=$(kubectl -n $namespace get daemonsets -o=jsonpath-as-json='{$.metadata.labels.app}' $ds | tr -d ' []\n')
      label_value=$(unquote_string $label_value)
      if [[ ! -z "$label_value" ]]; then
        echo "app:$label_value"
      fi
    fi
  }

  find_dcgm_exporter_svc() {
    local namespace=$1
    local dcgm_exporter_label=$2
    dcgm_exporter_label=$(echo $dcgm_exporter_label | tr ':' '=')
    svc=$(kubectl -n $namespace get svc -l $dcgm_exporter_label -o=jsonpath='{.items[0].metadata.name}' || true)
    echo $svc
  }

  #### Functions end here #####

  echo "Installing castai-gpu-metrics-exporter."

  # Precondition checks
  kubectl get namespace castai-agent >/dev/null 2>&1
  if [ $? -eq 1 ]; then
    echo "CAST AI namespace not found. Connect your cluster to CAST AI. See https://docs.cast.ai/docs/about-the-read-only-agent#step-1-connect-your-cluster-to-cast-ai"
    exit 1
  fi

  if [ -z $CASTAI_API_TOKEN ] || [ -z $CASTAI_API_URL ] || [ -z $CASTAI_CLUSTER_ID ]; then
    echo "CASTAI_API_TOKEN, CASTAI_API_URL, CASTAI_CLUSTER_ID variables were not provided"
    exit 1
  fi

  if ! [ -x "$(command -v helm)" ]; then
    echo "Error: helm is not installed. (helm is required to install gpu-metrics-exporter)"
    exit 1
  fi

  if [ "$SKIP_HELM_UPDATE" != "true" ]; then
    echo "Adding helm repositories for CAST AI required charts."
    helm repo add castai-helm https://castai.github.io/helm-charts
    helm repo update
    echo "Finished adding helm charts repositories.\n"
  fi

  # determine which components need to be installed and how to configure them
  echo "Checking presence of dcgm-exporter and nv-hostengine in the cluster."
  echo "Iterating through daemonsets in all namespaces."
  echo "Will take a few seconds per daemon set. Might take a few minutes"
  echo "Set the DEBUG environment variable to any value to see more details."

  [[ ! -z "$DEBUG" ]] && echo "Going through all daemon sets in all namespaces.\n"
  all_namespaces=$(kubectl get namespaces | cut -d ' ' -f 1)
  all_namespaces=($all_namespaces)
  num_namespaces=${#all_namespaces[@]}
  current_ns=0
  for ns in "${all_namespaces[@]:1}"; do
    let current_ns=current_ns+1
    [[ ! -z "$DEBUG" ]] && echo "$current_ns/$num_namespaces:  Checking namespace $ns"
    check_all_daemonsets_in_namespace $ns
    if [[ ! -z "$DCGM_EXPORTER_DAEMONSET" ]] && [[ ! -z "$NV_HOSTENGINE_DAEMONSET" ]]; then
      break
    fi
  done
  echo ""

  helm pull castai-helm/gpu-metrics-exporter --untar
  cd gpu-metrics-exporter

  value_overrides="--set gpuMetricsExporter.config.CAST_API=$CASTAI_API_URL \
                   --set gpuMetricsExporter.config.API_KEY=$CASTAI_API_TOKEN \
                   --set gpuMetricsExporter.config.CLUSTER_ID=$CASTAI_CLUSTER_ID"

  # if we found nv-hostengine, we need to configure the dcgm-exporter container in the gpu-metrics-exporter chart
  # to connect to the 5555 port of the node.
  if [ ! -z $NV_HOSTENGINE_DAEMONSET ]; then
    echo "Found nv-hostengine, configuring gpu-metrics-exporter to use it"
    value_overrides="$value_overrides \
                     --set dcgmExporter.enabled=true \
                     --set dcgmExporter.useExternalHostEngine=true"
  # if nv-hostengine does not exist but DCGM exporter exists, then we don't deploy a new DCGM exporter just
  # configure our gpu-metrics-exporter to find the existing DCGM exporter by scanning the labels
  elif [ ! -z $DCGM_EXPORTER_DAEMONSET ]; then
    echo "Found dcgm-exporter with an embedded nv-hostengine, configuring gpu-metrics-exporter to use it"
    dcgm_label=$(find_dcgm_exporter_label_value $DCGM_EXPORTER_NAMESPACE $DCGM_EXPORTER_DAEMONSET)
    [[ ! -z "$DEBUG" ]] && echo "Discovered DCGM-exporter label: $dcgm_label"
    dcgm_service_name=$(find_dcgm_exporter_svc $DCGM_EXPORTER_NAMESPACE $dcgm_label)
    [[ ! -z "$DEBUG" ]] && echo "Discovered DCGM-exporter service name: $dcgm_service_name"
    if [ ! -z $dcgm_service_name ]; then
      value_overrides="$value_overrides \
                           --set dcgmExporter.enabled=false \
                           --set dcgmExporter.config.DCGM_HOST=$dcgm_service_name.$DCGM_EXPORTER_NAMESPACE"
    elif [ ! -z $dcgm_label ]; then
      value_overrides="$value_overrides \
                       --set dcgmExporter.enabled=false \
                       --set gpuMetricsExporter.config.DCGM_LABELS=$dcgm_label"
    else
      echo "Could not find the service name of the dcgm-exporter or a app name label. Please check the dcgm-exporter daemonset."
      exit 1
    fi
  else
    echo "DCGM exporter and nv-hostengine not found. Deploying a new DCGM exporter with an embedded nv-hostengine."
  fi

  if [ -z $K8S_PROVIDER ]; then
    helm upgrade -i castai-gpu-metrics-exporter . -f values.yaml -n castai-agent \
      $value_overrides
  else
    helm upgrade -i castai-gpu-metrics-exporter . -f values.yaml -f values-$K8S_PROVIDER.yaml -n castai-agent \
      $value_overrides
  fi

  cd ../
  rm -r gpu-metrics-exporter

  echo "Finished installing castai-gpu-metrics-exporter."

fi

echo "Scaling castai-agent:"
kubectl scale deployments/castai-agent --replicas=2 --namespace castai-agent