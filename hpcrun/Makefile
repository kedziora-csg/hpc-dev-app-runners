# The whole off-cluster regression suite.  No node hours, no container, no
# scheduler: the placement checks run against the frozen reports in
# tests/fixtures/, and the host-side checks against the shipped schemas,
# experiments and cluster descriptions.  Run it after any edit under hpcrun/ or
# sites/.
test:
	@tests/self_test.sh
	@echo
	@tests/test_results.sh
	@echo
	@tests/test_cluster.sh
	@echo
	@tests/test_app_contract.sh
	@echo
	@tests/test_bench.sh

.PHONY: test
