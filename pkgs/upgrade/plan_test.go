package main

import (
	"encoding/json"
	"slices"
	"strings"
	"testing"
)

// The shape flakeModules/cluster/plan.nix emits; worker2 follows nixpkgs.
const examplePlan = `{
  "example": {
    "clusterName": "example",
    "apiserverPort": 6444,
    "machines": [
      {"machine": "cp2", "role": "control-plane", "ip": "10.0.0.2", "targetHost": "root@10.0.0.2", "etcd": true, "apiserver": true, "kubelet": true, "drain": false, "kubernetesVersion": "1.37"},
      {"machine": "cp1", "role": "control-plane", "ip": "10.0.0.1", "targetHost": "root@10.0.0.1", "etcd": true, "apiserver": true, "kubelet": true, "drain": false, "kubernetesVersion": "1.37"},
      {"machine": "worker1", "role": "worker", "ip": "10.0.0.11", "targetHost": "root@10.0.0.11", "etcd": false, "apiserver": false, "kubelet": true, "drain": true, "kubernetesVersion": "1.37"},
      {"machine": "worker2", "role": "worker", "ip": "10.0.0.12", "targetHost": "root@10.0.0.12", "etcd": false, "apiserver": false, "kubelet": true, "drain": true, "kubernetesVersion": null}
    ]
  }
}`

func loadExample(t *testing.T) Plan {
	t.Helper()
	var plans map[string]Plan
	if err := json.Unmarshal([]byte(examplePlan), &plans); err != nil {
		t.Fatal(err)
	}
	p, err := pickPlan(plans, "")
	if err != nil {
		t.Fatal(err)
	}
	return p
}

func names(ms []Machine) []string {
	out := make([]string, len(ms))
	for i, m := range ms {
		out[i] = m.Name
	}
	return out
}

func TestPlanDecoding(t *testing.T) {
	p := loadExample(t)
	if p.APIServerPort != 6444 || len(p.Machines) != 4 {
		t.Fatalf("decoded %+v", p)
	}
	if v := p.Machines[3].KubernetesVersion; v != "" {
		t.Errorf("a null kubernetesVersion decoded as %q, want unpinned", v)
	}
	if got := names(p.etcdMembers()); !slices.Equal(got, []string{"cp2", "cp1"}) {
		t.Errorf("etcd members %v", got)
	}
}

func TestPickPlan(t *testing.T) {
	two := map[string]Plan{"a": {}, "b": {}}
	if _, err := pickPlan(two, ""); err == nil || !strings.Contains(err.Error(), "a, b") {
		t.Errorf("several clusters without --cluster: %v", err)
	}
	if _, err := pickPlan(two, "c"); err == nil {
		t.Error("an unknown cluster was accepted")
	}
	if _, err := pickPlan(map[string]Plan{}, ""); err == nil {
		t.Error("an empty plan was accepted")
	}
}

func TestSelectMachines(t *testing.T) {
	p := loadExample(t)
	for _, tc := range []struct {
		name string
		only []string
		from string
		want []string
	}{
		{"everything, in plan order", nil, "", []string{"cp2", "cp1", "worker1", "worker2"}},
		{"resume", nil, "cp1", []string{"cp1", "worker1", "worker2"}},
		{"only keeps plan order", []string{"worker2", "cp2"}, "", []string{"cp2", "worker2"}},
		{"only after from", []string{"cp2", "worker1"}, "cp1", []string{"worker1"}},
	} {
		t.Run(tc.name, func(t *testing.T) {
			got, err := p.selectMachines(tc.only, tc.from)
			if err != nil {
				t.Fatal(err)
			}
			if !slices.Equal(names(got), tc.want) {
				t.Errorf("got %v, want %v", names(got), tc.want)
			}
		})
	}

	if _, err := p.selectMachines([]string{"nope"}, ""); err == nil || !strings.Contains(err.Error(), "cp2, cp1") {
		t.Errorf("an unknown machine: %v", err)
	}
	if _, err := p.selectMachines([]string{"cp2"}, "worker1"); err == nil {
		t.Error("an empty selection was accepted")
	}
}
