#!/bin/bash

solution_yaml=${1:-'solution.yaml'}
force_delete=${2:-''}

if [[ "$solution_yaml" == "--force" || "$solution_yaml" == "-f" ]]; then
    temp=$force_delete
    force_delete=$solution_yaml
    solution_yaml=$temp
    if [[ "$solution_yaml" == "" ]]; then
        solution_yaml="solution.yaml"
    fi
fi

# Check if the file exists
if [ ! -f $solution_yaml ]
then
    echo "ERROR: $solution_yaml does not exist"
    exit 1
fi

pvc_consul_filter="data-default-consul"
pvc_kafka_filter="kafka"
pvc_zookeeper_filter="zookeeper"
pv_filter="pvc"
openldap_pvc="openldap-data"

function parseSolution()
{
    echo "$(./parse_scripts/parse_yaml.sh $solution_yaml $1)"
}

namespace=$(parseSolution 'solution.namespace')
namespace=$(echo $namespace | cut -f2 -d'>')
parsed_node_output=$(parseSolution 'solution.nodes.node*.name')

# Split parsed output into an array of vars and vals
IFS=';' read -r -a parsed_var_val_array <<< "$parsed_node_output"

find $(pwd)/cortx-cloud-helm-pkg/cortx-data-provisioner -name "mnt-blk-*" -delete
find $(pwd)/cortx-cloud-helm-pkg/cortx-data -name "mnt-blk-*" -delete

node_name_list=[] # short version
node_selector_list=[] # long version
count=0
# Loop the var val tuple array
for var_val_element in "${parsed_var_val_array[@]}"
do
    node_name=$(echo $var_val_element | cut -f2 -d'>')
    node_selector_list[count]=$node_name
    shorter_node_name=$(echo $node_name | cut -f1 -d'.')
    node_name_list[count]=$shorter_node_name
    count=$((count+1))
    file_name="mnt-blk-info-$shorter_node_name.txt"
    data_prov_file_path=$(pwd)/cortx-cloud-helm-pkg/cortx-data-provisioner/$file_name
    data_file_path=$(pwd)/cortx-cloud-helm-pkg/cortx-data/$file_name

    # Get the node var from the tuple
    node=$(echo $var_val_element | cut -f3 -d'.')

    filter="solution.storage.cvg*.devices*.device"
    parsed_dev_output=$(parseSolution $filter)
    IFS=';' read -r -a parsed_dev_array <<< "$parsed_dev_output"
    for dev in "${parsed_dev_array[@]}"
    do
        device=$(echo $dev | cut -f2 -d'>')
        if [[ -s $data_prov_file_path ]]; then
            printf "\n" >> $data_prov_file_path
        fi
        if [[ -s $data_file_path ]]; then
            printf "\n" >> $data_file_path
        fi
        printf $device >> $data_prov_file_path
        printf $device >> $data_file_path
    done
done

#############################################################
# Destroy CORTX Cloud functions
#############################################################
function deleteCortxData()
{
    printf "########################################################\n"
    printf "# Delete CORTX Data                                     \n"
    printf "########################################################\n"
    for i in "${!node_selector_list[@]}"; do
        helm uninstall "cortx-data-${node_name_list[$i]}"
    done
}

function deleteCortxServices()
{
    printf "########################################################\n"
    printf "# Delete CORTX Services                                 \n"
    printf "########################################################\n"
    kubectl delete service cortx-io-svc --namespace=$namespace
}

function deleteCortxControl()
{
    printf "########################################################\n"
    printf "# Delete CORTX Control                                  \n"
    printf "########################################################\n"
    helm uninstall "cortx-control"
}

function deleteCortxProvisioners()
{
    printf "########################################################\n"
    printf "# Delete CORTX Data provisioner                         \n"
    printf "########################################################\n"
    for i in "${!node_selector_list[@]}"; do
        helm uninstall "cortx-data-provisioner-${node_name_list[$i]}"
    done

    printf "########################################################\n"
    printf "# Delete CORTX Control provisioner                      \n"
    printf "########################################################\n"
    helm uninstall "cortx-control-provisioner"
}

function deleteGlusterfs()
{
    printf "########################################################\n"
    printf "# Delete CORTX GlusterFS                                \n"
    printf "########################################################\n"
    gluster_vol="myvol"

    # Build Gluster endpoint array
    gluster_ep_array=[]
    count=0
    while IFS= read -r line; do
        if [[ $line == *"gluster-"* ]]
        then
            IFS=" " read -r -a my_array <<< "$line"
            gluster_ep_array[count]=$line
            count=$((count+1))
        fi
    done <<< "$(kubectl get pods -A -o wide | grep 'gluster-')"

    # Loop through all gluster endpoint array and find endoint IP address
    # and gluster node name
    count=0
    first_gluster_node_name=''
    for gluster_ep in "${gluster_ep_array[@]}"
    do
        IFS=" " read -r -a my_array <<< "$gluster_ep"
        gluster_ep_ip=${my_array[6]}
        gluster_node_name=${my_array[1]}
        printf "=================================================================================\n"
        printf "Stop and delete GlusterFS volume: $gluster_node_name                             \n"
        printf "=================================================================================\n"
        kubectl exec --namespace=$namespace -i $gluster_node_name -- bash -c \
            'rm -rf /etc/gluster/* /etc/gluster/.glusterfs/'
        kubectl exec --namespace=$namespace -i $gluster_node_name -- bash -c \
            'mkdir -p /etc/gluster/var/log/cortx'
        if [[ "$count" == 0 ]]; then
            first_gluster_node_name=$gluster_node_name
            echo y | kubectl exec --namespace=$namespace -i $gluster_node_name -- gluster volume stop $gluster_vol
            echo y | kubectl exec --namespace=$namespace -i $gluster_node_name -- gluster volume delete $gluster_vol
        else
            echo y | kubectl exec --namespace=$namespace -i $first_gluster_node_name -- gluster peer detach $gluster_ep_ip
        fi
        count=$((count+1))
    done

    while IFS= read -r line; do
        IFS=" " read -r -a my_array <<< "$line"
        helm uninstall ${my_array[0]}
    done <<< "$(helm ls | grep 'cortx-gluster')"
    
    printf "\nWait for GlusterFS to terminate"
    while true; do
        count=0
        glusterfs="$(kubectl get pods --namespace=$namespace | grep 'gluster' 2>&1)"
        while IFS= read -r line; do
            if [[ "$line" == *"gluster"* ]]; then
                count=$((count+1))
            fi
        done <<< "${glusterfs}"

        if [[ $count -eq 0 ]]; then
            break
        else
            printf "."
        fi
        sleep 1s
    done
    printf "\n\n"
}

function waitForCortxPodsToTerminate()
{
    printf "\nWait for CORTX Pods to terminate"
    while true; do
        count=0
        cortx_pods="$(kubectl get pods --namespace=$namespace | grep 'cortx' 2>&1)"
        while IFS= read -r line; do
            if [[ "$line" == *"cortx"* ]]; then
                count=$((count+1))
            fi
        done <<< "${cortx_pods}"

        if [[ $count -eq 0 ]]; then
            break
        else
            printf "."
        fi
        sleep 1s
    done
    printf "\n\n"
}

function deleteCortxLocalBlockStorage()
{
    printf "######################################################\n"
    printf "# Delete CORTX Local Block Storage                    \n"
    printf "######################################################\n"
    for i in "${!node_selector_list[@]}"; do
        node_name=${node_name_list[i]}
        node_selector=${node_selector_list[i]}
        file_path="cortx-cloud-helm-pkg/cortx-data-provisioner/mnt-blk-info-$node_name.txt"
        count=001
        while IFS=' ' read -r mount_path || [[ -n "$mount_path" ]]; do
            count_str=$(printf "%03d" $count)
            count=$((count+1))
            helm_name1="cortx-data-blk-data$count_str-$node_name"
            helm uninstall $helm_name1
        done < "$file_path"
    done
}

function deleteCortxPVs()
{
    printf "######################################################\n"
    printf "# Delete CORTX Persistent Volumes                     \n"
    printf "######################################################\n"
    while IFS= read -r line; do
        if [[ $line != *"master"* && $line != *"AGE"* ]]
        then
            IFS=" " read -r -a pvc_line <<< "$line"
            if [[ "${pvc_line[5]}" == *"cortx-data-fs-local"* || "${pvc_line[5]}" == *"cortx-control-fs-local"* ]]; then
                printf "Removing ${pvc_line[0]}\n"
                if [[ "$force_delete" == "--force" || "$force_delete" == "-f" ]]; then
                    kubectl patch pv ${pvc_line[0]} -p '{"metadata":{"finalizers":null}}'
                fi
                kubectl delete pv ${pvc_line[0]}
            fi
        fi
    done <<< "$(kubectl get pv -A)"
}

function deleteCortxConfigmap()
{
    printf "########################################################\n"
    printf "# Delete CORTX Configmap                               #\n"
    printf "########################################################\n"
    cfgmap_path="./cortx-cloud-helm-pkg/cortx-configmap"
    # Delete data machine id config maps
    for i in "${!node_name_list[@]}"; do
        kubectl delete configmap "cortx-data-machine-id-cfgmap-${node_name_list[i]}" --namespace=$namespace
        rm -rf "$cfgmap_path/auto-gen-${node_name_list[i]}"

    done
    # Delete control machine id config map
    kubectl delete configmap "cortx-control-machine-id-cfgmap" --namespace=$namespace
    rm -rf "$cfgmap_path/auto-gen-control"
    # Delete CORTX config maps
    rm -rf "$cfgmap_path/auto-gen-cfgmap"
    kubectl delete configmap "cortx-cfgmap" --namespace=$namespace
    rm -rf "$cfgmap_path/auto-gen-cfgmap"

    rm -rf "$cfgmap_path/node-info"
    rm -rf "$cfgmap_path/storage-info"

    # Delete SSL cert config map
    ssl_cert_path="$cfgmap_path/ssl-cert"
    kubectl delete configmap "cortx-ssl-cert-cfgmap" --namespace=$namespace
}

#############################################################
# Destroy CORTX 3rd party functions
#############################################################
function deleteKafkaZookeper()
{
    printf "########################################################\n"
    printf "# Delete Kafka                                         #\n"
    printf "########################################################\n"
    helm uninstall kafka

    printf "########################################################\n"
    printf "# Delete Zookeeper                                     #\n"
    printf "########################################################\n"
    helm uninstall zookeeper
}

function deleteOpenLdap()
{
    printf "########################################################\n"
    printf "# Delete openLDAP                                      #\n"
    printf "########################################################\n"
    openldap_array=[]
    count=0
    while IFS= read -r line; do
        IFS=" " read -r -a my_array <<< "$line"
        openldap_array[count]="${my_array[1]}"
        count=$((count+1))
    done <<< "$(kubectl get pods -A | grep 'openldap-')"

    for openldap_pod_name in "${openldap_array[@]}"
    do
        kubectl exec -ti $openldap_pod_name --namespace="default" -- bash -c \
            'rm -rf /etc/3rd-party/* /var/data/3rd-party/* /var/log/3rd-party/*'
    done

    helm uninstall "openldap"
}

function deleteSecrets()
{
    printf "########################################################\n"
    printf "# Delete Secrets                                       #\n"
    printf "########################################################\n"
    output=$(./parse_scripts/parse_yaml.sh $solution_yaml "solution.secrets*.name")
    IFS=';' read -r -a parsed_secret_name_array <<< "$output"
    for secret_name in "${parsed_secret_name_array[@]}"
    do
        secret_name=$(echo $secret_name | cut -f2 -d'>')
        kubectl delete secret $secret_name --namespace=$namespace
    done

    find $(pwd)/cortx-cloud-helm-pkg/cortx-control-provisioner -name "secret-*" -delete
    find $(pwd)/cortx-cloud-helm-pkg/cortx-control -name "secret-*" -delete
    find $(pwd)/cortx-cloud-helm-pkg/cortx-data-provisioner -name "secret-*" -delete
    find $(pwd)/cortx-cloud-helm-pkg/cortx-data -name "secret-*" -delete
}

function deleteConsul()
{
    printf "########################################################\n"
    printf "# Delete Consul                                        #\n"
    printf "########################################################\n"
    helm delete consul

    rancher_prov_path="$(pwd)/cortx-cloud-3rd-party-pkg/auto-gen-rancher-provisioner"
    rancher_prov_file="$rancher_prov_path/local-path-storage.yaml"
    kubectl delete -f $rancher_prov_file
    rm -rf $rancher_prov_path
}

function waitFor3rdPartyToTerminate()
{
    printf "\nWait for 3rd party to terminate"
    while true; do
        count=0
        pods="$(kubectl get pods 2>&1)"
        while IFS= read -r line; do
            if [[ "$line" == *"kafka"* || \
                 "$line" == *"zookeeper"* || \
                 "$line" == *"openldap"* || \
                 "$line" == *"consul"* ]]; then
                count=$((count+1))
            fi
        done <<< "${pods}"

        if [[ $count -eq 0 ]]; then
            break
        else
            printf "."
        fi
        sleep 1s
    done
    printf "\n\n"
}

function delete3rdPartyPVCs()
{
    printf "########################################################\n"
    printf "# Delete Persistent Volume Claims                      #\n"
    printf "########################################################\n"
    volume_claims=$(kubectl get pvc --namespace=default | grep -E "$pvc_consul_filter|$pvc_kafka_filter|$pvc_zookeeper_filter|$openldap_pvc|cortx|3rd-party" | cut -f1 -d " ")
    echo $volume_claims
    for volume_claim in $volume_claims
    do
        printf "Removing $volume_claim\n"
        if [[ "$force_delete" == "--force" || "$force_delete" == "-f" ]]; then
            kubectl patch pvc $volume_claim -p '{"metadata":{"finalizers":null}}'
        fi
        kubectl delete pvc $volume_claim
    done

    if [[ $namespace != 'default' ]]; then
        volume_claims=$(kubectl get pvc --namespace=$namespace | grep -E "$pvc_consul_filter|$pvc_kafka_filter|$pvc_zookeeper_filter|$openldap_pvc|cortx|3rd-party" | cut -f1 -d " ")
        echo $volume_claims
        for volume_claim in $volume_claims
        do
            printf "Removing $volume_claim\n"
            if [[ "$force_delete" == "--force" || "$force_delete" == "-f" ]]; then
                kubectl patch pvc $volume_claim -p '{"metadata":{"finalizers":null}}'
            fi
            kubectl delete pvc $volume_claim
        done
    fi
}

function delete3rdPartyPVs()
{
    printf "########################################################\n"
    printf "# Delete Persistent Volumes                            #\n"
    printf "########################################################\n"
    persistent_volumes=$(kubectl get pv --namespace=default | grep -E "$pvc_consul_filter|$pvc_kafka_filter|$pvc_zookeeper_filter" | cut -f1 -d " ")
    echo $persistent_volumes
    for persistent_volume in $persistent_volumes
    do
        printf "Removing $persistent_volume\n"    
        if [[ "$force_delete" == "--force" || "$force_delete" == "-f" ]]; then
            kubectl patch pv $persistent_volume -p '{"metadata":{"finalizers":null}}'
        fi
        kubectl delete pv $persistent_volume
    done

    if [[ $namespace != 'default' ]]; then
        persistent_volumes=$(kubectl get pv --namespace=$namespace | grep -E "$pvc_consul_filter|$pvc_kafka_filter|$pvc_zookeeper_filter" | cut -f1 -d " ")
        echo $persistent_volumes
        for persistent_volume in $persistent_volumes
        do
            printf "Removing $persistent_volume\n"        
            if [[ "$force_delete" == "--force" || "$force_delete" == "-f" ]]; then
                kubectl patch pv $persistent_volume -p '{"metadata":{"finalizers":null}}'
            fi
            kubectl delete pv $persistent_volume
        done
    fi
}

function helmChartCleanup()
{
    print_header=true
    helm_ls_header=true
    while IFS= read -r line; do
        IFS=" " read -r -a my_array <<< "$line"
        if [[ "$helm_ls_header" = true ]]; then
            helm_ls_header=false
            continue
        fi
        if [[ "$print_header" = true ]]; then
            printf "Helm chart cleanup:\n"
            print_header=false
        fi
        helm uninstall ${my_array[0]}
    done <<< "$(helm ls | grep 'consul\|cortx\|kafka\|openldap\|zookeeper')"
}

function deleteCortxNamespace()
{
    # Delete CORTX namespace
    if [[ "$namespace" != "default" ]]; then
        kubectl delete namespace $namespace
    fi
}

function cleanup()
{
    #################################################################
    # Delete files that contain disk partitions on the worker nodes #
    #################################################################
    # Split parsed output into an array of vars and vals
    IFS=';' read -r -a parsed_var_val_array <<< "$parsed_node_output"
    # Loop the var val tuple array
    for var_val_element in "${parsed_var_val_array[@]}"
    do
        node_name=$(echo $var_val_element | cut -f2 -d'>')
        shorter_node_name=$(echo $node_name | cut -f1 -d'.')
        file_name="mnt-blk-info-$shorter_node_name.txt"
        rm $(pwd)/cortx-cloud-helm-pkg/cortx-data-provisioner/$file_name
        rm $(pwd)/cortx-cloud-helm-pkg/cortx-data/$file_name
    done
}

#############################################################
# Destroy CORTX Cloud
#############################################################
deleteCortxData
deleteCortxServices
deleteCortxControl
deleteCortxProvisioners
waitForCortxPodsToTerminate
deleteGlusterfs
deleteCortxLocalBlockStorage
deleteCortxPVs
deleteCortxConfigmap

#############################################################
# Destroy CORTX 3rd party
#############################################################
deleteKafkaZookeper
deleteOpenLdap
deleteSecrets
deleteConsul
waitFor3rdPartyToTerminate
delete3rdPartyPVCs
delete3rdPartyPVs

#############################################################
# Clean up
#############################################################
helmChartCleanup
deleteCortxNamespace
cleanup