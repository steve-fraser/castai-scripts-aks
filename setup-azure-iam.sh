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

# kubectl get namespace castai-agent >/dev/null 2>&1
# if [ $? -eq 1 ]; then
#   fatal "Cast AI namespace not found. Please run phase1 of the onboarding script first."
# fi

if [ -z $NODE_GROUP ]; then
  fatal "NODE_GROUP environment variable was not provided"
fi

if [ -z $SUBSCRIPTION_ID ]; then
  fatal "SUBSCRIPTION_ID environment variable was not provided"
fi

if [ -z $CASTAI_API_TOKEN ] || [ -z $CASTAI_API_URL ] || [ -z $CASTAI_CLUSTER_ID ]; then
  fatal "CASTAI_API_TOKEN, CASTAI_API_URL or CASTAI_CLUSTER_ID variables were not provided"
fi

if ! [ -x "$(command -v az)" ]; then
  fatal "Error: azure cli is not installed"
fi

if ! [ -x "$(command -v jq)" ]; then
  fatal "Error: jq is not installed"
fi

if [ -z $REGION ]; then
  fatal "REGION environment variable was not provided"
fi


function enable_autoscaler_agent() {
  echo "Installing autoscaler"

  echo "Installing autoscaler cloud components"
  SUBSCRIPTION=$(az account list --query "[?id=='${SUBSCRIPTION_ID}'].{name:name,tenantId:tenantId}[0]")
  if [[ $SUBSCRIPTION == "" ]]; then
    fatal "Error: subscription not found"
  fi

  echo "Setting active subscription: $(echo $SUBSCRIPTION | jq -r '.name')"
  az account set -s $SUBSCRIPTION_ID

  function get_cluster() {
    CLUSTER=$(az aks list --query "[?nodeResourceGroup=='${NODE_GROUP}'].{name:name,resourceGroup:resourceGroup,subnet:agentPoolProfiles[0].vnetSubnetId}[0]" --output json)
    if [[ $CLUSTER == "" ]]; then
      return 1
    fi
  }

  echo "Fetching cluster information"
  if ! retry get_cluster; then
    echo "Error: failed to find cluster by nodeResourceGroup $NODE_GROUP"
    exit 1
  fi

  CLUSTER_NAME=$(echo $CLUSTER | jq -r '.name')
  CLUSTER_GROUP=$(echo $CLUSTER | jq -r '.resourceGroup')

  VNET_GROUP=$(echo $CLUSTER | jq -r '.subnet | select(. != null)' | sed -n "s|/subscriptions/$SUBSCRIPTION_ID/resourceGroups/\([[:alnum:](),_-]*\).*|\1|p")
  ROLE_NAME="CastAKSRole-${CASTAI_CLUSTER_ID:0:8}"
  SCOPES=(
    $([ -n "$VNET_GROUP" ] && [ $CLUSTER_GROUP != $VNET_GROUP ] && echo "/subscriptions/$SUBSCRIPTION_ID/resourceGroups/$VNET_GROUP")
    "/subscriptions/$SUBSCRIPTION_ID/resourceGroups/$CLUSTER_GROUP"
    "/subscriptions/$SUBSCRIPTION_ID/resourceGroups/$NODE_GROUP"
  )
  ROLE_DEF='{
     "Name": "'"$ROLE_NAME"'",
     "Description": "CAST.AI role used to manage '"$CLUSTER_NAME"' AKS cluster",
     "IsCustom": true,
     "Actions": [
         "Microsoft.Compute/*/read",
         "Microsoft.Compute/virtualMachines/*",
         "Microsoft.Compute/virtualMachineScaleSets/*",
         "Microsoft.Compute/disks/write",
         "Microsoft.Compute/disks/delete",
         "Microsoft.Compute/disks/beginGetAccess/action",
         "Microsoft.Compute/galleries/write",
         "Microsoft.Compute/galleries/delete",
         "Microsoft.Compute/galleries/images/write",
         "Microsoft.Compute/galleries/images/delete",
         "Microsoft.Compute/galleries/images/versions/write",
         "Microsoft.Compute/galleries/images/versions/delete",
         "Microsoft.Compute/snapshots/write",
         "Microsoft.Compute/snapshots/delete",
         "Microsoft.Network/*/read",
         "Microsoft.Network/networkInterfaces/write",
         "Microsoft.Network/networkInterfaces/delete",
         "Microsoft.Network/networkInterfaces/join/action",
         "Microsoft.Network/networkSecurityGroups/join/action",
         "Microsoft.Network/virtualNetworks/subnets/join/action",
         "Microsoft.Network/applicationGateways/backendhealth/action",
         "Microsoft.Network/applicationGateways/backendAddressPools/join/action",
         "Microsoft.Network/applicationSecurityGroups/joinIpConfiguration/action",
         "Microsoft.Network/loadBalancers/backendAddressPools/write",
         "Microsoft.Network/loadBalancers/backendAddressPools/join/action",
         "Microsoft.ContainerService/*/read",
         "Microsoft.ContainerService/managedClusters/start/action",
         "Microsoft.ContainerService/managedClusters/stop/action",
         "Microsoft.ContainerService/managedClusters/runCommand/action",
         "Microsoft.ContainerService/managedClusters/agentPools/*",
         "Microsoft.ContainerService/managedClusters/write",
         "Microsoft.Resources/*/read",
         "Microsoft.Resources/tags/write",
         "Microsoft.Authorization/locks/read",
         "Microsoft.Authorization/roleAssignments/read",
         "Microsoft.Authorization/roleDefinitions/read",
         "Microsoft.ManagedIdentity/userAssignedIdentities/assign/action"
       ],
       "AssignableScopes": [
       '$(
    tmp=$(printf '"%s",' "${SCOPES[@]}")
    echo ${tmp%,}
  )'
       ]
  }'

  ROLE=$(az role definition list -n $ROLE_NAME --query "[0]")
  if [[ $ROLE == "" ]]; then
    echo "Creating custom role: '$ROLE_NAME'"
    az role definition create -o none --role-definition ''"$ROLE_DEF"''
  else
    echo "Role already exists. Updating..."
    az role definition update -o none --only-show-errors --role-definition ''"$ROLE_DEF"''
  fi

  GRAPH_URL="https://graph.microsoft.com"
  if [[ $REGION == usgov* ]]; then
    GRAPH_URL="https://graph.microsoft.us"
  fi

  APP_NAME="wba-NonProd-infra-core-int-castai"
  APP=$(az rest -m GET -u "${GRAPH_URL}/v1.0/applications\?\$filter=startswith(displayName, '${APP_NAME}')" --headers ConsistencyLevel=eventual | jq -r '.value[0]')
  APP_ID=""
  APP_OBJECT_ID=""
  if [[ $APP == "null" ]]; then
    echo "Creating app registration: '${APP_NAME}'"
    APP=$(az rest -m POST -u "${GRAPH_URL}/v1.0/applications" --headers Content-Type=application/json -b "{'displayName':'${APP_NAME}'}")
  else
    echo "Using existing app registration: '${APP_NAME}'"
  fi
  APP_ID=$(echo $APP | jq -r '.appId')
  APP_OBJECT_ID=$(echo $APP | jq -r '.id')

  SECRET_NAME="${CLUSTER_NAME}-castai"
  SECRET_KEY_ID=$(echo $APP | jq -r --arg SECRET_NAME "$SECRET_NAME" '.passwordCredentials[0] | select(.displayName==$SECRET_NAME) | .keyId')
  if [[ $SECRET_KEY_ID != "" ]]; then
    echo "Removing app old secret: '${SECRET_NAME}'"
    az rest -m POST -u "${GRAPH_URL}/v1.0/applications/${APP_OBJECT_ID}/removePassword" --headers Content-Type=application/json -b "{'keyId':'${SECRET_KEY_ID}'}"
  fi
  echo "Creating app secret: '${SECRET_NAME}'"
  APP_SECRET=$(az rest -m POST -u "${GRAPH_URL}/v1.0/applications/${APP_OBJECT_ID}/addPassword" --headers Content-Type=application/json -b "{'passwordCredential':{'displayName':'${SECRET_NAME}','endDateTime':'2199-01-01T11:11:11.111Z'}}" | jq -r '.secretText')

  SP_ID=$(az rest -m GET -u "${GRAPH_URL}/v1.0/servicePrincipals\?\$filter=appId eq '$APP_ID'" --headers ConsistencyLevel=eventual | jq -r '.value[0].id')
  if [[ $SP_ID == "" || $SP_ID == "null" ]]; then
    echo "Creating service principal"
    SP_ID=$(az rest -m POST -u "${GRAPH_URL}/v1.0/servicePrincipals" --headers Content-Type=application/json -b "{'appId':'${APP_ID}'}" | jq -r '.id')
  else
    echo "Using existing service principal: '${SP_ID}'"
  fi

  echo "Assigning role to '$APP_NAME' app"
  for scope in "${SCOPES[@]}"; do
    retry az role assignment create \
      --assignee-object-id "$SP_ID" \
      --assignee-principal-type "ServicePrincipal" \
      --scope "$scope" \
      --role $ROLE_NAME -o none
    if [ $? -ne 0 ]; then
      fatal "Failed to assign scope \"$scope\" to $ROLE_NAME as ServicePrincipal. Please check your permissions if you have enough rights to access aforementioned scope."
    fi
  done

  echo "--------------------------------------------------------------------------------"
  echo "Your generated credentials:"
  CREDENTIALS='{
    "subscriptionId": "'"$SUBSCRIPTION_ID"'",
    "tenantId": "'"$(echo "$SUBSCRIPTION" | jq -r '.tenantId')"'",
    "clientId": "'"$APP_ID"'",
    "clientSecret": "'"$APP_SECRET"'"
  }'
  echo $CREDENTIALS


  echo "Sending credentials to CAST AI console..."
  API_URL="${CASTAI_API_URL}/v1/kubernetes/external-clusters/${CASTAI_CLUSTER_ID}"
  BODY=$(jq -c -n --arg CREDENTIALS "$CREDENTIALS" '{credentials:$CREDENTIALS}')

  function update_cluster() {
    RESPONSE=$(curl -sSL --write-out "HTTP_STATUS:%{http_code}" -X POST -H "X-API-Key: ${CASTAI_API_TOKEN}" -d "${BODY}" $API_URL)
    RESPONSE_STATUS=$(echo "$RESPONSE" | tr -d '\n' | sed -e 's/.*HTTP_STATUS://')
    RESPONSE_BODY=$(echo "$RESPONSE" | sed -e 's/HTTP_STATUS\:.*//g')

    if [[ $RESPONSE_STATUS == "401" ]]; then
      RESPONSE_BODY="401 Unauthorized"
      return 0
    fi
    if [[ $RESPONSE_STATUS != "200" ]]; then
      if [[ $(grep -c "Failed to refresh the Token for request" <<<$RESPONSE_BODY) -gt 0 ]]; then
        echo "Request failed, will retry after $RETRY_SEC seconds ..."
        return 1
      fi
      if [[ "$RESPONSE_BODY_OLD" == "$RESPONSE_BODY" ]]; then
        echo "Request failed again, will retry after $RETRY_SEC seconds ..."
      else
        echo "Request failed with error: $RESPONSE_BODY"
        echo "Will retry after $RETRY_SEC seconds ..."
      fi
      RESPONSE_BODY_OLD=$RESPONSE_BODY
      return 1
    fi
  }

  RETRY_SEC=10 RETRY_TIMES=30 retry update_cluster

  if [[ $RESPONSE_STATUS == "200" ]]; then
    echo "Successfully sent."
  else
    echo "Couldn't save credentials to CAST AI console. Try pasting the credentials to the console manually."
    echo $RESPONSE_BODY
    exit 1
  fi
}

if [[ $INSTALL_AUTOSCALER = "true" ]]; then
  enable_autoscaler_agent
fi