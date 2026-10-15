package main

import (
	"context"
	"io"
	"testing"
	"time"

	appsv1 "k8s.io/api/apps/v1"
	corev1 "k8s.io/api/core/v1"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/client-go/kubernetes/fake"
)

func TestNodeReady(t *testing.T) {
	node := func(ready corev1.ConditionStatus, version string) *corev1.Node {
		return &corev1.Node{
			ObjectMeta: metav1.ObjectMeta{Name: "worker1"},
			Status: corev1.NodeStatus{
				Conditions: []corev1.NodeCondition{
					{Type: corev1.NodeMemoryPressure, Status: corev1.ConditionFalse},
					{Type: corev1.NodeReady, Status: ready},
				},
				NodeInfo: corev1.NodeSystemInfo{KubeletVersion: version},
			},
		}
	}

	for _, tc := range []struct {
		name string
		node *corev1.Node
		want string // the minor the plan pins, or "" for unpinned
		ok   bool
	}{
		{"ready at the pinned minor", node(corev1.ConditionTrue, "v1.37.1"), "1.37", true},
		{"ready, still on the old minor", node(corev1.ConditionTrue, "v1.36.4"), "1.37", false},
		{"a minor that only shares a prefix", node(corev1.ConditionTrue, "v1.370.0"), "1.37", false},
		{"not ready", node(corev1.ConditionFalse, "v1.37.1"), "1.37", false},
		{"unpinned takes any version", node(corev1.ConditionTrue, "v1.36.4"), "", true},
	} {
		t.Run(tc.name, func(t *testing.T) {
			client := fake.NewClientset(tc.node)
			err := nodeReady(context.Background(), client, Machine{Name: "worker1", KubernetesVersion: tc.want})
			if (err == nil) != tc.ok {
				t.Errorf("got %v, want ok=%v", err, tc.ok)
			}
		})
	}

	if err := nodeReady(context.Background(), fake.NewClientset(), Machine{Name: "worker1"}); err == nil {
		t.Error("a missing node counted as Ready")
	}
}

func TestCordonAndDrain(t *testing.T) {
	controller := func(kind string) []metav1.OwnerReference {
		yes := true
		return []metav1.OwnerReference{{APIVersion: "apps/v1", Kind: kind, Name: "x", Controller: &yes}}
	}
	pod := func(name, kind string) *corev1.Pod {
		return &corev1.Pod{
			ObjectMeta: metav1.ObjectMeta{Name: name, Namespace: "default", OwnerReferences: controller(kind)},
			Spec:       corev1.PodSpec{NodeName: "worker1"},
		}
	}
	client := fake.NewClientset(
		&corev1.Node{ObjectMeta: metav1.ObjectMeta{Name: "worker1"}},
		&appsv1.DaemonSet{ObjectMeta: metav1.ObjectMeta{Name: "x", Namespace: "default"}},
		pod("app", "ReplicaSet"),
		pod("agent", "DaemonSet"),
	)
	// No eviction subresource, so the drain deletes; the fake does not act
	// on an eviction.
	client.Resources = []*metav1.APIResourceList{{
		GroupVersion: "v1",
		APIResources: []metav1.APIResource{{Name: "pods", Kind: "Pod", Namespaced: true}},
	}}
	c := &liveCluster{client: client, timeout: 10 * time.Second, out: io.Discard}
	ctx := context.Background()

	if err := c.Cordon(ctx, "worker1"); err != nil {
		t.Fatal(err)
	}
	if err := c.Drain(ctx, "worker1"); err != nil {
		t.Fatal(err)
	}
	pods, err := client.CoreV1().Pods("default").List(ctx, metav1.ListOptions{})
	if err != nil {
		t.Fatal(err)
	}
	if len(pods.Items) != 1 || pods.Items[0].Name != "agent" {
		t.Errorf("after the drain: %v, want only the DaemonSet pod", pods.Items)
	}

	node, _ := client.CoreV1().Nodes().Get(ctx, "worker1", metav1.GetOptions{})
	if !node.Spec.Unschedulable {
		t.Error("cordon left the node schedulable")
	}
	if err := c.Uncordon(ctx, "worker1"); err != nil {
		t.Fatal(err)
	}
	node, _ = client.CoreV1().Nodes().Get(ctx, "worker1", metav1.GetOptions{})
	if node.Spec.Unschedulable {
		t.Error("uncordon left the node unschedulable")
	}
}
