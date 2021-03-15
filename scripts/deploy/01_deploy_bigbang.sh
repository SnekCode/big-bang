#!/usr/bin/env bash

# set -ex

CI_VALUES_FILE="tests/ci/k3d/values.yaml"

# Deploy flux and wait for it to be ready
echo "Installing Flux"
flux --version
flux check --pre

# create flux namespace
kubectl create ns flux-system || true

# TODO When changing the flux images to .mil this will need to chagne
# delete flux private-registry secret
kubectl delete secret private-registry -n flux-system || true

if [[ -z "${AIRGAP}" ]]; then
# create flux private-registry secret
kubectl create secret docker-registry private-registry -n flux-system \
   --docker-server=registry1.dso.mil \
   --docker-username='robot$bigbang' \
   --docker-password=${REGISTRY1_PASSWORD} \
   --docker-email=bigbang@bigbang.dev || true
fi

# install flux
kubectl apply -f ./scripts/deploy/flux.yaml

# wait for flux
flux check

IFS=","
for package in $CI_MERGE_REQUEST_LABELS; do
  if [ "$(yq e ".addons.${package}.enabled" $CI_VALUES_FILE 2>/dev/null)" == "false" ]; then
    echo "Identified \"$package\" from labels"
    yq e ".addons.${package}.enabled = "true"" $CI_VALUES_FILE > tmpfile && mv tmpfile $CI_VALUES_FILE
  fi
done

# deploy BigBang using dev sized scaling
echo "Installing BigBang with the following configurations:"
cat $CI_VALUES_FILE

if [[ -z "${AIRGAP}" ]]; then
helm upgrade -i bigbang chart -n bigbang --create-namespace \
--set registryCredentials[0].username='robot$bigbang' --set registryCredentials[0].password=${REGISTRY1_PASSWORD} \
--set registryCredentials[0].registry=registry1.dso.mil \
-f ${CI_VALUES_FILE}
else
kubectl set env deploy/source-controller -n flux-system HTTP_PROXY=http://proxy.dso.mil:8888
kubectl set env deploy/source-controller -n flux-system HTTPS_PROXY=http://proxy.dso.mil:8888
kubectl set env deploy/source-controller -n flux-system NO_PROXY=notification-controller,10.42.0.0/16,10.43.0.0/16
helm upgrade -i bigbang chart -n bigbang --create-namespace \
-f ${CI_VALUES_FILE}l --set registryCredentials=null
fi

# apply secrets kustomization pointing to current branch
echo "Deploying secrets from the ${CI_COMMIT_REF_NAME} branch"
if [[ -z "${CI_COMMIT_TAG}" ]]; then
  cat tests/ci/shared-secrets.yaml | sed 's|master|'$CI_COMMIT_REF_NAME'|g' | kubectl apply -f -
else
  # NOTE: $CI_COMMIT_REF_NAME = $CI_COMMIT_TAG when running on a tagged build
  cat tests/ci/shared-secrets.yaml | sed 's|branch: master|tag: '$CI_COMMIT_REF_NAME'|g' | kubectl apply -f -
fi