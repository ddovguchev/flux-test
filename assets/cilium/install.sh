#!/usr/bin/env bash

export CILIUM_VERSION="1.19.2"
export CILIUM_NAMESPACE="kube-system"

helm upgrade --install cilium oci://quay.io/cilium/charts/cilium \
  --version "$CILIUM_VERSION" \
  -n "$CILIUM_NAMESPACE" \
  -f cilium-values.yaml