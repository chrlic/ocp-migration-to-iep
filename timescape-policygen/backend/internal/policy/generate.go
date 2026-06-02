// Package policy synthesizes CiliumNetworkPolicy objects from observed flow edges.
//
// Phase 1 = L4 only (protocol + port). Phase 2 (L7) extends Rule with toPorts.rules
// (http/dns/kafka) — the Edge type already carries the columns needed; see TODO(l7).
//
// Two target scopes are supported (user-selectable):
//   ScopeWorkload  — one CNP per target workload, endpointSelector = identity labels
//   ScopeNamespace — one CNP per namespace, endpointSelector = namespace only
package policy

import (
	"fmt"
	"sort"
	"strings"

	"github.com/mdivis/timescape-policygen/internal/clickhouse"
)

type Scope string

const (
	ScopeWorkload  Scope = "workload"
	ScopeNamespace Scope = "namespace"
)

// Reserved Cilium identities → the special entity used in `fromEntities`/`toEntities`
// when a peer has no pod (host traffic, world, etc.). Keyed by numeric identity.
var reservedEntity = map[uint32]string{
	1: "host",
	2: "world",
	3: "unmanaged",
	4: "health",
	5: "init",
	6: "remote-node",
	7: "kube-apiserver",
}

// labelStrip drops labels that are unstable across rollouts or are k8s plumbing,
// so a per-workload selector keeps matching after a redeploy.
var labelStripPrefixes = []string{
	"k8s:io.kubernetes.pod.namespace", // namespace handled separately
	"k8s:pod-template-hash",
	"k8s:controller-revision-hash",
	"k8s:statefulset.kubernetes.io/pod-name",
	"k8s:apps.kubernetes.io/pod-index",
	"k8s:io.cilium.k8s.policy",         // policy-derived
	"k8s:io.cilium.k8s.namespace.labels",
	"k8s:app.kubernetes.io/version",    // changes on every upgrade → breaks match
	"k8s:version",
	"k8s:helm.sh/chart",                // carries the chart version
	"reserved:",
}

// GenerateInput is the request the API hands to the generator.
type GenerateInput struct {
	Cluster   string
	Namespace string
	Scope     Scope
	// Target workloads when Scope==workload; ignored for namespace scope.
	Targets []clickhouse.Workload
	Ingress []clickhouse.Edge // edges where traffic_direction == ingress
	Egress  []clickhouse.Edge // edges where traffic_direction == egress
}

// ---- CiliumNetworkPolicy object model (minimal, L4) ----

type CNP struct {
	APIVersion string      `yaml:"apiVersion"`
	Kind       string      `yaml:"kind"`
	Metadata   Metadata    `yaml:"metadata"`
	Spec       Spec        `yaml:"spec"`
}

type Metadata struct {
	Name      string            `yaml:"name"`
	Namespace string            `yaml:"namespace"`
	Labels    map[string]string `yaml:"labels,omitempty"`
}

type Spec struct {
	EndpointSelector EndpointSelector `yaml:"endpointSelector"`
	Ingress          []Rule           `yaml:"ingress,omitempty"`
	Egress           []Rule           `yaml:"egress,omitempty"`
}

type EndpointSelector struct {
	MatchLabels map[string]string `yaml:"matchLabels,omitempty"`
}

// Rule is one ingress/egress rule. Peers are mutually exclusive in practice:
// FromEndpoints (in-cluster pods) or FromEntities (host/world/...). ToPorts holds L4.
type Rule struct {
	FromEndpoints []EndpointSelector `yaml:"fromEndpoints,omitempty"`
	FromEntities  []string           `yaml:"fromEntities,omitempty"`
	ToEndpoints   []EndpointSelector `yaml:"toEndpoints,omitempty"`
	ToEntities    []string           `yaml:"toEntities,omitempty"`
	ToPorts       []PortRule         `yaml:"toPorts,omitempty"`
}

type PortRule struct {
	Ports []Port `yaml:"ports"`
	// TODO(l7): Rules *L7Rules `yaml:"rules,omitempty"` — http/dns/kafka in phase 2.
}

type Port struct {
	Port     string `yaml:"port"`
	Protocol string `yaml:"protocol"` // TCP|UDP|SCTP
}

// Generate produces one or more CNPs per the requested scope.
func Generate(in GenerateInput) ([]CNP, error) {
	switch in.Scope {
	case ScopeNamespace:
		return []CNP{genNamespace(in)}, nil
	case ScopeWorkload:
		return genWorkloads(in)
	default:
		return nil, fmt.Errorf("unknown scope %q", in.Scope)
	}
}

func genNamespace(in GenerateInput) CNP {
	return CNP{
		APIVersion: "cilium.io/v2",
		Kind:       "CiliumNetworkPolicy",
		Metadata: Metadata{
			Name:      sanitize("allow-observed-" + in.Namespace),
			Namespace: in.Namespace,
			Labels:    map[string]string{"generated-by": "timescape-policygen"},
		},
		Spec: Spec{
			// Namespace scope: select every endpoint in the namespace.
			EndpointSelector: EndpointSelector{MatchLabels: map[string]string{
				"k8s:io.kubernetes.pod.namespace": in.Namespace,
			}},
			Ingress: buildRules(in.Ingress, true),
			Egress:  buildRules(in.Egress, false),
		},
	}
}

func genWorkloads(in GenerateInput) ([]CNP, error) {
	if len(in.Targets) == 0 {
		return nil, fmt.Errorf("workload scope requires at least one target")
	}
	var out []CNP
	for _, t := range in.Targets {
		ing := filterByTarget(in.Ingress, t.Name)
		egr := filterByTarget(in.Egress, t.Name)
		sel := identitySelector(pickTargetLabels(ing, egr), in.Namespace)
		out = append(out, CNP{
			APIVersion: "cilium.io/v2",
			Kind:       "CiliumNetworkPolicy",
			Metadata: Metadata{
				Name:      sanitize("allow-observed-" + t.Name),
				Namespace: in.Namespace,
				Labels: map[string]string{
					"generated-by":  "timescape-policygen",
					"target-kind":   strings.ToLower(t.Kind),
					"target-name":   t.Name,
				},
			},
			Spec: Spec{
				EndpointSelector: sel,
				Ingress:          buildRules(ing, true),
				Egress:           buildRules(egr, false),
			},
		})
	}
	return out, nil
}

// buildRules groups edges by peer-selector, then nests all (proto,port) pairs for
// that peer under a single rule's toPorts — the compact, human-readable shape.
func buildRules(edges []clickhouse.Edge, ingress bool) []Rule {
	type peerKey struct {
		entity   string // non-empty => entity-based rule
		selector string // canonical matchLabels string for endpoint-based rule
	}
	grouped := map[peerKey]map[Port]struct{}{}
	selFor := map[peerKey]EndpointSelector{}

	for _, e := range edges {
		// Skip ephemeral (>=32768) ports: these are almost always reply traffic
		// captured as a flow (the client's source port), not a real listening
		// port. Allowing them would add meaningless high-port rules. The edge is
		// still returned to the UI table for transparency; it's just not encoded
		// into the policy.
		if e.Port >= 32768 {
			continue
		}
		var k peerKey
		if ent, ok := reservedEntity[e.PeerIdentity]; ok && e.PeerWorkload == "" && len(cleanLabels(e.PeerLabels)) == 0 {
			k = peerKey{entity: ent}
		} else {
			sel := peerSelector(e)
			k = peerKey{selector: canonical(sel.MatchLabels)}
			selFor[k] = sel
		}
		if grouped[k] == nil {
			grouped[k] = map[Port]struct{}{}
		}
		grouped[k][Port{Port: fmt.Sprintf("%d", e.Port), Protocol: e.Protocol}] = struct{}{}
	}

	var rules []Rule
	for k, ports := range grouped {
		pr := PortRule{Ports: sortedPorts(ports)}
		var r Rule
		if k.entity != "" {
			if ingress {
				r.FromEntities = []string{k.entity}
			} else {
				r.ToEntities = []string{k.entity}
			}
		} else {
			if ingress {
				r.FromEndpoints = []EndpointSelector{selFor[k]}
			} else {
				r.ToEndpoints = []EndpointSelector{selFor[k]}
			}
		}
		r.ToPorts = []PortRule{pr}
		rules = append(rules, r)
	}
	// Deterministic output ordering.
	sort.Slice(rules, func(i, j int) bool { return ruleKey(rules[i]) < ruleKey(rules[j]) })
	return rules
}

// peerSelector builds the in-cluster pod selector for a peer: namespace + the
// peer's identity labels (cleaned). Cross-namespace peers carry the namespace label.
func peerSelector(e clickhouse.Edge) EndpointSelector {
	m := map[string]string{}
	if e.PeerNamespace != "" {
		m["k8s:io.kubernetes.pod.namespace"] = e.PeerNamespace
	}
	for k, v := range labelsToMap(cleanLabels(e.PeerLabels)) {
		m[k] = v
	}
	return EndpointSelector{MatchLabels: m}
}

func identitySelector(labels []string, namespace string) EndpointSelector {
	m := map[string]string{"k8s:io.kubernetes.pod.namespace": namespace}
	for k, v := range labelsToMap(cleanLabels(labels)) {
		m[k] = v
	}
	return EndpointSelector{MatchLabels: m}
}

// pickTargetLabels takes the target label set from the first edge that has one.
func pickTargetLabels(ing, egr []clickhouse.Edge) []string {
	for _, set := range [][]clickhouse.Edge{ing, egr} {
		for _, e := range set {
			if len(e.TargetLabels) > 0 {
				return e.TargetLabels
			}
		}
	}
	return nil
}

func filterByTarget(edges []clickhouse.Edge, name string) []clickhouse.Edge {
	var out []clickhouse.Edge
	for _, e := range edges {
		if e.TargetWorkload == name {
			out = append(out, e)
		}
	}
	return out
}

// cleanLabels drops unstable / plumbing labels (see labelStripPrefixes).
func cleanLabels(in []string) []string {
	var out []string
	for _, l := range in {
		drop := false
		for _, p := range labelStripPrefixes {
			if strings.HasPrefix(l, p) {
				drop = true
				break
			}
		}
		if !drop {
			out = append(out, l)
		}
	}
	return out
}

// labelsToMap parses Cilium label strings ("source:key=value") into matchLabels.
// Cilium matchLabels uses the "source:key" form as the map key.
func labelsToMap(in []string) map[string]string {
	m := map[string]string{}
	for _, l := range in {
		src, kv := "k8s", l
		if i := strings.Index(l, ":"); i >= 0 {
			src, kv = l[:i], l[i+1:]
		}
		eq := strings.Index(kv, "=")
		if eq < 0 {
			continue
		}
		m[src+":"+kv[:eq]] = kv[eq+1:]
	}
	return m
}

func canonical(m map[string]string) string {
	keys := make([]string, 0, len(m))
	for k := range m {
		keys = append(keys, k)
	}
	sort.Strings(keys)
	var b strings.Builder
	for _, k := range keys {
		b.WriteString(k)
		b.WriteByte('=')
		b.WriteString(m[k])
		b.WriteByte(',')
	}
	return b.String()
}

func sortedPorts(set map[Port]struct{}) []Port {
	out := make([]Port, 0, len(set))
	for p := range set {
		out = append(out, p)
	}
	sort.Slice(out, func(i, j int) bool {
		if out[i].Protocol != out[j].Protocol {
			return out[i].Protocol < out[j].Protocol
		}
		return out[i].Port < out[j].Port
	})
	return out
}

func ruleKey(r Rule) string {
	parts := append([]string{}, r.FromEntities...)
	parts = append(parts, r.ToEntities...)
	for _, s := range r.FromEndpoints {
		parts = append(parts, canonical(s.MatchLabels))
	}
	for _, s := range r.ToEndpoints {
		parts = append(parts, canonical(s.MatchLabels))
	}
	return strings.Join(parts, "|")
}

// sanitize makes a valid k8s object name from a workload/namespace string.
func sanitize(s string) string {
	s = strings.ToLower(s)
	var b strings.Builder
	for _, r := range s {
		switch {
		case r >= 'a' && r <= 'z', r >= '0' && r <= '9', r == '-':
			b.WriteRune(r)
		default:
			b.WriteByte('-')
		}
	}
	out := strings.Trim(b.String(), "-")
	if len(out) > 253 {
		out = out[:253]
	}
	if out == "" {
		out = "policy"
	}
	return out
}
