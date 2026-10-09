#!/bin/bash
kubectl -n new-api get deploy new-api-stable -o yaml 2>&1 | sed -e 's/[[:space:]]*$//' | head -150
