package main

import (
	"context"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strings"
	"time"
)

// Cluster is what the rollout observes and changes in the running cluster.
// cluster.go implements it against the real apiservers and etcd members.
type Cluster interface {
	EtcdHealthy(ctx context.Context, m Machine) error
	APIServerReady(ctx context.Context, m Machine) error
	// NodeReady also requires the kubelet to report the plan's minor, when
	// the plan pins one.
	NodeReady(ctx context.Context, m Machine) error
	SaveSnapshot(ctx context.Context, m Machine, path string) error
	Cordon(ctx context.Context, node string) error
	Uncordon(ctx context.Context, node string) error
	Drain(ctx context.Context, node string) error
}

// Deployer switches one machine to the flake's configuration.
type Deployer interface {
	Update(ctx context.Context, m Machine) error
}

type rollout struct {
	plan     Plan
	cluster  Cluster
	deployer Deployer

	drain       bool
	snapshotDir string // empty skips the snapshot
	timeout     time.Duration
	interval    time.Duration
	now         func() time.Time
	log         io.Writer
}

func (r *rollout) logf(format string, args ...any) {
	fmt.Fprintf(r.log, "==> "+format+"\n", args...)
}

func (r *rollout) run(ctx context.Context, selected []Machine) error {
	if r.snapshotDir != "" && len(r.plan.etcdMembers()) > 0 {
		path, err := r.snapshot(ctx)
		if err != nil {
			return err
		}
		r.logf("etcd snapshot saved to %s", path)
	}

	for _, m := range selected {
		if err := r.machine(ctx, m); err != nil {
			return fmt.Errorf("%s: %w; the rollout stopped here", m.Name, err)
		}
		r.logf("%s: done", m.Name)
	}

	names := make([]string, len(selected))
	for i, m := range selected {
		names[i] = m.Name
	}
	r.logf("cluster %s: updated %s", r.plan.ClusterName, strings.Join(names, " "))
	return nil
}

func (r *rollout) machine(ctx context.Context, m Machine) error {
	r.logf("%s: checking cluster health", m.Name)
	if err := r.preGate(ctx, m); err != nil {
		return err
	}

	drained := r.drain && m.Drain
	if drained {
		if err := r.cluster.Cordon(ctx, m.Name); err != nil {
			return fmt.Errorf("cordon: %w", err)
		}
		if err := r.cluster.Drain(ctx, m.Name); err != nil {
			if uerr := r.cluster.Uncordon(ctx, m.Name); uerr != nil {
				return fmt.Errorf("drain: %w; uncordoning it again also failed: %w", err, uerr)
			}
			return fmt.Errorf("drain: %w; uncordoned it and stopped before updating", err)
		}
	}

	r.logf("%s: updating", m.Name)
	if err := r.deployer.Update(ctx, m); err != nil {
		return fmt.Errorf("update: %w", err)
	}

	if err := r.postGate(ctx, m); err != nil {
		return err
	}
	if drained {
		if err := r.cluster.Uncordon(ctx, m.Name); err != nil {
			return fmt.Errorf("uncordon: %w", err)
		}
	}
	return nil
}

// preGate is the quorum-loss guard: it refuses to take a machine down while
// any other etcd member or apiserver is already unhealthy. The machine about
// to update is only reported, since updating it may be the fix.
func (r *rollout) preGate(ctx context.Context, target Machine) error {
	var failed []string
	check := func(ms []Machine, what string, healthy func(context.Context, Machine) error) {
		for _, m := range ms {
			err := healthy(ctx, m)
			if err == nil {
				continue
			}
			if m.Name == target.Name {
				r.logf("warning: %s's own %s is unhealthy: %v", m.Name, what, err)
			} else {
				failed = append(failed, fmt.Sprintf("%s on %s (%v)", what, m.Name, err))
			}
		}
	}
	check(r.plan.etcdMembers(), "etcd", r.cluster.EtcdHealthy)
	check(r.plan.apiservers(), "apiserver", r.cluster.APIServerReady)

	if len(failed) > 0 {
		return fmt.Errorf("not updating while unhealthy: %s", strings.Join(failed, "; "))
	}
	return nil
}

func (r *rollout) postGate(ctx context.Context, m Machine) error {
	if m.Etcd {
		if err := r.waitFor(ctx, "etcd member healthy", m, r.cluster.EtcdHealthy); err != nil {
			return err
		}
	}
	if m.APIServer {
		if err := r.waitFor(ctx, "apiserver ready", m, r.cluster.APIServerReady); err != nil {
			return err
		}
	}
	if m.Kubelet {
		what := "node Ready"
		if m.KubernetesVersion != "" {
			what += " at v" + m.KubernetesVersion
		}
		if err := r.waitFor(ctx, what, m, r.cluster.NodeReady); err != nil {
			return err
		}
	}
	return nil
}

func (r *rollout) waitFor(ctx context.Context, what string, m Machine, check func(context.Context, Machine) error) error {
	deadline := r.now().Add(r.timeout)
	for {
		err := check(ctx, m)
		if err == nil {
			r.logf("%s: %s", m.Name, what)
			return nil
		}
		if !r.now().Before(deadline) {
			return fmt.Errorf("gave up after %s waiting for %s: %w", r.timeout, what, err)
		}
		select {
		case <-ctx.Done():
			return ctx.Err()
		case <-time.After(r.interval):
		}
	}
}

// snapshot saves etcd from the first member that will give one.
func (r *rollout) snapshot(ctx context.Context) (string, error) {
	if err := os.MkdirAll(r.snapshotDir, 0o700); err != nil {
		return "", err
	}
	path := filepath.Join(r.snapshotDir, fmt.Sprintf("etcd-%s-%s.db", r.plan.ClusterName, r.now().UTC().Format("20060102T150405Z")))

	var errs []error
	for _, m := range r.plan.etcdMembers() {
		err := r.cluster.SaveSnapshot(ctx, m, path)
		if err == nil {
			return path, nil
		}
		errs = append(errs, fmt.Errorf("%s: %w", m.Name, err))
	}
	return "", fmt.Errorf("could not take an etcd snapshot from any member: %w", errors.Join(errs...))
}

// dryRun prints every step run would take, without touching anything.
func (r *rollout) dryRun(w io.Writer, flake string, selected []Machine) {
	fmt.Fprintf(w, "cluster %s: %d machine(s), in order\n", r.plan.ClusterName, len(selected))
	if r.snapshotDir != "" && len(r.plan.etcdMembers()) > 0 {
		fmt.Fprintf(w, "snapshot etcd into %s\n", r.snapshotDir)
	}
	for _, m := range selected {
		drain := r.drain && m.Drain
		fmt.Fprintf(w, "%s (%s; %s)\n", m.Name, m.Role, m.Services())
		fmt.Fprintln(w, "  pre-gate: every other etcd member healthy, every other apiserver /readyz")
		if drain {
			fmt.Fprintf(w, "  cordon and drain %s\n", m.Name)
		}
		fmt.Fprintf(w, "  clan machines update --flake %s %s\n", flake, m.Name)

		var post []string
		if m.Etcd {
			post = append(post, "etcd member healthy")
		}
		if m.APIServer {
			post = append(post, fmt.Sprintf("/readyz on :%d", r.plan.APIServerPort))
		}
		if m.Kubelet {
			if m.KubernetesVersion != "" {
				post = append(post, "node Ready at v"+m.KubernetesVersion)
			} else {
				post = append(post, "node Ready")
			}
		}
		if len(post) > 0 {
			fmt.Fprintf(w, "  post-gate: %s\n", strings.Join(post, ", "))
		}
		if drain {
			fmt.Fprintf(w, "  uncordon %s\n", m.Name)
		}
	}
}
