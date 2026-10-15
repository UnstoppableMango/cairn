package main

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"os"
	"os/exec"
	"slices"
	"sort"
	"strings"
)

// Plan is one cluster's entry in the `cairn-upgrade-plan` flake output,
// emitted by flakeModules/cluster/plan.nix.
type Plan struct {
	ClusterName   string    `json:"clusterName"`
	APIServerPort int       `json:"apiserverPort"`
	Machines      []Machine `json:"machines"`
}

// Machine is one step of the rollout, in the order the plan gives.
type Machine struct {
	Name       string `json:"machine"`
	Role       string `json:"role"`
	IP         string `json:"ip"`
	TargetHost string `json:"targetHost"`
	Etcd       bool   `json:"etcd"`
	APIServer  bool   `json:"apiserver"`
	Kubelet    bool   `json:"kubelet"`
	Drain      bool   `json:"drain"`
	// The minor the kubelet should report once updated, or empty when the
	// cluster follows nixpkgs and the plan cannot know it.
	KubernetesVersion string `json:"kubernetesVersion"`
}

// Services lists what the machine runs, for messages.
func (m Machine) Services() string {
	var s []string
	if m.Etcd {
		s = append(s, "etcd")
	}
	if m.APIServer {
		s = append(s, "apiserver")
	}
	if m.Kubelet {
		s = append(s, "kubelet")
	}
	return strings.Join(s, ",")
}

// loadPlans reads every cluster's plan from file, or evaluates the flake's
// `cairn-upgrade-plan` output when file is empty.
func loadPlans(ctx context.Context, flake, file string) (map[string]Plan, error) {
	var raw []byte
	if file != "" {
		b, err := os.ReadFile(file)
		if err != nil {
			return nil, err
		}
		raw = b
	} else {
		var stderr bytes.Buffer
		cmd := exec.CommandContext(ctx, "nix", "eval", "--json", flake+"#cairn-upgrade-plan")
		cmd.Stderr = &stderr
		b, err := cmd.Output()
		if err != nil {
			return nil, fmt.Errorf("evaluating %s#cairn-upgrade-plan (does the flake import cairn's flake module and declare a cluster under cairn.clusters?): %w\n%s", flake, err, stderr.String())
		}
		raw = b
	}

	var plans map[string]Plan
	if err := json.Unmarshal(raw, &plans); err != nil {
		return nil, fmt.Errorf("reading the upgrade plan: %w", err)
	}
	return plans, nil
}

// pickPlan returns the named cluster's plan, or the only one when name is
// empty.
func pickPlan(plans map[string]Plan, name string) (Plan, error) {
	if name != "" {
		p, ok := plans[name]
		if !ok {
			return Plan{}, fmt.Errorf("no cluster named %s in the plan", name)
		}
		return p, nil
	}

	names := make([]string, 0, len(plans))
	for n := range plans {
		names = append(names, n)
	}
	sort.Strings(names)
	switch len(names) {
	case 0:
		return Plan{}, fmt.Errorf("the flake declares no cairn.clusters")
	case 1:
		return plans[names[0]], nil
	default:
		return Plan{}, fmt.Errorf("the flake declares several clusters (%s); pick one with --cluster", strings.Join(names, ", "))
	}
}

func (p Plan) machine(name string) (Machine, error) {
	for _, m := range p.Machines {
		if m.Name == name {
			return m, nil
		}
	}
	names := make([]string, len(p.Machines))
	for i, m := range p.Machines {
		names[i] = m.Name
	}
	return Machine{}, fmt.Errorf("%s is not a machine in cluster %s (machines: %s)", name, p.ClusterName, strings.Join(names, ", "))
}

// selectMachines narrows the plan to what this run updates, keeping the plan's
// order: everything from `from` onwards, then only the machines in `only`.
func (p Plan) selectMachines(only []string, from string) ([]Machine, error) {
	for _, name := range append(slices.Clone(only), from) {
		if name == "" {
			continue
		}
		if _, err := p.machine(name); err != nil {
			return nil, err
		}
	}

	var selected []Machine
	started := from == ""
	for _, m := range p.Machines {
		started = started || m.Name == from
		if !started || (len(only) > 0 && !slices.Contains(only, m.Name)) {
			continue
		}
		selected = append(selected, m)
	}
	if len(selected) == 0 {
		return nil, fmt.Errorf("nothing to update")
	}
	return selected, nil
}

func (p Plan) etcdMembers() []Machine {
	return p.filter(func(m Machine) bool { return m.Etcd })
}

func (p Plan) apiservers() []Machine {
	return p.filter(func(m Machine) bool { return m.APIServer })
}

func (p Plan) filter(keep func(Machine) bool) []Machine {
	var out []Machine
	for _, m := range p.Machines {
		if keep(m) {
			out = append(out, m)
		}
	}
	return out
}
