update:
	nix flake update

check lint:
	# The single-node-cluster VM test provisions its vars/secrets via clan's
	# generator machinery, which clan-core builds during evaluation (IFD).
	# allow-import-from-derivation isn't a flake nixConfig setting here (that
	# would pin it for every command against this repo, not just `check`) —
	# pass it explicitly for this invocation instead.
	nix flake check --option allow-import-from-derivation true

format fmt:
	nix fmt
