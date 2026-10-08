kubectl -n new-api get pods -l app=new-api -o wide 2>&1 | head -8
kubectl -n new-api get endpointslice -o wide 2>&1 | head -6
