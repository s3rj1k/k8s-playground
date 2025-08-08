# Variables
CODENAME := noble
IMAGE_NAME := ubuntu-$(CODENAME)-nvidia
RAW_IMAGE := image.vm
QCOW2_IMAGE := $(IMAGE_NAME).qcow2
DOCKER_REGISTRY := s3rj1k
DOCKER_TAG := latest
DOCKER_IMAGE := $(DOCKER_REGISTRY)/$(IMAGE_NAME):$(DOCKER_TAG)

# Default target
.PHONY: all
all: build-container

# Build raw image using mkosi
.PHONY: build-raw
build-raw:
	mkosi --force build

# Convert raw image to qcow2
.PHONY: convert-qcow2
convert-qcow2: build-raw
	qemu-img convert -f raw -O qcow2 $(RAW_IMAGE) $(QCOW2_IMAGE)

# Create Dockerfile for container disk
## https://github.com/kubevirt/kubevirt/blob/main/docs/container-register-disks.md#high-level-design
Dockerfile: convert-qcow2
	@echo "FROM scratch" > Dockerfile
	@echo "ADD --chown=107:107 $(QCOW2_IMAGE) /disk/" >> Dockerfile

# Build container disk
.PHONY: build-container
build-container: Dockerfile
	docker build -t $(DOCKER_IMAGE) .

# Build container disk
.PHONY: container-disk
container-disk: build-container

# Clean up generated files
.PHONY: clean
clean:
	rm -f $(RAW_IMAGE) $(QCOW2_IMAGE) Dockerfile
	docker rmi $(DOCKER_IMAGE) || true

# Help target
.PHONY: help
help:
	@echo "Available targets:"
	@echo "  all              - Build container disk locally (default)"
	@echo "  build-raw        - Build raw VM image using mkosi"
	@echo "  convert-qcow2    - Convert raw image to qcow2 format"
	@echo "  build-container  - Build Docker container disk"
	@echo "  container-disk   - Build container disk locally"
	@echo "  clean            - Clean up generated files"
	@echo "  help             - Show this help message"
	@echo ""
	@echo "Variables:"
	@echo "  CODENAME         - Ubuntu codename (default: $(CODENAME))"
	@echo "  IMAGE_NAME       - Name of the image (default: $(IMAGE_NAME))"
	@echo "  DOCKER_REGISTRY  - Docker registry (default: $(DOCKER_REGISTRY))"
	@echo "  DOCKER_TAG       - Docker tag (default: $(DOCKER_TAG))"
