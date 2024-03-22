#!/bin/bash
NAMESPACE=default
APISecret=$(pwgen 20 1)

# create namespace
kubectl create ns "$NAMESPACE"
kubectl config set-context --current --namespace="$NAMESPACE"

# add tyk repos to helm
helm repo add tyk-helm https://helm.tyk.io/public/helm/charts/
helm repo update

# install redis and wait for it to be running
helm install tyk-redis oci://registry-1.docker.io/bitnamicharts/redis -n "$NAMESPACE" --set image.tag=6.2.13
sleep 5
kubectl wait --for=condition=ready -n "$NAMESPACE" pod tyk-redis-master-0
sleep 1
kubectl wait --for=condition=ready -n "$NAMESPACE" pod tyk-redis-replicas-0
sleep 1
kubectl wait --for=condition=ready -n "$NAMESPACE" pod tyk-redis-replicas-1
sleep 1
kubectl wait --for=condition=ready -n "$NAMESPACE" pod tyk-redis-replicas-2

# install tyk gateway and pump and wait for it to be running
kubectl create secret generic tyk-api-secret --from-literal=APISecret="$APISecret"
helm upgrade  tyk-oss tyk-helm/tyk-oss -n "$NAMESPACE" -f tyk-values.yaml --install --set global.redis.addrs="{tyk-redis-master.$NAMESPACE.svc.cluster.local:6379}"
kubectl wait --timeout=1800s --for=condition=Available -n "$NAMESPACE" deployment/gateway-tyk-oss-tyk-gateway
ATTEMPTS=60
until kubectl rollout status -n "$NAMESPACE" deployment/gateway-tyk-oss-tyk-gateway || [ $ATTEMPTS -le 0 ]; do
	ATTEMPTS=$(("$ATTEMPTS" - 1))
	sleep 10
done

# install cert manager for tyk operator and wait for it to be running
kubectl apply --validate=false -f https://github.com/jetstack/cert-manager/releases/download/v1.8.0/cert-manager.yaml
kubectl wait --timeout=1800s --for=condition=Available -n cert-manager deployment/cert-manager
ATTEMPTS=60
until kubectl rollout status -n cert-manager deployment/cert-manager || [ $ATTEMPTS -le 0 ]; do
	ATTEMPTS=$(("$ATTEMPTS" - 1))
	sleep 10
done
kubectl wait --timeout=1800s --for=condition=Available -n cert-manager deployment/cert-manager-cainjector
ATTEMPTS=60
until kubectl rollout status -n cert-manager deployment/cert-manager-cainjector || [ $ATTEMPTS -le 0 ]; do
	ATTEMPTS=$(("$ATTEMPTS" - 1))
	sleep 10
done
kubectl wait --timeout=1800s --for=condition=Available -n cert-manager deployment/cert-manager-webhook
ATTEMPTS=60
until kubectl rollout status -n cert-manager deployment/cert-manager-webhook || [ $ATTEMPTS -le 0 ]; do
	ATTEMPTS=$(("$ATTEMPTS" - 1))
	sleep 10
done

# install tyk operator and wait for it to be running
kubectl create secret -n "$NAMESPACE" generic tyk-operator-conf \
	--from-literal "TYK_AUTH=${APISecret}" \
	--from-literal "TYK_MODE=ce" \
	--from-literal "TYK_URL=http://gateway-svc-tyk-oss-tyk-gateway.$NAMESPACE.svc.cluster.local:8080" \
	--from-literal "TYK_TLS_INSECURE_SKIP_VERIFY=true"
helm install tyk-operator tyk-helm/tyk-operator -n "$NAMESPACE" -f tyk-operator-values.yaml
kubectl wait --timeout=1800s --for=condition=Available -n "$NAMESPACE" deployment/tyk-operator-controller-manager
ATTEMPTS=60
until kubectl rollout status -n "$NAMESPACE" deployment/tyk-operator-controller-manager || [ $ATTEMPTS -le 0 ]; do
	ATTEMPTS=$(("$ATTEMPTS" - 1))
	sleep 10
done

# port forward tyk gateway to localhost:5000
POD_NAME=$(kubectl get pods | grep gateway-tyk-oss | cut -d ' ' -f 1)
kubectl port-forward "$POD_NAME" -n "$NAMESPACE" 5000:8080 &
