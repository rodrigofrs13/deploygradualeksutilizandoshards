echo ""
echo "###########  Shard1"

kubectl get svc springboot-canary -n shard-1
export SHARD1_CANARY_LB=$(kubectl get svc springboot-canary -n shard-1 -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')
curl -s http://$SHARD1_CANARY_LB/ | jq-windows-amd64.exe .


echo ""
echo "###########  Shard2"

kubectl get svc springboot-canary -n shard-2
export SHARD2_CANARY_LB=$(kubectl get svc springboot-canary -n shard-2 -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')
curl -s http://$SHARD2_CANARY_LB/ | jq-windows-amd64.exe .