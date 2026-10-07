kubectl -n new-api get svc newapi-np -o wide
echo "---- ports ----"
kubectl -n new-api get svc newapi-np -o jsonpath='{.spec.type}{"\n"}{range .spec.ports[*]}{.name}{" port="}{.port}{" targetPort="}{.targetPort}{" nodePort="}{.nodePort}{"\n"}{end}'
echo "---- endpoints ----"
kubectl -n new-api get endpoints newapi-np
