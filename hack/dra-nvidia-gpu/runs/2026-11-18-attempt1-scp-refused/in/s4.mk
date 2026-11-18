# Read after tests/bats/Makefile (make -f tests/bats/Makefile -f s4.mk), so RUN_BATS and runner-image are upstream's own.
# The plan's S4 is these three files and no others; upstream's tests-gpu-a10 adds cuda_workloads and extres.
tests-session-s4: runner-image
	$(call RUN_BATS, \
		tests/bats/test_gpu_basic.bats \
		tests/bats/test_gpu_robustness.bats \
		tests/bats/test_gpu_sharing.bats)
