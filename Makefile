# Current Operator version
VERSION ?= $$(git describe --abbrev=0 --tags --match "v*")

# Default bundle image tag
BUNDLE_IMG ?= clastix/capsule:$(VERSION)-bundle
# Options for 'bundle-build'
ifneq ($(origin CHANNELS), undefined)
BUNDLE_CHANNELS := --channels=$(CHANNELS)
endif
ifneq ($(origin DEFAULT_CHANNEL), undefined)
BUNDLE_DEFAULT_CHANNEL := --default-channel=$(DEFAULT_CHANNEL)
endif
BUNDLE_METADATA_OPTS ?= $(BUNDLE_CHANNELS) $(BUNDLE_DEFAULT_CHANNEL)

# Image URL to use all building/pushing image targets
IMG ?= clastix/capsule:$(VERSION)

# Get the currently used golang install path (in GOPATH/bin, unless GOBIN is set)
ifeq (,$(shell go env GOBIN))
GOBIN=$(shell go env GOPATH)/bin
else
GOBIN=$(shell go env GOBIN)
endif

# Get information about git current status
GIT_HEAD_COMMIT ?= $$(git rev-parse --short HEAD)
GIT_TAG_COMMIT  ?= $$(git rev-parse --short $(VERSION))
GIT_MODIFIED_1  ?= $$(git diff $(GIT_HEAD_COMMIT) $(GIT_TAG_COMMIT) --quiet && echo "" || echo ".dev")
GIT_MODIFIED_2  ?= $$(git diff --quiet && echo "" || echo ".dirty")
GIT_MODIFIED    ?= $$(echo "$(GIT_MODIFIED_1)$(GIT_MODIFIED_2)")
GIT_REPO        ?= $$(git config --get remote.origin.url)
BUILD_DATE      ?= $$(git log -1 --format="%at" | xargs -I{} date -d @{} +%Y-%m-%dT%H:%M:%S)

all: manager

# Run tests
test: generate manifests
	go test ./... -coverprofile cover.out

# Build manager binary
manager: generate golint
	go build -o bin/manager

# Run against the configured Kubernetes cluster in ~/.kube/config
run: generate manifests
	go run .

# Creates the single file to install Capsule without any external dependency
installer: manifests kustomize
	cd config/manager && $(KUSTOMIZE) edit set image controller=${IMG}
	$(KUSTOMIZE) build config/default > config/install.yaml

# Install CRDs into a cluster
install: installer
	$(KUSTOMIZE) build config/crd | kubectl apply -f -

# Uninstall CRDs from a cluster
uninstall: installer
	$(KUSTOMIZE) build config/crd | kubectl delete -f -

# Deploy controller in the configured Kubernetes cluster in ~/.kube/config
deploy: installer
	kubectl apply -f config/install.yaml

# Remove controller in the configured Kubernetes cluster in ~/.kube/config
remove: installer
	kubectl delete -f config/install.yaml
	kubectl delete clusterroles.rbac.authorization.k8s.io capsule-namespace-deleter capsule-namespace-provisioner --ignore-not-found
	kubectl delete clusterrolebindings.rbac.authorization.k8s.io capsule-namespace-deleter capsule-namespace-provisioner --ignore-not-found

# Generate manifests e.g. CRD, RBAC etc.
manifests: controller-gen
	$(CONTROLLER_GEN) rbac:roleName=manager-role crd webhook paths="./..." output:crd:artifacts:config=config/crd/bases

# Generate code
generate: controller-gen
	$(CONTROLLER_GEN) object:headerFile="hack/boilerplate.go.txt" paths="./..."

apidoc: apidocs-gen
	$(APIDOCS_GEN) crdoc --resources config/crd/bases --output docs/content/general/crds-apis.md --template docs/template/reference-cr.tmpl

# Helm
SRC_ROOT = $(shell git rev-parse --show-toplevel)

helm-docs: HELMDOCS_VERSION := v1.11.0
helm-docs: docker
	@docker run -v "$(SRC_ROOT):/helm-docs" jnorwood/helm-docs:$(HELMDOCS_VERSION) --chart-search-root /helm-docs

helm-lint: ct
	@ct lint --config $(SRC_ROOT)/.github/configs/ct.yaml --lint-conf $(SRC_ROOT)/.github/configs/lintconf.yaml --all --debug

helm-test: kind ct docker-build
	@kind create cluster --wait=60s --name capsule-charts
	@kind load docker-image --name capsule-charts ${IMG}
	@kubectl create ns capsule-system
	@ct install --config $(SRC_ROOT)/.github/configs/ct.yaml --namespace=capsule-system --all --debug
	@kind delete cluster --name capsule-charts

docker:
	@hash docker 2>/dev/null || {\
		echo "You need docker" &&\
		exit 1;\
	}

# Setup development env
# Usage: 
# 	LAPTOP_HOST_IP=<YOUR_LAPTOP_IP> make dev-setup
# For example:
#	LAPTOP_HOST_IP=192.168.10.101 make dev-setup
define TLS_CNF
[ req ]
default_bits       = 4096
distinguished_name = req_distinguished_name
req_extensions     = req_ext
[ req_distinguished_name ]
countryName                = SG
stateOrProvinceName        = SG
localityName               = SG
organizationName           = CAPSULE
commonName                 = CAPSULE
[ req_ext ]
subjectAltName = @alt_names
[alt_names]
IP.1   = $(LAPTOP_HOST_IP)
endef
export TLS_CNF
dev-setup:
	kubectl -n capsule-system scale deployment capsule-controller-manager --replicas=0
	mkdir -p /tmp/k8s-webhook-server/serving-certs
	echo "$${TLS_CNF}" > _tls.cnf
	openssl req -newkey rsa:4096 -days 3650 -nodes -x509 \
		-subj "/C=SG/ST=SG/L=SG/O=CAPSULE/CN=CAPSULE" \
		-extensions req_ext \
		-config _tls.cnf \
		-keyout /tmp/k8s-webhook-server/serving-certs/tls.key \
		-out /tmp/k8s-webhook-server/serving-certs/tls.crt
	rm -f _tls.cnf 
	export WEBHOOK_URL="https://$${LAPTOP_HOST_IP}:9443"; \
	export CA_BUNDLE=`openssl base64 -in /tmp/k8s-webhook-server/serving-certs/tls.crt | tr -d '\n'`; \
	kubectl patch MutatingWebhookConfiguration capsule-mutating-webhook-configuration \
		--type='json' -p="[\
		    {'op': 'replace', 'path': '/webhooks/0/clientConfig', 'value':{'url':\"$${WEBHOOK_URL}/defaults\",'caBundle':\"$${CA_BUNDLE}\"}},\
			{'op': 'replace', 'path': '/webhooks/1/clientConfig', 'value':{'url':\"$${WEBHOOK_URL}/defaults\",'caBundle':\"$${CA_BUNDLE}\"}},\
			{'op': 'replace', 'path': '/webhooks/2/clientConfig', 'value':{'url':\"$${WEBHOOK_URL}/defaults\",'caBundle':\"$${CA_BUNDLE}\"}},\
			{'op': 'replace', 'path': '/webhooks/3/clientConfig', 'value':{'url':\"$${WEBHOOK_URL}/namespace-owner-reference\",'caBundle':\"$${CA_BUNDLE}\"}}\
		]" && \
	kubectl patch ValidatingWebhookConfiguration capsule-validating-webhook-configuration \
		--type='json' -p="[\
			{'op': 'replace', 'path': '/webhooks/0/clientConfig', 'value':{'url':\"$${WEBHOOK_URL}/cordoning\",'caBundle':\"$${CA_BUNDLE}\"}},\
			{'op': 'replace', 'path': '/webhooks/1/clientConfig', 'value':{'url':\"$${WEBHOOK_URL}/ingresses\",'caBundle':\"$${CA_BUNDLE}\"}},\
			{'op': 'replace', 'path': '/webhooks/2/clientConfig', 'value':{'url':\"$${WEBHOOK_URL}/namespaces\",'caBundle':\"$${CA_BUNDLE}\"}},\
			{'op': 'replace', 'path': '/webhooks/3/clientConfig', 'value':{'url':\"$${WEBHOOK_URL}/networkpolicies\",'caBundle':\"$${CA_BUNDLE}\"}},\
			{'op': 'replace', 'path': '/webhooks/4/clientConfig', 'value':{'url':\"$${WEBHOOK_URL}/nodes\",'caBundle':\"$${CA_BUNDLE}\"}},\
			{'op': 'replace', 'path': '/webhooks/5/clientConfig', 'value':{'url':\"$${WEBHOOK_URL}/pods\",'caBundle':\"$${CA_BUNDLE}\"}},\
			{'op': 'replace', 'path': '/webhooks/6/clientConfig', 'value':{'url':\"$${WEBHOOK_URL}/persistentvolumeclaims\",'caBundle':\"$${CA_BUNDLE}\"}},\
			{'op': 'replace', 'path': '/webhooks/7/clientConfig', 'value':{'url':\"$${WEBHOOK_URL}/services\",'caBundle':\"$${CA_BUNDLE}\"}},\
			{'op': 'replace', 'path': '/webhooks/8/clientConfig', 'value':{'url':\"$${WEBHOOK_URL}/tenants\",'caBundle':\"$${CA_BUNDLE}\"}}\
		]" && \
	kubectl patch crd tenants.capsule.clastix.io \
		--type='json' -p="[\
			{'op': 'replace', 'path': '/spec/conversion/webhook/clientConfig', 'value':{'url': \"$${WEBHOOK_URL}\", 'caBundle': \"$${CA_BUNDLE}\"}}\
		]" && \
	kubectl patch crd capsuleconfigurations.capsule.clastix.io \
		--type='json' -p="[\
			{'op': 'replace', 'path': '/spec/conversion/webhook/clientConfig', 'value':{'url': \"$${WEBHOOK_URL}\", 'caBundle': \"$${CA_BUNDLE}\"}}\
		]";


# Build the docker image
docker-build: test
	docker build . -t ${IMG} --build-arg GIT_HEAD_COMMIT=$(GIT_HEAD_COMMIT) \
 							 --build-arg GIT_TAG_COMMIT=$(GIT_TAG_COMMIT) \
 							 --build-arg GIT_MODIFIED=$(GIT_MODIFIED) \
 							 --build-arg GIT_REPO=$(GIT_REPO) \
 							 --build-arg GIT_LAST_TAG=$(VERSION) \
 							 --build-arg BUILD_DATE=$(BUILD_DATE)

# Push the docker image
docker-push:
	docker push ${IMG}

CONTROLLER_GEN = $(shell pwd)/bin/controller-gen
controller-gen: ## Download controller-gen locally if necessary.
	$(call go-install-tool,$(CONTROLLER_GEN),sigs.k8s.io/controller-tools/cmd/controller-gen@v0.10.0)

APIDOCS_GEN = $(shell pwd)/bin/crdoc
apidocs-gen: ## Download crdoc locally if necessary.
	$(call go-install-tool,$(APIDOCS_GEN),fybrik.io/crdoc@latest)

GINKGO = $(shell pwd)/bin/ginkgo
ginkgo: ## Download ginkgo locally if necessary.
	$(call go-install-tool,$(GINKGO),github.com/onsi/ginkgo/ginkgo@v1.16.5)

CT = $(shell pwd)/bin/ct
ct: ## Download ct locally if necessary.
	$(call go-install-tool,$(CT),github.com/helm/chart-testing/v3/ct@v3.7.1)

KIND = $(shell pwd)/bin/kind
kind: ## Download kind locally if necessary.
	$(call go-install-tool,$(KIND),sigs.k8s.io/kind/cmd/kind@v0.17.0)

KUSTOMIZE = $(shell pwd)/bin/kustomize
kustomize: ## Download kustomize locally if necessary.
	$(call install-kustomize,$(KUSTOMIZE),3.8.7)

define install-kustomize
@[ -f $(1) ] || { \
set -e ;\
echo "Installing v$(2)" ;\
cd bin ;\
wget "https://raw.githubusercontent.com/kubernetes-sigs/kustomize/master/hack/install_kustomize.sh" ;\
bash ./install_kustomize.sh $(2) ;\
}
endef

# go-install-tool will 'go install' any package $2 and install it to $1.
PROJECT_DIR := $(shell dirname $(abspath $(lastword $(MAKEFILE_LIST))))
define go-install-tool
@[ -f $(1) ] || { \
set -e ;\
echo "Installing $(2)" ;\
GOBIN=$(PROJECT_DIR)/bin go install $(2) ;\
}
endef

# Generate bundle manifests and metadata, then validate generated files.
bundle: manifests
	operator-sdk generate kustomize manifests -q
	kustomize build config/manifests | operator-sdk generate bundle -q --overwrite --version $(VERSION) $(BUNDLE_METADATA_OPTS)
	operator-sdk bundle validate ./bundle

# Build the bundle image.
bundle-build:
	docker build -f bundle.Dockerfile -t $(BUNDLE_IMG) .

# Sorting imports
.PHONY: goimports
goimports:
	goimports -w -l -local "github.com/clastix/capsule" .

GOLANGCI_LINT = $(shell pwd)/bin/golangci-lint
golangci-lint: ## Download golangci-lint locally if necessary.
	$(call go-install-tool,$(GOLANGCI_LINT),github.com/golangci/golangci-lint/cmd/golangci-lint@v1.45.2)

# Linting code as PR is expecting
.PHONY: golint
golint: golangci-lint
	$(GOLANGCI_LINT) run -c .golangci.yml

# Running e2e tests in a KinD instance
.PHONY: e2e
e2e/%: ginkgo
	$(MAKE) e2e-build/$* && $(MAKE) e2e-exec || $(MAKE) e2e-destroy

e2e-build/%:
	kind create cluster --wait=60s --name capsule --image=kindest/node:$*
	make docker-build
	kind load docker-image --nodes capsule-control-plane --name capsule $(IMG)
	helm upgrade \
		--debug \
		--install \
		--namespace capsule-system \
		--create-namespace \
		--set 'manager.image.pullPolicy=Never' \
		--set 'manager.resources=null'\
		--set "manager.image.tag=$(VERSION)" \
		--set 'manager.livenessProbe.failureThreshold=10' \
		--set 'manager.readinessProbe.failureThreshold=10' \
		capsule \
		./charts/capsule

e2e-exec: ginkgo
	$(GINKGO) -v -tags e2e ./e2e

e2e-destroy:
	kind delete cluster --name capsule
