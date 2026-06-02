// Package clickhouse wraps the Timescape ClickHouse `hubble.flows` table with
// the parameterized queries the policy generator needs. All column names in this
// table contain slashes (e.g. `flow/source/namespace`) and MUST be backtick-quoted;
// every identifier used here is a hard-coded constant, never user input — user
// input only ever arrives as bound query parameters, so the slash-quoting cannot
// be turned into an injection vector.
package clickhouse

import (
	"context"
	"fmt"
	"time"

	"github.com/ClickHouse/clickhouse-go/v2"
	"github.com/ClickHouse/clickhouse-go/v2/lib/driver"
)

type Client struct {
	conn driver.Conn
}

// Config is read from the environment in main.go (see deploy manifests).
type Config struct {
	Addr     string // host:9000 (native protocol)
	Database string // "hubble"
	Username string
	Password string
}

func New(cfg Config) (*Client, error) {
	conn, err := clickhouse.Open(&clickhouse.Options{
		Addr: []string{cfg.Addr},
		Auth: clickhouse.Auth{
			Database: cfg.Database,
			Username: cfg.Username,
			Password: cfg.Password,
		},
		DialTimeout: 5 * time.Second,
		Compression: &clickhouse.Compression{Method: clickhouse.CompressionLZ4},
	})
	if err != nil {
		return nil, fmt.Errorf("open clickhouse: %w", err)
	}
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	if err := conn.Ping(ctx); err != nil {
		return nil, fmt.Errorf("ping clickhouse: %w", err)
	}
	return &Client{conn: conn}, nil
}

func (c *Client) Close() error { return c.conn.Close() }

// Verdict / direction constants as stored by Timescape (verified on the lab).
const (
	VerdictForwarded = 1 // FORWARDED
	VerdictDropped   = 2 // DROPPED
	DirIngress       = 2 // traffic_direction INGRESS (at destination)
	DirEgress        = 1 // traffic_direction EGRESS  (at source)
)

// Clusters returns distinct source cluster names seen in the window.
func (c *Client) Clusters(ctx context.Context, sinceMinutes int) ([]string, error) {
	const q = `
SELECT DISTINCT ` + "`flow/source/cluster_name`" + ` AS c
FROM hubble.flows
WHERE time > now() - INTERVAL ? MINUTE AND c != ''
ORDER BY c`
	return c.scanStrings(ctx, q, sinceMinutes)
}

// Namespaces returns destination namespaces present for a cluster in the window.
func (c *Client) Namespaces(ctx context.Context, cluster string, sinceMinutes int) ([]string, error) {
	const q = `
SELECT DISTINCT ` + "`flow/destination/namespace`" + ` AS ns
FROM hubble.flows
WHERE time > now() - INTERVAL ? MINUTE
  AND ` + "`flow/destination/cluster_name`" + ` = ?
  AND ns != ''
ORDER BY ns`
	return c.scanStrings(ctx, q, sinceMinutes, cluster)
}

// Workload is a selectable target/source entity (Deployment, DaemonSet, ...).
type Workload struct {
	Kind string `json:"kind"` // Deployment | DaemonSet | StatefulSet | ...
	Name string `json:"name"`
}

// Workloads lists distinct (kind,name) destination workloads in a namespace.
func (c *Client) Workloads(ctx context.Context, cluster, namespace string, sinceMinutes int) ([]Workload, error) {
	const q = `
SELECT DISTINCT
  ` + "`flow/destination/workload_kinds`" + `[1] AS kind,
  ` + "`flow/destination/workload_names`" + `[1] AS name
FROM hubble.flows
WHERE time > now() - INTERVAL ? MINUTE
  AND ` + "`flow/destination/cluster_name`" + ` = ?
  AND ` + "`flow/destination/namespace`" + ` = ?
  AND name != ''
ORDER BY kind, name`
	rows, err := c.conn.Query(ctx, q, sinceMinutes, cluster, namespace)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []Workload
	for rows.Next() {
		var w Workload
		if err := rows.Scan(&w.Kind, &w.Name); err != nil {
			return nil, err
		}
		out = append(out, w)
	}
	return out, rows.Err()
}

// EdgeQuery parameterizes a flow aggregation for one target workload (or whole ns).
type EdgeQuery struct {
	Cluster       string
	Namespace     string
	WorkloadName  string // "" => whole namespace
	Direction     int32  // DirIngress or DirEgress
	SinceMinutes  int
	OnlyForwarded bool   // exclude DROPPED (default true)
	SourceNSFilter string // optional: restrict the *peer* namespace
}

// Edge is one deduplicated observed connection, peer -> target on proto/port.
type Edge struct {
	PeerCluster   string   `json:"peerCluster"`
	PeerNamespace string   `json:"peerNamespace"`
	PeerLabels    []string `json:"peerLabels"`
	PeerWorkload  string   `json:"peerWorkload"`
	PeerIdentity  uint32   `json:"peerIdentity"` // reserved identities (host=1, world=2, ...) when no pod
	TargetWorkload string  `json:"targetWorkload"`
	TargetLabels  []string `json:"targetLabels"`
	Protocol      string   `json:"protocol"` // TCP|UDP|SCTP
	Port          uint16   `json:"port"`
	Flows         uint64   `json:"flows"`
}

// Edges runs the core generator aggregation. Peer side = source for ingress,
// destination for egress; target side is the converse. Returns one row per
// distinct (peer-selector, proto, port).
func (c *Client) Edges(ctx context.Context, q EdgeQuery) ([]Edge, error) {
	// Choose peer/target column families by direction. These are constant
	// identifiers chosen by a Go switch — never interpolated from user input.
	var peer, tgt string
	switch q.Direction {
	case DirIngress:
		peer, tgt = "source", "destination"
	case DirEgress:
		peer, tgt = "destination", "source"
	default:
		return nil, fmt.Errorf("invalid direction %d", q.Direction)
	}
	col := func(side, field string) string { return "`flow/" + side + "/" + field + "`" }

	query := `
SELECT
  ` + col(peer, "cluster_name") + `        AS peer_cluster,
  ` + col(peer, "namespace") + `           AS peer_ns,
  arraySort(` + col(peer, "labels") + `)   AS peer_labels,
  ` + col(peer, "workload_names") + `[1]   AS peer_wl,
  ` + col(peer, "identity") + `            AS peer_identity,
  ` + col(tgt, "workload_names") + `[1]    AS tgt_wl,
  arraySort(` + col(tgt, "labels") + `)    AS tgt_labels,
  ` + "`flow/l4/protocol`" + `             AS proto,
  toUInt16(greatest(
     ` + destPort("tcp") + `,
     ` + destPort("udp") + `,
     ` + destPort("sctp") + `)) AS port,
  count() AS flows
FROM hubble.flows
WHERE time > now() - INTERVAL ? MINUTE
  AND ` + col(tgt, "cluster_name") + ` = ?
  AND ` + col(tgt, "namespace") + ` = ?
  AND ` + "`flow/traffic_direction`" + ` = ?
  AND proto != ''
  AND port > 0`

	args := []any{q.SinceMinutes, q.Cluster, q.Namespace, q.Direction}

	if q.OnlyForwarded {
		query += "\n  AND `flow/verdict` = ?"
		args = append(args, int32(VerdictForwarded))
	}
	if q.WorkloadName != "" {
		query += "\n  AND " + col(tgt, "workload_names") + "[1] = ?"
		args = append(args, q.WorkloadName)
	}
	if q.SourceNSFilter != "" {
		query += "\n  AND " + col(peer, "namespace") + " = ?"
		args = append(args, q.SourceNSFilter)
	}
	query += `
GROUP BY peer_cluster, peer_ns, peer_labels, peer_wl, peer_identity, tgt_wl, tgt_labels, proto, port
ORDER BY flows DESC`

	rows, err := c.conn.Query(ctx, query, args...)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []Edge
	for rows.Next() {
		var e Edge
		if err := rows.Scan(
			&e.PeerCluster, &e.PeerNamespace, &e.PeerLabels, &e.PeerWorkload, &e.PeerIdentity,
			&e.TargetWorkload, &e.TargetLabels, &e.Protocol, &e.Port, &e.Flows,
		); err != nil {
			return nil, err
		}
		out = append(out, e)
	}
	return out, rows.Err()
}

// destPort is the listening port for the given L4 proto. It is always the flow's
// destination_port regardless of direction: for ingress the server is the flow
// destination; for egress the server is still the flow destination (the peer the
// target connects out to). So an egress toPorts rule allows that same port.
func destPort(proto string) string {
	return "`flow/l4/" + proto + "/destination_port`"
}

func (c *Client) scanStrings(ctx context.Context, q string, args ...any) ([]string, error) {
	rows, err := c.conn.Query(ctx, q, args...)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []string
	for rows.Next() {
		var s string
		if err := rows.Scan(&s); err != nil {
			return nil, err
		}
		out = append(out, s)
	}
	return out, rows.Err()
}
