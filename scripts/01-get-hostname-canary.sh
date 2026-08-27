kubectl get svc springboot-canary -n shard-1
export SHARD1_CANARY_LB=$(kubectl get svc springboot-canary -n shard-1 -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')
curl http://$SHARD1_CANARY_LB/