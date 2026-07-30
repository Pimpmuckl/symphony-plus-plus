.PHONY: all ci ci-fast ci-static ci-test ci-dialyzer ci-coverage ci-full

all ci ci-fast ci-static ci-test ci-dialyzer ci-coverage ci-full:
	$(MAKE) -C elixir $@
