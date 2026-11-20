#!/usr/bin/env bash
# Creates the kind cluster for compare.sh and loads the images it needs.
# The kubeconfig goes to the path given, never to the default one.
# Usage: setup-cmp.sh <cluster name> <kubeconfig path> <backend image> <epp image>...
set -euo pipefail
name=$1
kubeconfig=$2
backend=$3
shift 3
here=$(cd "$(dirname "$0")" && pwd)
export KUBECONFIG=$kubeconfig
kind create cluster --name "$name" --kubeconfig "$kubeconfig" --wait 120s
kind load docker-image --name "$name" "$backend" "$@"
docker pull -q cr.agentgateway.dev/agentgateway:v1.7.0 >/dev/null
# kind load docker-image fails on this multi-platform image ("content digest ... not found"), so it goes in as a single-platform archive.
archive=$(mktemp --suffix=.tar)
docker save --platform linux/amd64 -o "$archive" cr.agentgateway.dev/agentgateway:v1.7.0
kind load image-archive --name "$name" "$archive"
rm -f "$archive"
sed "s#image: llmd3089-grpcstream:dev#image: ${backend}#" "$here/deploy/backend.yaml" | kubectl apply -f -
kubectl apply -f "$here/deploy/agentgateway-plain.yaml"
kubectl rollout status deploy/grpcstream --timeout=180s
kubectl rollout status deploy/agw-plain --timeout=180s
kubectl wait --for=condition=Ready pod/client --timeout=180s
