.PHONY: help all setup deps build static fmt fmt-check lint hygiene assets-check test test-fast test-slow coverage ci ci-prepare ci-test-prepare ci-fast ci-static ci-test ci-test-partition ci-slow ci-slow-partition ci-dialyzer ci-coverage ci-hygiene ci-full dialyzer e2e

MIX ?= mix
QUIET ?= 1
MAKEFLAGS += --no-print-directory
GATE_LOG_ROOT ?= _build/make-logs
FAST_TEST_PARTITIONS ?= 9
SLOW_TEST_PARTITIONS ?= 8
SLOW_TEST_MAX_CASES ?= 4
CI_TEST_PARTITION_FLAGS := $(if $(MIX_TEST_PARTITION),--partitions $(FAST_TEST_PARTITIONS),)
CI_SLOW_TEST_PARTITION_FLAGS := $(if $(MIX_TEST_PARTITION),--partitions $(SLOW_TEST_PARTITIONS),)
CI_SLOW_TEST_MAX_CASES_FLAGS := --max-cases $(SLOW_TEST_MAX_CASES)
CI_DIALYZER_FLAGS ?= --format short --no-compile --no-check

ifeq ($(OS),Windows_NT)
GATE_RUN_ID := $(or $(GATE_RUN_ID),$(shell powershell.exe -NoProfile -Command "([guid]::NewGuid().ToString('N')).Substring(0, 12)"))
TEST_COMPILE_CMD := set MIX_ENV=test&& $(MIX) compile
else
GATE_RUN_ID := $(or $(GATE_RUN_ID),$(shell date +%Y%m%d%H%M%S))
TEST_COMPILE_CMD := MIX_ENV=test $(MIX) compile
endif

GATE_LOG_DIR ?= $(GATE_LOG_ROOT)/$(GATE_RUN_ID)

ifeq ($(VERBOSE),1)
QUIET := 0
endif

ifeq ($(OS),Windows_NT)
define run_ci_step
	@powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "New-Item -ItemType Directory -Force -Path '$(GATE_LOG_DIR)' | Out-Null; $$label = '$(1)'; $$command = '$(2)'; if ('$(QUIET)' -eq '0') { Write-Output ('==> ' + $$label); cmd.exe /d /s /c $$command; exit $$LASTEXITCODE } else { $$log = '$(GATE_LOG_DIR)/$(1).log'; Write-Output ('==> ' + $$label); cmd.exe /d /s /c $$command > $$log 2>&1; $$status = $$LASTEXITCODE; if ($$null -eq $$status) { $$status = 1 }; if ($$status -eq 0) { Write-Output ('ok  ' + $$label + ' (log: ' + $$log + ')') } else { Write-Output ('fail ' + $$label + ' (exit ' + $$status + ', log: ' + $$log + ')'); Get-Content -LiteralPath $$log; exit $$status } }"
endef
else
define run_ci_step
	@mkdir -p "$(GATE_LOG_DIR)"
	@if [ "$(QUIET)" = "0" ]; then \
		printf '==> %s\n' "$(1)"; \
		$(2); \
	else \
		log="$(GATE_LOG_DIR)/$(1).log"; \
		printf '==> %s\n' "$(1)"; \
		{ $(2); } > "$$log" 2>&1; \
		status=$$?; \
		if [ $$status -eq 0 ]; then \
			printf 'ok  %s (log: %s)\n' "$(1)" "$$log"; \
		else \
			printf 'fail %s (exit %s, log: %s)\n' "$(1)" "$$status" "$$log"; \
			printf '%s\n' "--- $(1) log start ---"; \
			cat "$$log"; \
			printf '%s\n' "--- $(1) log end ---"; \
			exit $$status; \
		fi; \
	fi
endef
endif

help:
	@echo Targets: setup, deps, build, static, fmt, fmt-check, lint, hygiene, assets-check, test, test-fast, test-slow, coverage, dialyzer, e2e
	@echo CI targets: ci-fast, ci-static, ci-test, ci-slow, ci-dialyzer, ci-coverage, ci-hygiene, ci-full
	@echo make all is quiet by default. Logs are written under $(GATE_LOG_ROOT). Use VERBOSE=1 for streamed output.
	@echo make all runs the fast PR gate. Use make ci-full for coverage, Dialyzer, and hygiene ratchets.

setup:
	@$(MIX) setup

deps:
	@$(MIX) deps.get

build:
	@$(MIX) build

static:
	@$(MIX) static

fmt:
	@$(MIX) format

fmt-check:
	@$(MIX) format --check-formatted

lint:
	@$(MIX) lint

hygiene:
	@$(MIX) hygiene

assets-check:
	@cd assets && npm run quality

coverage:
	@$(MIX) test --cover

test:
	@$(MIX) test

test-fast:
	@$(MIX) test --exclude ci_slow

test-slow:
	@$(MIX) test --only ci_slow

dialyzer:
	@$(MIX) dialyzer --format short

e2e:
	@SYMPHONY_RUN_LIVE_E2E=1 $(MIX) test test/symphony_elixir/live_e2e_test.exs

ci-prepare:
	$(call run_ci_step,setup,$(MIX) setup)
	$(call run_ci_step,build,$(MIX) build)

ci-test-prepare: ci-prepare
	$(call run_ci_step,test-compile,$(TEST_COMPILE_CMD))

ci-static: ci-prepare
	$(call run_ci_step,static,$(MIX) static)

ci-test: ci-test-prepare ci-test-partition

ci-test-partition:
	$(call run_ci_step,test,$(MIX) test --exclude ci_slow $(CI_TEST_PARTITION_FLAGS))

ci-slow: ci-test-prepare ci-slow-partition

ci-slow-partition:
	$(call run_ci_step,test-slow,$(MIX) test --exclude test --include ci_slow $(CI_SLOW_TEST_PARTITION_FLAGS) $(CI_SLOW_TEST_MAX_CASES_FLAGS))

ci-dialyzer: ci-prepare
	$(call run_ci_step,dialyzer-plt,$(MIX) dialyzer --plt)
	$(call run_ci_step,dialyzer,$(MIX) dialyzer $(CI_DIALYZER_FLAGS))

ci-coverage: ci-prepare
	$(call run_ci_step,coverage,$(MIX) test --cover)

ci-hygiene:
	$(call run_ci_step,setup,$(MIX) setup)
	$(call run_ci_step,hygiene,$(MIX) hygiene)

ci-fast: ci-prepare
	$(call run_ci_step,static,$(MIX) static)
	$(call run_ci_step,test,$(MIX) test --exclude ci_slow)

ci-full: ci-prepare
	$(call run_ci_step,static,$(MIX) static)
	$(call run_ci_step,coverage,$(MIX) test --cover)
	$(call run_ci_step,dialyzer-plt,$(MIX) dialyzer --plt)
	$(call run_ci_step,dialyzer,$(MIX) dialyzer $(CI_DIALYZER_FLAGS))
	$(call run_ci_step,hygiene,$(MIX) hygiene)

ci: ci-fast

all: ci-fast
