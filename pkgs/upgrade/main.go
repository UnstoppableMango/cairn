// cairn-upgrade rolls a cairn cluster one machine at a time: `clan machines
// update` per machine, gated on etcd, apiserver and node health before and
// after. It deploys nothing itself. See docs/UPGRADES.md for the design and the
// manual runbook it automates.
package main

import (
	"context"
	"fmt"
	"os"
	"os/signal"
	"syscall"
	"time"

	"github.com/spf13/cobra"
	"k8s.io/client-go/tools/clientcmd"
)

type options struct {
	flake       string
	cluster     string
	planFile    string
	only        []string
	from        string
	skipDrain   bool
	noSnapshot  bool
	snapshotDir string
	timeout     time.Duration
	dryRun      bool
	rollback    string
	kubeconfig  string
}

func newCommand() *cobra.Command {
	var o options
	cmd := &cobra.Command{
		Use:   "cairn-upgrade",
		Short: "Update a cairn cluster's machines one at a time",
		Long: `Updates a cairn cluster's machines one at a time, in the order the flake's
cairn-upgrade-plan.<cluster> output gives: control plane first, then workers.

etcd is reached with the client certificate from the current kubeconfig
context, which cairn signs with the same CA etcd trusts. Set ETCDCTL_CACERT,
ETCDCTL_CERT and ETCDCTL_KEY to use other credentials.`,
		Args:          cobra.NoArgs,
		SilenceUsage:  true,
		SilenceErrors: true,
		RunE: func(cmd *cobra.Command, _ []string) error {
			return run(cmd.Context(), o)
		},
	}

	f := cmd.Flags()
	f.StringVar(&o.flake, "flake", ".", "flake declaring the cluster")
	f.StringVar(&o.cluster, "cluster", "", "cluster to upgrade; required when the flake has several")
	f.StringVar(&o.planFile, "plan", "", "read the plan JSON from this file instead of evaluating the flake")
	f.StringArrayVar(&o.only, "only", nil, "update only this machine (repeatable)")
	f.StringVar(&o.from, "from", "", "resume the rollout at this machine, skipping those before it")
	f.BoolVar(&o.skipDrain, "skip-drain", false, "do not cordon and drain schedulable machines")
	f.BoolVar(&o.noSnapshot, "no-snapshot", false, "do not take an etcd snapshot before the first update")
	f.StringVar(&o.snapshotDir, "snapshot-dir", ".", "where the etcd snapshot is written")
	f.DurationVar(&o.timeout, "timeout", 10*time.Minute, "how long each drain and post-update gate waits")
	f.BoolVar(&o.dryRun, "dry-run", false, "print the plan and every step without acting")
	f.StringVar(&o.rollback, "rollback", "", "switch this machine back to its previous generation and exit")
	f.StringVar(&o.kubeconfig, "kubeconfig", "", "kubeconfig to use instead of the default loading rules")
	return cmd
}

func run(ctx context.Context, o options) error {
	plans, err := loadPlans(ctx, o.flake, o.planFile)
	if err != nil {
		return err
	}
	plan, err := pickPlan(plans, o.cluster)
	if err != nil {
		return err
	}

	if o.rollback != "" {
		m, err := plan.machine(o.rollback)
		if err != nil {
			return err
		}
		if o.dryRun {
			fmt.Printf("would run on %s: %s\n", m.TargetHost, rollbackCommand)
			return nil
		}
		fmt.Fprintf(os.Stderr, "==> rolling %s (%s) back to its previous generation\n", m.Name, m.TargetHost)
		return rollback(ctx, m, os.Stderr)
	}

	selected, err := plan.selectMachines(o.only, o.from)
	if err != nil {
		return err
	}

	r := &rollout{
		plan:     plan,
		drain:    !o.skipDrain,
		timeout:  o.timeout,
		interval: 5 * time.Second,
		now:      time.Now,
		log:      os.Stderr,
	}
	if !o.noSnapshot {
		r.snapshotDir = o.snapshotDir
	}

	if o.dryRun {
		r.dryRun(os.Stdout, o.flake, selected)
		return nil
	}

	rules := clientcmd.NewDefaultClientConfigLoadingRules()
	rules.ExplicitPath = o.kubeconfig
	config, err := clientcmd.NewNonInteractiveDeferredLoadingClientConfig(rules, nil).ClientConfig()
	if err != nil {
		return fmt.Errorf("loading kubeconfig: %w", err)
	}
	r.cluster, err = newLiveCluster(plan, config, o.timeout, os.Stderr)
	if err != nil {
		return err
	}
	r.deployer = clanDeployer{flake: o.flake, out: os.Stderr}

	return r.run(ctx, selected)
}

func main() {
	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()
	if err := newCommand().ExecuteContext(ctx); err != nil {
		fmt.Fprintln(os.Stderr, "cairn-upgrade:", err)
		os.Exit(1)
	}
}
