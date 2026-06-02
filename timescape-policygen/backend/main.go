// timescape-policygen: a Timescape-like GUI backend that turns observed Hubble
// flows (in ClickHouse) into CiliumNetworkPolicy. L4 in phase 1; L7 to follow.
//
// Config via env (see deploy/):
//   CH_ADDR      ClickHouse native endpoint, default chi-...:9000
//   CH_DATABASE  default "hubble"
//   CH_USER / CH_PASSWORD
//   LISTEN_ADDR  default ":8080"
//   STATIC_DIR   optional: serve the built Vue SPA from this dir
package main

import (
	"log"
	"net/http"
	"os"

	"github.com/mdivis/timescape-policygen/internal/api"
	"github.com/mdivis/timescape-policygen/internal/clickhouse"
)

func main() {
	ch, err := clickhouse.New(clickhouse.Config{
		Addr:     env("CH_ADDR", "clickhouse-hubble-timescape.hubble-timescape-install.svc.cluster.local:9000"),
		Database: env("CH_DATABASE", "hubble"),
		Username: env("CH_USER", "default"),
		Password: os.Getenv("CH_PASSWORD"),
	})
	if err != nil {
		log.Fatalf("clickhouse: %v", err)
	}
	defer ch.Close()

	srv := api.New(ch)

	mux := http.NewServeMux()
	mux.Handle("/api/", srv.Handler())

	// Serve the built SPA if present (single-container deployment).
	if dir := os.Getenv("STATIC_DIR"); dir != "" {
		fs := http.FileServer(http.Dir(dir))
		mux.Handle("/", spaFallback(dir, fs))
	}

	addr := env("LISTEN_ADDR", ":8080")
	log.Printf("listening on %s", addr)
	log.Fatal(http.ListenAndServe(addr, mux))
}

// spaFallback serves index.html for unknown paths so the Vue router works.
func spaFallback(dir string, fs http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if _, err := os.Stat(dir + r.URL.Path); os.IsNotExist(err) && r.URL.Path != "/" {
			http.ServeFile(w, r, dir+"/index.html")
			return
		}
		fs.ServeHTTP(w, r)
	})
}

func env(k, def string) string {
	if v := os.Getenv(k); v != "" {
		return v
	}
	return def
}
