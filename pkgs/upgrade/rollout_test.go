package main

import (
	"bytes"
	"context"
	"errors"
	"fmt"
	"slices"
	"strings"
	"testing"
	"time"
)

// fakeCluster records every action, and fails a check while its key
// ("etcd cp1", "node worker1", ...) is in unhealthy.
type fakeCluster struct {
	unhealthy map[string]bool
	drainErr  error
	// Called after each update, so a test can bring a machine back.
	onUpdate func(Machine)
	actions  []string
}

func (f *fakeCluster) check(kind string, m Machine) error {
	if f.unhealthy[kind+" "+m.Name] {
		return fmt.Errorf("%s down", kind)
	}
	return nil
}

func (f *fakeCluster) EtcdHealthy(_ context.Context, m Machine) error { return f.check("etcd", m) }
func (f *fakeCluster) APIServerReady(_ context.Context, m Machine) error {
	return f.check("apiserver", m)
}
func (f *fakeCluster) NodeReady(_ context.Context, m Machine) error { return f.check("node", m) }

func (f *fakeCluster) SaveSnapshot(_ context.Context, m Machine, _ string) error {
	if err := f.check("etcd", m); err != nil {
		return err
	}
	f.actions = append(f.actions, "snapshot "+m.Name)
	return nil
}

func (f *fakeCluster) Cordon(_ context.Context, n string) error {
	f.actions = append(f.actions, "cordon "+n)
	return nil
}

func (f *fakeCluster) Uncordon(_ context.Context, n string) error {
	f.actions = append(f.actions, "uncordon "+n)
	return nil
}

func (f *fakeCluster) Drain(_ context.Context, n string) error {
	if f.drainErr != nil {
		return f.drainErr
	}
	f.actions = append(f.actions, "drain "+n)
	return nil
}

func (f *fakeCluster) Update(_ context.Context, m Machine) error {
	f.actions = append(f.actions, "update "+m.Name)
	if f.onUpdate != nil {
		f.onUpdate(m)
	}
	return nil
}

func newTestRollout(t *testing.T, f *fakeCluster) (*rollout, *bytes.Buffer) {
	t.Helper()
	var log bytes.Buffer
	return &rollout{
		plan:        loadExample(t),
		cluster:     f,
		deployer:    f,
		drain:       true,
		snapshotDir: t.TempDir(),
		timeout:     50 * time.Millisecond,
		interval:    time.Millisecond,
		now:         time.Now,
		log:         &log,
	}, &log
}

func TestRolloutOrder(t *testing.T) {
	f := &fakeCluster{}
	r, _ := newTestRollout(t, f)
	if err := r.run(context.Background(), r.plan.Machines); err != nil {
		t.Fatal(err)
	}
	want := []string{
		"snapshot cp2",
		"update cp2",
		"update cp1",
		"cordon worker1", "drain worker1", "update worker1", "uncordon worker1",
		"cordon worker2", "drain worker2", "update worker2", "uncordon worker2",
	}
	if !slices.Equal(f.actions, want) {
		t.Errorf("actions\n got %v\nwant %v", f.actions, want)
	}
}

func TestSnapshotFallsBackToAHealthyMember(t *testing.T) {
	f := &fakeCluster{unhealthy: map[string]bool{"etcd cp2": true}}
	r, _ := newTestRollout(t, f)
	if _, err := r.snapshot(context.Background()); err != nil {
		t.Fatal(err)
	}
	if !slices.Equal(f.actions, []string{"snapshot cp1"}) {
		t.Errorf("actions %v", f.actions)
	}
}

func TestPreGateRefusesWhenAPeerIsDown(t *testing.T) {
	f := &fakeCluster{unhealthy: map[string]bool{"etcd cp1": true}}
	r, _ := newTestRollout(t, f)
	r.snapshotDir = ""

	err := r.run(context.Background(), r.plan.Machines[:1])
	if err == nil || !strings.Contains(err.Error(), "etcd on cp1") {
		t.Fatalf("got %v, want a refusal naming etcd on cp1", err)
	}
	if len(f.actions) != 0 {
		t.Errorf("acted despite the refusal: %v", f.actions)
	}
}

func TestPreGateOnlyWarnsAboutTheTarget(t *testing.T) {
	f := &fakeCluster{unhealthy: map[string]bool{"apiserver cp2": true}}
	// The update is what brings it back.
	f.onUpdate = func(m Machine) { delete(f.unhealthy, "apiserver "+m.Name) }
	r, log := newTestRollout(t, f)
	r.snapshotDir = ""

	if err := r.run(context.Background(), r.plan.Machines[:1]); err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(log.String(), "warning: cp2's own apiserver is unhealthy") {
		t.Errorf("no warning in\n%s", log)
	}
}

func TestDrainFailureUncordonsAndStops(t *testing.T) {
	f := &fakeCluster{drainErr: errors.New("PDB says no")}
	r, _ := newTestRollout(t, f)
	r.snapshotDir = ""

	err := r.run(context.Background(), r.plan.Machines[2:])
	if err == nil || !strings.Contains(err.Error(), "PDB says no") {
		t.Fatalf("got %v", err)
	}
	if want := []string{"cordon worker1", "uncordon worker1"}; !slices.Equal(f.actions, want) {
		t.Errorf("actions %v, want %v", f.actions, want)
	}
}

func TestPostGateTimesOut(t *testing.T) {
	// A kubelet that never comes back at the pinned minor.
	f := &fakeCluster{unhealthy: map[string]bool{"node worker1": true}}
	r, _ := newTestRollout(t, f)
	r.snapshotDir = ""

	err := r.run(context.Background(), r.plan.Machines[2:])
	if err == nil || !strings.Contains(err.Error(), "waiting for node Ready at v1.37") {
		t.Fatalf("got %v", err)
	}
	// Left cordoned for whoever picks it up, and worker2 untouched.
	if want := []string{"cordon worker1", "drain worker1", "update worker1"}; !slices.Equal(f.actions, want) {
		t.Errorf("actions %v, want %v", f.actions, want)
	}
}

func TestSkipDrain(t *testing.T) {
	f := &fakeCluster{}
	r, _ := newTestRollout(t, f)
	r.drain, r.snapshotDir = false, ""

	if err := r.run(context.Background(), r.plan.Machines[2:3]); err != nil {
		t.Fatal(err)
	}
	if want := []string{"update worker1"}; !slices.Equal(f.actions, want) {
		t.Errorf("actions %v, want %v", f.actions, want)
	}
}

func TestDryRun(t *testing.T) {
	r, _ := newTestRollout(t, &fakeCluster{})
	var out bytes.Buffer
	r.dryRun(&out, ".", r.plan.Machines)

	for _, line := range []string{
		"cp2 (control-plane; etcd,apiserver,kubelet)",
		"  post-gate: etcd member healthy, /readyz on :6444, node Ready at v1.37",
		"  cordon and drain worker1",
		"  post-gate: node Ready\n",
	} {
		if !strings.Contains(out.String(), line) {
			t.Errorf("dry run lacks %q:\n%s", line, out.String())
		}
	}
	if strings.Contains(out.String(), "drain cp") {
		t.Errorf("dry run drains a master-only machine:\n%s", out.String())
	}
}
