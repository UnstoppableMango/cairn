package main

import (
	"context"
	"crypto/tls"
	"crypto/x509"
	"errors"
	"fmt"
	"io"
	"net"
	"net/http"
	"os"
	"os/exec"
	"strconv"
	"strings"
	"time"

	"go.etcd.io/etcd/api/v3/v3rpc/rpctypes"
	clientv3 "go.etcd.io/etcd/client/v3"
	"go.etcd.io/etcd/client/v3/snapshot"
	"go.uber.org/zap"
	corev1 "k8s.io/api/core/v1"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/client-go/kubernetes"
	"k8s.io/client-go/rest"
	"k8s.io/kubectl/pkg/drain"
)

const probeTimeout = 5 * time.Second

// liveCluster reaches every apiserver and etcd member directly, from the
// operator's machine, with the credentials of the current kubeconfig context.
type liveCluster struct {
	plan    Plan
	config  *rest.Config
	client  kubernetes.Interface
	etcdTLS *tls.Config
	timeout time.Duration
	out     io.Writer
}

func newLiveCluster(plan Plan, config *rest.Config, timeout time.Duration, out io.Writer) (*liveCluster, error) {
	client, err := kubernetes.NewForConfig(config)
	if err != nil {
		return nil, err
	}
	etcdTLS, err := etcdTLSConfig(config)
	if err != nil {
		return nil, err
	}
	return &liveCluster{plan: plan, config: config, client: client, etcdTLS: etcdTLS, timeout: timeout, out: out}, nil
}

// etcdTLSConfig is the kubeconfig's TLS identity, which cairn signs with the
// same CA etcd trusts. ETCDCTL_CACERT, ETCDCTL_CERT and ETCDCTL_KEY override
// it, each on its own.
func etcdTLSConfig(config *rest.Config) (*tls.Config, error) {
	base, err := rest.TLSConfigFor(config)
	if err != nil {
		return nil, err
	}
	if base == nil {
		base = &tls.Config{}
	}
	c := base.Clone()
	// A tls-server-name in the kubeconfig names the apiserver, not etcd, and
	// gRPC negotiates its own protocols.
	c.ServerName = ""
	c.NextProtos = nil

	if ca := os.Getenv("ETCDCTL_CACERT"); ca != "" {
		pem, err := os.ReadFile(ca)
		if err != nil {
			return nil, err
		}
		pool := x509.NewCertPool()
		if !pool.AppendCertsFromPEM(pem) {
			return nil, fmt.Errorf("ETCDCTL_CACERT %s holds no certificates", ca)
		}
		c.RootCAs = pool
	}

	cert, key := os.Getenv("ETCDCTL_CERT"), os.Getenv("ETCDCTL_KEY")
	if (cert == "") != (key == "") {
		return nil, fmt.Errorf("set ETCDCTL_CERT and ETCDCTL_KEY together")
	}
	if cert != "" {
		pair, err := tls.LoadX509KeyPair(cert, key)
		if err != nil {
			return nil, err
		}
		c.Certificates = []tls.Certificate{pair}
		c.GetClientCertificate = nil
	}
	return c, nil
}

func (c *liveCluster) etcdConfig(m Machine) clientv3.Config {
	return clientv3.Config{
		Endpoints:   []string{"https://" + net.JoinHostPort(m.IP, "2379")},
		TLS:         c.etcdTLS,
		DialTimeout: probeTimeout,
		Logger:      zap.NewNop(),
	}
}

// EtcdHealthy is `etcdctl endpoint health`: a read the member must answer
// through raft. A permission error still means it answered.
func (c *liveCluster) EtcdHealthy(ctx context.Context, m Machine) error {
	client, err := clientv3.New(c.etcdConfig(m))
	if err != nil {
		return err
	}
	defer client.Close()

	ctx, cancel := context.WithTimeout(ctx, probeTimeout)
	defer cancel()
	_, err = client.Get(ctx, "health")
	if err == nil || errors.Is(err, rpctypes.ErrPermissionDenied) {
		return nil
	}
	return err
}

func (c *liveCluster) SaveSnapshot(ctx context.Context, m Machine, path string) error {
	_, err := snapshot.SaveWithVersion(ctx, zap.NewNop(), c.etcdConfig(m), path)
	return err
}

// APIServerReady asks the machine's own apiserver for /readyz on its backend
// port rather than the VIP, so a ready peer never answers for it. The serving
// certificate lists every control-plane IP, so the cluster CA verifies it.
func (c *liveCluster) APIServerReady(ctx context.Context, m Machine) error {
	config := rest.CopyConfig(c.config)
	config.Host = "https://" + net.JoinHostPort(m.IP, strconv.Itoa(c.plan.APIServerPort))
	config.Timeout = probeTimeout
	client, err := rest.HTTPClientFor(config)
	if err != nil {
		return err
	}

	req, err := http.NewRequestWithContext(ctx, http.MethodGet, config.Host+"/readyz", nil)
	if err != nil {
		return err
	}
	resp, err := client.Do(req)
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		body, _ := io.ReadAll(io.LimitReader(resp.Body, 4096))
		return fmt.Errorf("/readyz answered %s: %s", resp.Status, strings.TrimSpace(string(body)))
	}
	return nil
}

func (c *liveCluster) NodeReady(ctx context.Context, m Machine) error {
	return nodeReady(ctx, c.client, m)
}

func nodeReady(ctx context.Context, client kubernetes.Interface, m Machine) error {
	node, err := client.CoreV1().Nodes().Get(ctx, m.Name, metav1.GetOptions{})
	if err != nil {
		return err
	}

	ready := false
	for _, cond := range node.Status.Conditions {
		if cond.Type == corev1.NodeReady {
			ready = cond.Status == corev1.ConditionTrue
		}
	}
	if !ready {
		return fmt.Errorf("node %s is not Ready", m.Name)
	}

	if m.KubernetesVersion != "" {
		got := node.Status.NodeInfo.KubeletVersion
		if !strings.HasPrefix(got, "v"+m.KubernetesVersion+".") {
			return fmt.Errorf("node %s runs kubelet %s, want v%s.x", m.Name, got, m.KubernetesVersion)
		}
	}
	return nil
}

func (c *liveCluster) drainer(ctx context.Context) *drain.Helper {
	return &drain.Helper{
		Ctx:                 ctx,
		Client:              c.client,
		IgnoreAllDaemonSets: true,
		DeleteEmptyDirData:  true,
		GracePeriodSeconds:  -1,
		Timeout:             c.timeout,
		Out:                 c.out,
		ErrOut:              c.out,
	}
}

func (c *liveCluster) cordon(ctx context.Context, name string, desired bool) error {
	node, err := c.client.CoreV1().Nodes().Get(ctx, name, metav1.GetOptions{})
	if err != nil {
		return err
	}
	return drain.RunCordonOrUncordon(c.drainer(ctx), node, desired)
}

func (c *liveCluster) Cordon(ctx context.Context, name string) error {
	return c.cordon(ctx, name, true)
}

func (c *liveCluster) Uncordon(ctx context.Context, name string) error {
	return c.cordon(ctx, name, false)
}

func (c *liveCluster) Drain(ctx context.Context, name string) error {
	return drain.RunNodeDrain(c.drainer(ctx), name)
}

// clanDeployer deploys with the clan CLI, which builds and switches the
// machine exactly as a manual `clan machines update` would.
type clanDeployer struct {
	flake string
	out   io.Writer
}

func (d clanDeployer) Update(ctx context.Context, m Machine) error {
	cmd := exec.CommandContext(ctx, "clan", "machines", "update", "--flake", d.flake, m.Name)
	cmd.Stdout, cmd.Stderr = d.out, d.out
	return cmd.Run()
}

const rollbackCommand = "nix-env --profile /nix/var/nix/profiles/system --rollback && /nix/var/nix/profiles/system/bin/switch-to-configuration switch"

// rollback switches a machine back to its previous system generation.
func rollback(ctx context.Context, m Machine, out io.Writer) error {
	cmd := exec.CommandContext(ctx, "ssh", m.TargetHost, rollbackCommand)
	cmd.Stdout, cmd.Stderr = out, out
	return cmd.Run()
}
