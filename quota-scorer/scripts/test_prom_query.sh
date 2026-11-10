#!/bin/bash

TOKEN=$1

if [[ -z "$TOKEN" ]]; then
  read -ersp "Enter prometheus token: " TOKEN
  echo
fi

HOST=prometheus-k8s.openshift-monitoring.svc.cluster.local:9091

curl -vkH "Authorization: Bearer $TOKEN" -k "https://$HOST/api/v1/query?query=up"
