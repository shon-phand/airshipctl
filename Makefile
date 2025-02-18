SHELL := /bin/bash

GIT_VERSION         ?= v0.1.0
GIT_MODULE          ?= opendev.org/airship/airshipctl/pkg/version

GO_FLAGS            := -ldflags '-extldflags "-static"' -tags=netgo -trimpath
GO_FLAGS            += -ldflags "-X ${GIT_MODULE}.gitVersion=${GIT_VERSION}"
# Get the currently used golang install path (in GOPATH/bin, unless GOBIN is set)
ifeq (,$(shell go env GOBIN 2> /dev/null))
GOBIN = $(shell go env GOPATH 2> /dev/null)/bin
else
GOBIN = $(shell go env GOBIN 2> /dev/null)
endif

# Produce CRDs that work back to Kubernetes 1.16
CRD_OPTIONS ?= crd:crdVersions=v1

BINDIR              := bin
EXECUTABLE_CLI      := airshipctl
TOOLBINDIR          := tools/bin

# linting
LINTER              := $(TOOLBINDIR)/golangci-lint
LINTER_CONFIG       := .golangci.yaml

# docker
DOCKER_MAKE_TARGET  := build
DOCKER_CMD_FLAGS    :=

# docker image options
DOCKER_REGISTRY     ?= quay.io
DOCKER_FORCE_CLEAN  ?= true
DOCKER_IMAGE_NAME   ?= airshipctl
DOCKER_IMAGE_PREFIX ?= airshipit
DOCKER_IMAGE_TAG    ?= latest
DOCKER_IMAGE        ?= $(DOCKER_REGISTRY)/$(DOCKER_IMAGE_PREFIX)/$(DOCKER_IMAGE_NAME):$(DOCKER_IMAGE_TAG)
DOCKER_TARGET_STAGE ?= release
PUBLISH             ?= false
# use this variables to override base images in internal build process
ifneq ($(strip $(DOCKER_BASE_GO_IMAGE)),)
DOCKER_CMD_FLAGS    += --build-arg GO_IMAGE=$(strip $(DOCKER_BASE_GO_IMAGE))
endif
ifneq ($(strip $(DOCKER_BASE_RELEASE_IMAGE)),)
DOCKER_CMD_FLAGS    += --build-arg RELEASE_IMAGE=$(strip $(DOCKER_BASE_RELEASE_IMAGE))
endif
ifneq ($(strip $(DOCKER_IMAGE_ENTRYPOINT)),)
DOCKER_CMD_FLAGS    += --build-arg ENTRYPOINT=$(strip $(DOCKER_IMAGE_ENTRYPOINT))
endif
ifneq ($(strip $(GOPROXY)),)
DOCKER_CMD_FLAGS    += --build-arg GOPROXY=$(strip $(GOPROXY))
endif
# use this variable for image labels added in internal build process
COMMIT              ?= $(shell git rev-parse HEAD)
LABEL               ?= org.airshipit.build=community
LABEL               += --label "org.opencontainers.image.revision=$(COMMIT)"
LABEL               += --label "org.opencontainers.image.created=$(shell date --rfc-3339=seconds --utc)"
LABEL               += --label "org.opencontainers.image.title=$(DOCKER_IMAGE_NAME)"

# go options
PKG                 ?= ./...
TESTS               ?= .
TEST_FLAGS          ?=
COVER_FLAGS         ?=
COVER_PROFILE       ?= cover.out
COVER_EXCLUDE       ?= (zz_generated|errors)

# proxy options
PROXY               ?= http://proxy.foo.com:8000
NO_PROXY            ?= localhost,127.0.0.1,.svc.cluster.local
USE_PROXY           ?= false

# docker build flags
DOCKER_CMD_FLAGS    += --network=host
DOCKER_CMD_FLAGS    += --force-rm=$(DOCKER_FORCE_CLEAN)

DOCKER_PROXY_FLAGS  := --build-arg http_proxy=$(PROXY)
DOCKER_PROXY_FLAGS  += --build-arg https_proxy=$(PROXY)
DOCKER_PROXY_FLAGS  += --build-arg HTTP_PROXY=$(PROXY)
DOCKER_PROXY_FLAGS  += --build-arg HTTPS_PROXY=$(PROXY)
DOCKER_PROXY_FLAGS  += --build-arg no_proxy=$(NO_PROXY)
DOCKER_PROXY_FLAGS  += --build-arg NO_PROXY=$(NO_PROXY)

ifeq ($(USE_PROXY), true)
DOCKER_CMD_FLAGS += $(DOCKER_PROXY_FLAGS)
endif

# Godoc server options
GD_PORT             ?= 8080

# Documentation location
DOCS_DIR            ?= docs

# document validation options
UNAME               != uname
export KIND_URL     ?= https://kind.sigs.k8s.io/dl/v0.8.1/kind-$(UNAME)-amd64
KUBECTL_VERSION     ?= v1.18.6
export KUBECTL_URL  ?= https://storage.googleapis.com/kubernetes-release/release/${KUBECTL_VERSION}/bin/linux/amd64/kubectl

# Plugins options
PLUGINS_DIR         := krm-functions
PLUGINS             := $(subst $(PLUGINS_DIR)/,,$(wildcard $(PLUGINS_DIR)/*))
# use this variables to override base images in internal build process
ifneq ($(strip $(DOCKER_BASE_PLUGINS_BUILD_IMAGE)),)
DOCKER_CMD_FLAGS    += --build-arg PLUGINS_BUILD_IMAGE=$(strip $(DOCKER_BASE_PLUGINS_BUILD_IMAGE))
endif
ifneq ($(strip $(DOCKER_BASE_PLUGINS_RELEASE_IMAGE)),)
DOCKER_CMD_FLAGS    += --build-arg PLUGINS_RELEASE_IMAGE=$(strip $(DOCKER_BASE_PLUGINS_RELEASE_IMAGE))
endif


$(PLUGINS):
	 @CGO_ENABLED=0 go build -o $(BINDIR)/$@ $(GO_FLAGS) ./$(PLUGINS_DIR)/$@/

.PHONY: depend
depend:
	@go mod download

.PHONY: build
build: depend
	@CGO_ENABLED=0 go build -o $(BINDIR)/$(EXECUTABLE_CLI) $(GO_FLAGS)

.PHONY: install
install: depend
install:
	@CGO_ENABLED=0 go install .

.PHONY: test
test: lint
test: cover
test: check-copyright

.PHONY: unit-tests
unit-tests: TESTFLAGS += -race -v
unit-tests:
	@echo "Performing unit test step..."
	@go test -run $(TESTS) $(PKG) $(TESTFLAGS) $(COVER_FLAGS)
	@echo "All unit tests passed"

.PHONY: cover
cover: COVER_FLAGS = -covermode=atomic -coverprofile=fullcover.out
cover: unit-tests
	@grep -vE "$(COVER_EXCLUDE)" fullcover.out > $(COVER_PROFILE)
	@./tools/coverage_check $(COVER_PROFILE)

.PHONY: fmt
fmt: lint

.PHONY: lint
lint: tidy
lint: $(LINTER)
	@echo "Performing linting step..."
	@./tools/whitespace_linter
	@./$(LINTER) run --config $(LINTER_CONFIG)
	@echo "Linting completed successfully"

.PHONY: tidy
tidy:
	@echo "Checking that go.mod is up to date..."
	@./tools/gomod_check
	@echo "go.mod is up to date"

.PHONY: golint
golint:
	@./tools/golint

.PHONY: images
images: docker-image
images: docker-image-kubeval-validator docker-image-cloud-init docker-image-replacement-transformer docker-image-templater docker-image-toolbox

.PHONY: docker-image
docker-image:
	@docker build . $(DOCKER_CMD_FLAGS) \
		--label $(LABEL) \
		--target $(DOCKER_TARGET_STAGE) \
		--build-arg MAKE_TARGET=$(DOCKER_MAKE_TARGET) \
		--tag $(DOCKER_IMAGE)
ifeq ($(PUBLISH), true)
	@docker push $(DOCKER_IMAGE)
endif

.PHONY: docker-image-templater
docker-image-templater:
	@docker build $(PLUGINS_DIR)/templater $(DOCKER_CMD_FLAGS) \
		--label $(LABEL) \
		--target $(DOCKER_TARGET_STAGE) \
		--tag $(DOCKER_REGISTRY)/$(DOCKER_IMAGE_PREFIX)/templater:$(DOCKER_IMAGE_TAG)
ifeq ($(PUBLISH), true)
	@docker push $(DOCKER_REGISTRY)/$(DOCKER_IMAGE_PREFIX)/templater:$(DOCKER_IMAGE_TAG)
endif

.PHONY: docker-image-replacement-transformer
docker-image-replacement-transformer:
	@docker build $(PLUGINS_DIR)/replacement-transformer $(DOCKER_CMD_FLAGS) \
		--label $(LABEL) \
		--target $(DOCKER_TARGET_STAGE) \
		--tag $(DOCKER_REGISTRY)/$(DOCKER_IMAGE_PREFIX)/replacement-transformer:$(DOCKER_IMAGE_TAG)
ifeq ($(PUBLISH), true)
	@docker push $(DOCKER_REGISTRY)/$(DOCKER_IMAGE_PREFIX)/replacement-transformer:$(DOCKER_IMAGE_TAG)
endif

.PHONY: docker-image-cloud-init
docker-image-cloud-init:
	@docker build $(PLUGINS_DIR)/cloud-init $(DOCKER_CMD_FLAGS) \
		--label $(LABEL) \
		--target $(DOCKER_TARGET_STAGE) \
		--tag $(DOCKER_REGISTRY)/$(DOCKER_IMAGE_PREFIX)/cloud-init:$(DOCKER_IMAGE_TAG)
ifeq ($(PUBLISH), true)
	@docker push $(DOCKER_REGISTRY)/$(DOCKER_IMAGE_PREFIX)/cloud-init:$(DOCKER_IMAGE_TAG)
endif

.PHONY: docker-image-kubeval-validator
docker-image-kubeval-validator:
	@docker build $(PLUGINS_DIR)/kubeval-validator $(DOCKER_CMD_FLAGS) \
		--label $(LABEL) \
		--target $(DOCKER_TARGET_STAGE) \
		--tag $(DOCKER_REGISTRY)/$(DOCKER_IMAGE_PREFIX)/kubeval-validator:$(DOCKER_IMAGE_TAG)
ifeq ($(PUBLISH), true)
	@docker push $(DOCKER_REGISTRY)/$(DOCKER_IMAGE_PREFIX)/kubeval-validator:$(DOCKER_IMAGE_TAG)
endif

.PHONY: docker-image-toolbox
docker-image-toolbox:
	@docker build $(PLUGINS_DIR)/toolbox $(DOCKER_CMD_FLAGS) \
		--label $(LABEL) \
		--target $(DOCKER_TARGET_STAGE) \
		--tag $(DOCKER_REGISTRY)/$(DOCKER_IMAGE_PREFIX)/toolbox:$(DOCKER_IMAGE_TAG)
ifeq ($(PUBLISH), true)
	@docker push $(DOCKER_REGISTRY)/$(DOCKER_IMAGE_PREFIX)/toolbox:$(DOCKER_IMAGE_TAG)
endif

.PHONY: print-docker-image-tag
print-docker-image-tag:
	@echo "$(DOCKER_IMAGE)"

.PHONY: docker-image-test-suite
docker-image-test-suite: DOCKER_MAKE_TARGET = "cover update-golden generate check-git-diff"
docker-image-test-suite: DOCKER_TARGET_STAGE = builder
docker-image-test-suite: docker-image

.PHONY: docker-image-unit-tests
docker-image-unit-tests: DOCKER_MAKE_TARGET = cover
docker-image-unit-tests: DOCKER_TARGET_STAGE = builder
docker-image-unit-tests: docker-image

.PHONY: docker-image-lint
docker-image-lint: DOCKER_MAKE_TARGET = "lint check-copyright"
docker-image-lint: DOCKER_TARGET_STAGE = builder
docker-image-lint: docker-image

.PHONY: docker-image-golint
docker-image-golint: DOCKER_MAKE_TARGET = golint
docker-image-golint: DOCKER_TARGET_STAGE = builder
docker-image-golint: docker-image

.PHONY: clean
clean:
	@rm -fr $(BINDIR)
	@rm -fr $(COVER_PROFILE)

.PHONY: docs
docs:
	tox

.PHONY: godoc
godoc:
	@go install golang.org/x/tools/cmd/godoc
	@echo "Follow this link to package documentation: http://localhost:${GD_PORT}/pkg/opendev.org/airship/airshipctl/"
	@godoc -http=":${GD_PORT}"

.PHONY: cli-docs
cli-docs:
	@echo "Generating CLI documentation..."
	@go run $(DOCS_DIR)/tools/generate_cli_docs.go
	@echo "CLI documentation generated"

.PHONY: releasenotes
releasenotes:
	@echo "TODO"

$(TOOLBINDIR):
	mkdir -p $(TOOLBINDIR)

$(LINTER): $(TOOLBINDIR)
	./tools/install_linter

.PHONY: update-golden
update-golden: delete-golden
update-golden: TESTFLAGS += -update
update-golden: PKG = opendev.org/airship/airshipctl/cmd/...
update-golden: unit-tests
update-golden: cli-docs

# The delete-golden target is a utility for update-golden
.PHONY: delete-golden
delete-golden:
	@find . -type f -name "*.golden" -delete

# Used by gates after unit-tests and update-golden targets to ensure no files are deleted.
.PHONY: check-git-diff
check-git-diff:
	@./tools/git_diff_check

# add-copyright is a utility to add copyright header to missing files
.PHONY: add-copyright
add-copyright:
	@./tools/add_license.sh

# check-copyright is a utility to check if copyright header is present on all files
.PHONY: check-copyright
check-copyright:
	@./tools/check_copyright

# Validate YAMLs for all sites
.PHONY: validate-docs
validate-docs:
	@./tools/validate_docs

# Generate code
generate: controller-gen
	$(CONTROLLER_GEN) object:headerFile="tools/license_go.txt" paths="./..."

# find or download controller-gen
# download controller-gen if necessary
controller-gen:
ifeq (, $(shell which controller-gen))
	@{ \
	set -e ;\
	CONTROLLER_GEN_TMP_DIR=$$(mktemp -d) ;\
	cd $$CONTROLLER_GEN_TMP_DIR ;\
	go mod init tmp ;\
	go get sigs.k8s.io/controller-tools/cmd/controller-gen@v0.6.0 ;\
	rm -rf $$CONTROLLER_GEN_TMP_DIR ;\
	}
CONTROLLER_GEN=$(GOBIN)/controller-gen
else
CONTROLLER_GEN=$(shell which controller-gen)
endif

# Generate manifests e.g. CRD, RBAC etc.
manifests: controller-gen
	$(CONTROLLER_GEN) $(CRD_OPTIONS) rbac:roleName=manager-role webhook paths="./..." output:crd:artifacts:config=manifests/function/airshipctl-schemas
