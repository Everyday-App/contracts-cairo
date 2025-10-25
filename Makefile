# Cairo Contracts Makefile

# Load environment variables from .env file if it exists
ifneq (,$(wildcard .env))
    include .env
    export
endif

# Default values for environment variables (can be overridden)
PROFILE ?= test

# Build the project
build:
	scarb build

# Run tests
test:
	scarb test

# Clean build artifacts
clean:
	scarb clean

# Declare contracts
declare-price-converter:
	sncast --profile $(PROFILE) declare --contract-name PriceConverter

declare-alarm-contract:
	sncast --profile $(PROFILE) declare --contract-name AlarmContract

declare-phone-lock-contract:
	sncast --profile $(PROFILE) declare --contract-name PhoneLockContract

# Declare all contracts
declare-all: declare-price-converter declare-alarm-contract declare-phone-lock-contract

# Deploy contracts using environment variables
deploy-price-converter:
	sncast --profile $(PROFILE) deploy \
		--class-hash $(CLASS_HASH_PRICE_CONVERTER_CONTRACT) \
		--constructor-calldata \
			$(PRICE_CONVERTER_ARG1) \
			$(PRICE_CONVERTER_ARG2)

deploy-alarm-contract:
	sncast --profile $(PROFILE) deploy \
		--class-hash $(CLASS_HASH_ALARM_CONTRACT) \
		--constructor-calldata \
			$(ALARM_ARG1) \
			$(ALARM_ARG2) \
			$(ALARM_ARG3) \
			$(ALARM_ARG4) \
			$(ALARM_ARG5)

deploy-phone-lock-contract:
	sncast --profile $(PROFILE) deploy \
		--class-hash $(CLASS_HASH_PHONE_LOCK_CONTRACT) \
		--constructor-calldata \
			$(PHONE_LOCK_ARG1) \
			$(PHONE_LOCK_ARG2) \
			$(PHONE_LOCK_ARG3) \
			$(PHONE_LOCK_ARG4) \
			$(PHONE_LOCK_ARG5)

# Deploy all contracts
deploy-all: deploy-price-converter deploy-alarm-contract deploy-phone-lock-contract

# Run reward calculation scripts
calculate-alarm-rewards:
	cd scripts/alarm && node alarm_reward_calculator.js

calculate-phone-lock-rewards:
	cd scripts/phone_lock && node phone_lock_reward_calculator.js

# Run all reward calculation scripts
calculate-all-rewards: calculate-alarm-rewards calculate-phone-lock-rewards

# Format code
format:
	scarb fmt

# Check code
check:
	scarb check

# Run specific test files
test-alarm:
	scarb test test_alarm_contract

test-phone-lock:
	scarb test test_phone_lock_contract

test-phone-lock-e2e:
	scarb test test_phone_lock_e2e

test-price-converter:
	scarb test test_price_converter

# Setup development environment
setup:
	@echo "Setting up development environment..."
	@if [ ! -f .env ]; then \
		echo "Copying env.example to .env..."; \
		cp env.example .env; \
		echo "Please edit .env with your configuration"; \
	else \
		echo ".env already exists"; \
	fi
	@echo "Installing dependencies..."
	cd scripts && npm install
	@echo "Setup complete!"

# Help
help:
	@echo "Available commands:"
	@echo "  build                    - Build the project"
	@echo "  test                     - Run tests"
	@echo "  clean                    - Clean build artifacts"
	@echo "  declare-price-converter     - Declare PriceConverter contract"
	@echo "  declare-alarm-contract      - Declare AlarmContract contract"
	@echo "  declare-phone-lock-contract - Declare PhoneLockContract contract"
	@echo "  declare-all                 - Declare all contracts"
	@echo "  deploy-price-converter      - Deploy PriceConverter contract"
	@echo "  deploy-alarm-contract       - Deploy AlarmContract contract"
	@echo "  deploy-phone-lock-contract  - Deploy PhoneLockContract contract"
	@echo "  deploy-all                  - Deploy all contracts"
	@echo "  calculate-alarm-rewards     - Calculate alarm contract rewards"
	@echo "  calculate-phone-lock-rewards - Calculate phone lock contract rewards"
	@echo "  calculate-all-rewards       - Calculate all contract rewards"
	@echo "  format                      - Format code with scarb fmt"
	@echo "  check                       - Check code with scarb check"
	@echo "  test-alarm                  - Run alarm contract tests"
	@echo "  test-phone-lock             - Run phone lock contract tests"
	@echo "  test-phone-lock-e2e         - Run phone lock e2e tests"
	@echo "  test-price-converter        - Run price converter tests"
	@echo "  setup                       - Setup development environment"
	@echo "  help                        - Show this help message"
	@echo ""
	@echo "Environment variables (set in .env file or export):"
	@echo "  PROFILE                           - Sncast profile (default: test)"
	@echo "  CLASS_HASH_PRICE_CONVERTER_CONTRACT - PriceConverter class hash"
	@echo "  CLASS_HASH_ALARM_CONTRACT_STRK     - AlarmContract class hash"
	@echo "  CLASS_HASH_PHONE_LOCK_CONTRACT     - PhoneLockContract class hash"
	@echo "  PRICE_CONVERTER_ARG1               - PriceConverter constructor arg 1 (pragma oracle)"
	@echo "  PRICE_CONVERTER_ARG2               - PriceConverter constructor arg 2 (owner)"
	@echo "  ALARM_ARG1                         - AlarmContract constructor arg 1 (owner)"
	@echo "  ALARM_ARG2                         - AlarmContract constructor arg 2 (verified signer)"
	@echo "  ALARM_ARG3                         - AlarmContract constructor arg 3 (token address)"
	@echo "  ALARM_ARG4                         - AlarmContract constructor arg 4 (price converter)"
	@echo "  ALARM_ARG5                         - AlarmContract constructor arg 5 (protocol fees address)"
	@echo "  PHONE_LOCK_ARG1                    - PhoneLockContract constructor arg 1 (owner)"
	@echo "  PHONE_LOCK_ARG2                    - PhoneLockContract constructor arg 2 (verified signer)"
	@echo "  PHONE_LOCK_ARG3                    - PhoneLockContract constructor arg 3 (token address)"
	@echo "  PHONE_LOCK_ARG4                    - PhoneLockContract constructor arg 4 (price converter)"
	@echo "  PHONE_LOCK_ARG5                    - PhoneLockContract constructor arg 5 (protocol fees address)"
	@echo ""
	@echo "Copy env.example to .env and fill in your values"

.PHONY: build test clean declare-price-converter declare-alarm-contract declare-phone-lock-contract declare-all deploy-price-converter deploy-alarm-contract deploy-phone-lock-contract deploy-all calculate-alarm-rewards calculate-phone-lock-rewards calculate-all-rewards format check test-alarm test-phone-lock test-phone-lock-e2e test-price-converter setup help
