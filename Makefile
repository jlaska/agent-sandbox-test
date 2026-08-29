# agent-run Makefile
# Builds the agent-run binary from Go source

BINARY_NAME := agent-run
VERSION := 1.0.0

# Go parameters
GO := go
GOFLAGS := -v
LDFLAGS := -s -w -X main.version=$(VERSION)

# Directories
SRC_DIR := ./cmd/agent-run
PKG_DIR := ./internal/agentrun
BUILD_DIR := ./bin

.PHONY: all build clean test lint install help

## all: Build the binary
all: build

GO_SOURCES := $(shell find $(SRC_DIR) $(PKG_DIR) -name '*.go' 2>/dev/null)

## build: Build the agent-run binary
build: $(BUILD_DIR)/$(BINARY_NAME)

$(BUILD_DIR)/$(BINARY_NAME): $(GO_SOURCES) go.mod
	@echo "Building $(BINARY_NAME)..."
	@mkdir -p $(BUILD_DIR)
	$(GO) build $(GOFLAGS) -ldflags "$(LDFLAGS)" -o $(BUILD_DIR)/$(BINARY_NAME) $(SRC_DIR)
	@echo "Binary built: $(BUILD_DIR)/$(BINARY_NAME)"

## test: Run all tests
test:
	@echo "Running tests..."
	$(GO) test $(GOFLAGS) -cover $(PKG_DIR)

## lint: Run linter
lint:
	@echo "Running linter..."
	@which golangci-lint > /dev/null 2>&1 || { echo "golangci-lint not found. Install: go install github.com/golangci/golangci-lint/cmd/golangci-lint@latest"; exit 1; }
	golangci-lint run $(PKG_DIR)

## vet: Run go vet
vet:
	@echo "Running go vet..."
	$(GO) vet $(PKG_DIR)

## clean: Remove build artifacts
clean:
	@echo "Cleaning..."
	@rm -rf $(BUILD_DIR)
	$(GO) clean -cache -testcache
	@echo "Clean complete."

## install: Install the binary to GOPATH/bin
install:
	@echo "Installing $(BINARY_NAME)..."
	$(GO) install $(GOFLAGS) -ldflags "$(LDFLAGS)" $(SRC_DIR)
	@echo "Installed to $(shell go env GOPATH)/bin/$(BINARY_NAME)"

## fmt: Format Go source files
fmt:
	@echo "Formatting..."
	$(GO) fmt ./...

## help: Show this help message
help:
	@echo "Usage: make [target]"
	@echo ""
	@echo "Targets:"
	@sed -n 's/^## //p' $(MAKEFILE_LIST) | column -t -s ':' | sed 's/^/  /'
