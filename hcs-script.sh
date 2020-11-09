#!/bin/bash
echo “Logging to Azure”
date
az login

echo -n “Enter your resource group name: ”
read resourcegroup
export RESOURCE_GROUP=$resourcegroup && echo $RESOURCE_GROUP

echo -n “Enter your email: ”
read email
export EMAIL=$email && echo $EMAIL

echo “Creating a resource group”
az group create -l westus2 -n $RESOURCE_GROUP
date
echo “Creating an AKS cluster - this may take up to 10 minutes”
az aks create -g $RESOURCE_GROUP -n $RESOURCE_GROUP-aks
wait
date
echo “Creating an HCS Datacenter -This may take up to 15 minutes”
az hcs create -g $RESOURCE_GROUP --name $RESOURCE_GROUP-managed-hcs --datacenter-name dc1 --email $EMAIL --external-endpoint enabled

wait
date

echo “Confirming your resources”
az resource list --resource-group $RESOURCE_GROUP -o table

echo “Setting an environment variable to the name of your AKS cluster”
export AKS_CLUSTER=$(az aks list --resource-group $RESOURCE_GROUP | jq -r '.[] | .name') && echo $AKS_CLUSTER

echo “Setting an environment variable to the name of your HCS managed app”
export HCS_MANAGED_APP=$(az hcs list --resource-group $RESOURCE_GROUP | jq -r '.[] | .name') && echo $HCS_MANAGED_APP

echo $RESOURCE_GROUP
echo “Setting an environment variable to the name of your HCS managed apps resource group”
export HCS_MANAGED_RESOURCE_GROUP=$((az hcs list --resource-group $RESOURCE_GROUP | jq -r '.[] | .managedResourceGroupId') | awk -F/ '{ print $5 }')
echo $HCS_MANAGED_RESOURCE_GROUP

echo “Adding remote AKS kubeconfig to local kubconfig”
az aks get-credentials --name $AKS_CLUSTER --resource-group $RESOURCE_GROUP

echo “Bootstrap ACLs and store the token as a Kubernetes secret”
az hcs create-token --name $HCS_MANAGED_APP --resource-group $RESOURCE_GROUP --output-kubernetes-secret | kubectl apply -f -

echo “Generate Consul key/cert and store as a Kubernetes secret”
az hcs generate-kubernetes-secret --name $HCS_MANAGED_APP --resource-group $RESOURCE_GROUP | kubectl apply -f -

echo “Export the config file to pass to helm during install”
az hcs generate-helm-values --name $HCS_MANAGED_APP --resource-group $RESOURCE_GROUP --aks-cluster-name $AKS_CLUSTER > config.yaml

echo “Enable the AKS specific setting exposeGossipPorts”
sed -i -e 's/^  # \(exposeGossipPorts\)/  \1/' config.yaml

echo “Configure the development host to talk to the public endpoint”
export CONSUL_HTTP_ADDR=$(az hcs show --name $HCS_MANAGED_APP --resource-group $RESOURCE_GROUP | jq -r .properties.consulExternalEndpointUrl) && echo $CONSUL_HTTP_ADDR

echo “Set the CONSUL_HTTP_TOKEN on the development host to authorize the CLI”
export CONSUL_HTTP_TOKEN=$(kubectl get secret $HCS_MANAGED_APP-bootstrap-token -o jsonpath={.data.token} | base64 -d) && echo $CONSUL_HTTP_TOKEN

echo “Set the CONSUL_HTTP_SSL_VERIFY flag to false on the development host”
export CONSUL_HTTP_SSL_VERIFY=false && echo $CONSUL_HTTP_SSL_VERIFY

echo “Verify that the development host can see the Consul servers”
consul members

export AKS_MANAGED_RESOURCE_GROUP=$(az resource show --resource-group $RESOURCE_GROUP -n $AKS_CLUSTER --query "properties.nodeResourceGroup" --resource-type Microsoft.ContainerService/managedClusters)
echo $AKS_MANAGED_RESOURCE_GROUP

echo “Confirming your resources”
az resource list --resource-group $RESOURCE_GROUP -o table

echo “Setting an environment variable to the name of your AKS cluster”
export AKS_CLUSTER=$(az aks list --resource-group $RESOURCE_GROUP | jq -r '.[] | .name') && echo $AKS_CLUSTER

echo “Setting an environment variable to the name of your HCS managed app”
export HCS_MANAGED_APP=$(az hcs list --resource-group $RESOURCE_GROUP | jq -r '.[] | .name') && echo $HCS_MANAGED_APP

echo $RESOURCE_GROUP
echo “Setting an environment variable to the name of your HCS managed apps resource group”
export HCS_MANAGED_RESOURCE_GROUP=$((az hcs list --resource-group $RESOURCE_GROUP | jq -r '.[] | .managedResourceGroupId') | awk -F/ '{ print $5 }')
echo $HCS_MANAGED_RESOURCE_GROUP

echo “Adding remote AKS kubeconfig to local kubconfig”
az aks get-credentials --name $AKS_CLUSTER --resource-group $RESOURCE_GROUP

echo “Configure the development host to talk to the public endpoint”
export CONSUL_HTTP_ADDR=$(az hcs show --name $HCS_MANAGED_APP --resource-group $RESOURCE_GROUP | jq -r .properties.consulExternalEndpointUrl) && echo $CONSUL_HTTP_ADDR

echo “Set the CONSUL_HTTP_TOKEN on the development host to authorize the CLI”
export CONSUL_HTTP_TOKEN=$(kubectl get secret $HCS_MANAGED_APP-bootstrap-token -o jsonpath={.data.token} | base64 -d) && echo $CONSUL_HTTP_TOKEN
echo CONSUL_HTTP_TOKEN=$CONSUL_HTTP_TOKEN=

echo “Set the CONSUL_HTTP_SSL_VERIFY flag to false on the development host”
export CONSUL_HTTP_SSL_VERIFY=false && echo $CONSUL_HTTP_SSL_VERIFY

echo “Verify that the development host can see the Consul servers”
consul members

export AKS_MANAGED_RESOURCE_GROUP=$(az resource show --resource-group $RESOURCE_GROUP -n $AKS_CLUSTER --query "properties.nodeResourceGroup" --resource-type Microsoft.ContainerService/managedClusters | xargs)
echo $AKS_MANAGED_RESOURCE_GROUP

export HCS_VNET_NAME=$(az network vnet list --resource-group $HCS_MANAGED_RESOURCE_GROUP | jq -r '.[0].name')
echo HCS_VNET_NAME=$HCS_VNET_NAME

export AKS_VNET_ID=$(az network vnet list --resource-group $AKS_MANAGED_RESOURCE_GROUP | jq -r '.[0].id')
echo AKS_VNET_ID=$AKS_VNET_ID

export HCS_VNET_ID=$(az network vnet list --resource-group $HCS_MANAGED_RESOURCE_GROUP | jq -r '.[0].id')
echo HCS_VNET_ID=$HCS_VNET_ID

export AKS_VNET_NAME=$(az network vnet list --resource-group $AKS_MANAGED_RESOURCE_GROUP | jq -r '.[0].name')
echo AKS_VNET_NAME=$AKS_VNET_NAME


echo “Create a peering from the HCS Datacenter's vnet to the AKS Cluster's vnet”
az network vnet peering create \
  -g $HCS_MANAGED_RESOURCE_GROUP \
  -n hcs-to-aks \
  --vnet-name $HCS_VNET_NAME \
  --remote-vnet $AKS_VNET_ID \
  --allow-vnet-access

echo “Create a peering from the AKS Cluster's vnet to the HCS Datacenter's vnet”
az network vnet peering create \
  -g $AKS_MANAGED_RESOURCE_GROUP \
  -n aks-to-hcs \
  --vnet-name $AKS_VNET_NAME \
  --remote-vnet $HCS_VNET_ID \
  --allow-vnet-access


echo “Install the Consul clients to the AKS Cluster”
helm install hcs hashicorp/consul -f config.yaml --wait

echo “Verify the installation”
consul members  

kubectl get pods

git clone https://github.com/hashicorp/learn-consul-hcs-on-azure

sleep 20

kubectl apply -f ~/learn-consul-hcs-on-azure/hashicups/ --wait


kubectl get pods


echo “Create a config entry for an ingress gateway”
consul config write ~/learn-consul-hcs-on-azure/hashicups/ingress-gateway.hcl
date

echo “Add the ingress gateway to the helm configuration file”
tee -a ./config.yaml <<EOF
ingressGateways:
  enabled: true
  defaults:
    replicas: 1
  gateways:
    - name: ingress-gateway
      service:
        type: LoadBalancer
EOF
date


helm upgrade -f ./config.yaml hcs hashicorp/consul --wait

consul intention create ingress-gateway frontend && \
consul intention create frontend public-api && \
consul intention create public-api products-api && \
consul intention create products-api postgres

kubectl get svc

export INGRESS_IP=$(kubectl get svc/consul-ingress-gateway -o jsonpath='{.status.loadBalancer.ingress[0].ip}') && echo $INGRESS_IP
#Set the INGRESS_PORT environment variable. This is so that the Katacoda environment can load the UI.
export INGRESS_PORT=$(kubectl get svc/consul-ingress-gateway -o jsonpath='{.spec.ports[0].port}') && echo $INGRESS_PORT

#Now, generate a clickable link in the console.
echo http://$INGRESS_IP:$INGRESS_PORT
