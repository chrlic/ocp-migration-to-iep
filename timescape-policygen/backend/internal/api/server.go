// Package api exposes the read-only flow queries and the policy generator over HTTP.
// The browser never talks to ClickHouse directly — only this service holds the creds.
package api

import (
	"context"
	"encoding/json"
	"net/http"
	"strconv"
	"time"

	"github.com/mdivis/timescape-policygen/internal/clickhouse"
	"github.com/mdivis/timescape-policygen/internal/policy"
)

type Server struct {
	ch  *clickhouse.Client
	mux *http.ServeMux
}

func New(ch *clickhouse.Client) *Server {
	s := &Server{ch: ch, mux: http.NewServeMux()}
	s.routes()
	return s
}

func (s *Server) Handler() http.Handler { return s.mux }

func (s *Server) routes() {
	s.mux.HandleFunc("GET /api/healthz", func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusOK)
	})
	s.mux.HandleFunc("GET /api/clusters", s.handleClusters)
	s.mux.HandleFunc("GET /api/namespaces", s.handleNamespaces)
	s.mux.HandleFunc("GET /api/workloads", s.handleWorkloads)
	s.mux.HandleFunc("POST /api/generate", s.handleGenerate)
}

func (s *Server) handleClusters(w http.ResponseWriter, r *http.Request) {
	ctx, cancel := ctx(r)
	defer cancel()
	cs, err := s.ch.Clusters(ctx, sinceMin(r))
	respond(w, cs, err)
}

func (s *Server) handleNamespaces(w http.ResponseWriter, r *http.Request) {
	ctx, cancel := ctx(r)
	defer cancel()
	cluster := r.URL.Query().Get("cluster")
	if cluster == "" {
		httpErr(w, http.StatusBadRequest, "cluster is required")
		return
	}
	ns, err := s.ch.Namespaces(ctx, cluster, sinceMin(r))
	respond(w, ns, err)
}

func (s *Server) handleWorkloads(w http.ResponseWriter, r *http.Request) {
	ctx, cancel := ctx(r)
	defer cancel()
	q := r.URL.Query()
	cluster, ns := q.Get("cluster"), q.Get("namespace")
	if cluster == "" || ns == "" {
		httpErr(w, http.StatusBadRequest, "cluster and namespace are required")
		return
	}
	wls, err := s.ch.Workloads(ctx, cluster, ns, sinceMin(r))
	respond(w, wls, err)
}

// GenerateRequest is the POST body from the UI.
type GenerateRequest struct {
	Cluster        string                  `json:"cluster"`
	Namespace      string                  `json:"namespace"`
	Scope          policy.Scope            `json:"scope"` // "workload" | "namespace"
	Targets        []clickhouse.Workload   `json:"targets"`
	SourceNSFilter string                  `json:"sourceNamespaceFilter"`
	SinceMinutes   int                     `json:"sinceMinutes"`
	IncludeEgress  bool                    `json:"includeEgress"`
	IncludeDropped bool                    `json:"includeDropped"` // include DROPPED edges (audit)
}

// GenerateResponse returns both the structured edges (for the table/preview) and
// the rendered YAML (for copy/apply).
type GenerateResponse struct {
	Ingress []clickhouse.Edge `json:"ingress"`
	Egress  []clickhouse.Edge `json:"egress"`
	YAML    string            `json:"yaml"`
}

func (s *Server) handleGenerate(w http.ResponseWriter, r *http.Request) {
	ctx, cancel := ctx(r)
	defer cancel()
	var req GenerateRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		httpErr(w, http.StatusBadRequest, "bad json: "+err.Error())
		return
	}
	if req.Cluster == "" || req.Namespace == "" {
		httpErr(w, http.StatusBadRequest, "cluster and namespace are required")
		return
	}
	if req.SinceMinutes <= 0 {
		req.SinceMinutes = 60
	}
	if req.Scope == "" {
		req.Scope = policy.ScopeWorkload
	}

	base := clickhouse.EdgeQuery{
		Cluster:        req.Cluster,
		Namespace:      req.Namespace,
		SinceMinutes:   req.SinceMinutes,
		OnlyForwarded:  !req.IncludeDropped,
		SourceNSFilter: req.SourceNSFilter,
	}

	ingQ := base
	ingQ.Direction = clickhouse.DirIngress
	ingress, err := s.ch.Edges(ctx, ingQ)
	if err != nil {
		httpErr(w, http.StatusInternalServerError, err.Error())
		return
	}

	var egress []clickhouse.Edge
	if req.IncludeEgress {
		egQ := base
		egQ.Direction = clickhouse.DirEgress
		egress, err = s.ch.Edges(ctx, egQ)
		if err != nil {
			httpErr(w, http.StatusInternalServerError, err.Error())
			return
		}
	}

	cnps, err := policy.Generate(policy.GenerateInput{
		Cluster:   req.Cluster,
		Namespace: req.Namespace,
		Scope:     req.Scope,
		Targets:   req.Targets,
		Ingress:   ingress,
		Egress:    egress,
	})
	if err != nil {
		httpErr(w, http.StatusBadRequest, err.Error())
		return
	}
	yamlOut, err := policy.MarshalMulti(cnps)
	if err != nil {
		httpErr(w, http.StatusInternalServerError, err.Error())
		return
	}
	respond(w, GenerateResponse{Ingress: ingress, Egress: egress, YAML: yamlOut}, nil)
}

// ---- helpers ----

func ctx(r *http.Request) (context.Context, context.CancelFunc) {
	return context.WithTimeout(r.Context(), 30*time.Second)
}

func sinceMin(r *http.Request) int {
	if v := r.URL.Query().Get("sinceMinutes"); v != "" {
		if n, err := strconv.Atoi(v); err == nil && n > 0 {
			return n
		}
	}
	return 60
}

func respond(w http.ResponseWriter, v any, err error) {
	if err != nil {
		httpErr(w, http.StatusInternalServerError, err.Error())
		return
	}
	w.Header().Set("Content-Type", "application/json")
	_ = json.NewEncoder(w).Encode(v)
}

func httpErr(w http.ResponseWriter, code int, msg string) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(code)
	_ = json.NewEncoder(w).Encode(map[string]string{"error": msg})
}
