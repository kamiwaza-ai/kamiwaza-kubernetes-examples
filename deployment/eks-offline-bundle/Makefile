# Kamiwaza v0.13.3  offline → EKS.   Edit config.env + overrides.yaml, then:
#   make relocate   (one time)      make deploy
SHELL := /bin/bash
.ONESHELL:
.DEFAULT_GOAL := help
HERE := $(dir $(abspath $(lastword $(MAKEFILE_LIST))))

# The 5 operator charts share generic value schemas, so they're redirected to ECR
# via their offline override files (fixed infra). The kamiwaza umbrella's registry +
# tags + domain are ALL driven declaratively by overrides.yaml (--values).
OP_OVERLAYS := cert-manager-offline trust-manager-offline kuberay-operator-offline metrics-server-offline extension-operator-offline

define SETUP
set -euo pipefail
if [ ! -f "$(HERE)config.env" ]; then echo "missing config.env — run: cp config.env.example config.env && edit it"; exit 1; fi
set -a; source "$(HERE)config.env"; set +a
export PATH="$$WORK/prereqs/bin:$$PATH"
export MODEL_GGUF="$$(ls "$$WORK"/prereqs/models/*.gguf 2>/dev/null | head -1)"   # bundled embedding model
export KAMIWAZA_VERSION_SHORT="$${KAMIWAZA_VERSION#release-}"   # release-0.13.3 -> 0.13.3 (for v-prefixed tags)
export DEPLOYMENT_MODE=offline KAMIWAZA_K8S_RUNTIME=kind KAMIWAZA_OFFLINE_ALLOW_EMPTY_CATALOG=true
export CHART_REF_CERT_MANAGER=oci://$$REGISTRY/cert-manager CHART_REF_TRUST_MANAGER=oci://$$REGISTRY/trust-manager
export CHART_REF_KUBERAY_OPERATOR=oci://$$REGISTRY/kuberay-operator CHART_REF_METRICS_SERVER=oci://$$REGISTRY/metrics-server
export CHART_REF_EXTENSION_OPERATOR=oci://$$REGISTRY/extension-operator CHART_REF_KAMIWAZA=oci://$$REGISTRY/kamiwaza
ecr_login() { local s="login"; [ "$$1" = helm ] && s="registry login"; aws ecr get-login-password --region "$$AWS_REGION" | $$1 $$s --username AWS --password-stdin "$$REGISTRY"; }
guard_ctx() { c=$$(kubectl config current-context); case "$$c" in *$$CLUSTER_NAME*) ;; *) echo "REFUSING: context is $$c, not $$CLUSTER_NAME"; exit 1;; esac; }
endef

help: ## show targets
	@echo "Kamiwaza offline → EKS   (edit config.env + overrides.yaml first)"
	@grep -hE '^[a-z-]+:.*##' $(MAKEFILE_LIST) | sed -E 's/:.*## /\t/' | sort

relocate: ## one-time: push the bundle's images + charts + model-stager into ECR
	@$(SETUP)
	set +o pipefail   # `tar | head` closes the pipe early (SIGPIPE) — expected
	ecr_login docker; ecr_login helm
	echo "▶ creating ECR repos…"
	repos=$$(for w in "$$WRAP_DIR"/*.wrap; do top=$$(tar -tf "$$w" | head -1 | cut -d/ -f1)
	  tar -xOf "$$w" --occurrence=1 "$$top/chart/Images.lock" 2>/dev/null | awk '/^[[:space:]]+image:/{print $$2}' | sed -E 's#:[^:/]+$$##' | awk -F/ '{print $$(NF-1)"/"$$NF}'
	  echo "$$top" | sed -E 's#-[0-9v].*##'; done | sort -u; echo model-stager)
	for r in $$repos; do aws ecr create-repository --repository-name "$$r" --region "$$AWS_REGION" >/dev/null 2>&1 || true; done
	echo "▶ relocating wraps → ECR…"
	for w in "$$WRAP_DIR"/*.wrap; do echo "  $$w"; helm dt unwrap "$$w" "$$REGISTRY" --yes; rm -rf /tmp/chart-*; done
	echo "▶ building model-stager image (FROM the relocated chainguard-base — no internet)…"
	b=$$(mktemp -d); cp "$$MODEL_GGUF" "$$b"/
	printf 'FROM %s/images/chainguard-base:%s\nCOPY %s /staged/_bundled/%s\n' "$$REGISTRY" "$$KAMIWAZA_VERSION" "$$(basename $$MODEL_GGUF)" "$$(basename $$MODEL_GGUF)" > "$$b/Dockerfile"
	docker build -t "$$REGISTRY/model-stager:latest" "$$b" && docker push "$$REGISTRY/model-stager:latest"; rm -rf "$$b"
	echo "✔ relocate complete"

deploy: ## stand up / update the platform (idempotent)
	@$(SETUP)
	guard_ctx
	echo "▶ supporting resources (namespaces, StorageClass, embedding-model stager)…"
	for f in "$(HERE)"manifests/*.yaml; do envsubst '$$REGISTRY' < "$$f"; echo ---; done | kubectl apply -f -
	echo "▶ admin password secret…"
	pwf=$$(mktemp); printf '%s' "$$ADMIN_PASSWORD" > "$$pwf"
	kubectl create secret generic kamiwaza-user-admin -n kamiwaza --from-file="password=$$pwf" --dry-run=client -o yaml \
	  | kubectl label --local -f - --dry-run=client -o yaml app.kubernetes.io/managed-by=kamiwaza-seed-job app.kubernetes.io/component=user-secret kamiwaza.ai/username=admin \
	  | kubectl apply -f -; rm -f "$$pwf"
	echo "▶ redirect operator-chart override files → ECR (umbrella is driven by overrides.yaml)…"
	for o in $(OP_OVERLAYS); do sed -i "s#$$BUNDLE_REGISTRY_PLACEHOLDER#$$REGISTRY#g" "$$WORK/cluster/values/$$o.yaml"; done
	echo "▶ rendering overrides.yaml (\$$REGISTRY → $$REGISTRY)…"
	envsubst '$$REGISTRY $$DOMAIN $$KAMIWAZA_VERSION $$KAMIWAZA_VERSION_SHORT $$KEYCLOAK_TAG $$POSTGRES_TAG $$ETCD_TAG $$KUBECTL_TAG $$CURL_TAG $$LLAMACPP_TAG $$TRAEFIK_TAG $$KAFKA_TAG $$NEO4J_TAG $$OPENSEARCH_TAG' < "$(HERE)overrides.yaml" > /tmp/kamiwaza-overrides.rendered.yaml
	printf '#!/usr/bin/env bash\nexec %s/prereqs/bin/helm "$$@"\n' "$$WORK" > /tmp/helm-plain-http; chmod +x /tmp/helm-plain-http
	ecr_login helm
	echo "▶ helmfile sync — operators (own overlays), then umbrella (overrides.yaml)…"
	cd "$$WORK"
	# overrides.yaml is umbrella-shaped; the operator charts have strict schemas, so
	# apply --values ONLY to kamiwaza. Operators sync first to satisfy `needs`.
	helmfile -f cluster/helmfile.yaml.gotmpl -e release -l name!=kamiwaza sync
	helmfile -f cluster/helmfile.yaml.gotmpl -e release -l name=kamiwaza sync --values /tmp/kamiwaza-overrides.rendered.yaml
	echo "✔ deploy complete — UI: kubectl -n kamiwaza get svc traefik (LoadBalancer), Host from overrides.yaml global.domain"

show-tags: ## print the image tags pinned in the bundle (to refresh overrides.yaml per release)
	@$(SETUP)
	set +o pipefail   # `tar | head` closes the pipe early (SIGPIPE) — expected
	for w in "$$WRAP_DIR"/*.wrap; do top=$$(tar -tf "$$w" | head -1 | cut -d/ -f1)
	  tar -xOf "$$w" --occurrence=1 "$$top/chart/Images.lock" 2>/dev/null | awk '/^[[:space:]]+image:/{print $$2}'
	done | sed -E 's#^.*/##' | sort -u

status: ## show platform health
	@$(SETUP)
	guard_ctx
	kubectl -n kamiwaza get deploy,statefulset
	echo; kubectl get pods -A | grep -Ev 'Running|Completed' || echo "all pods Running/Completed"
	echo; kubectl -n kamiwaza get svc traefik 2>/dev/null

destroy: ## uninstall the platform (helm releases + namespaces; keeps cluster, CRDs, ECR)
	@$(SETUP)
	guard_ctx
	echo "▶ helmfile destroy (all releases)…"
	cd "$$WORK" && helmfile -f cluster/helmfile.yaml.gotmpl -e release destroy || true
	echo "▶ deleting namespaces (also removes PVCs→EBS, the Traefik ELB, secrets)…"
	kubectl delete ns kamiwaza kamiwaza-extensions kamiwaza-system kuberay metrics-server cert-manager --ignore-not-found --wait=false
	echo "✔ platform uninstalled. (CRDs + gp3 StorageClass + ECR remain — see 'make purge'.)"

destroy-ecr: ## delete the ECR repos created by `make relocate`
	@$(SETUP)
	set +o pipefail
	repos=$$(for w in "$$WRAP_DIR"/*.wrap; do top=$$(tar -tf "$$w" | head -1 | cut -d/ -f1)
	  tar -xOf "$$w" --occurrence=1 "$$top/chart/Images.lock" 2>/dev/null | awk '/^[[:space:]]+image:/{print $$2}' | sed -E 's#:[^:/]+$$##' | awk -F/ '{print $$(NF-1)"/"$$NF}'
	  echo "$$top" | sed -E 's#-[0-9v].*##'; done | sort -u; echo model-stager)
	for r in $$repos; do aws ecr delete-repository --repository-name "$$r" --force --region "$$AWS_REGION" >/dev/null 2>&1 && echo "  deleted $$r" || true; done
	echo "✔ ECR repos removed"

purge: destroy destroy-ecr ## full teardown: platform + CRDs + gp3 StorageClass + ECR (keeps the cluster)
	@$(SETUP)
	guard_ctx
	echo "▶ deleting CRDs left by the operators…"
	kubectl get crd -o name 2>/dev/null | grep -E 'cert-manager|trust\.cert-manager|gateway\.networking\.k8s\.io|ray\.io|extensions\.kamiwaza\.io' | xargs -r kubectl delete --ignore-not-found
	echo "▶ removing the gp3 default StorageClass we added (leaves EKS's gp2)…"
	kubectl delete storageclass gp3 --ignore-not-found
	echo "✔ purge complete — only the empty EKS cluster remains (terraform destroy to remove it)"
