.PHONY: all ci ci-fast ci-static ci-test ci-dialyzer ci-coverage ci-full

all:
	$(MAKE) -C elixir all
	cd elixir/assets && npm ci && npm run build

ci ci-fast ci-static ci-test ci-dialyzer ci-coverage ci-full:
	$(MAKE) -C elixir $@
