// Thin fetch wrapper for the Go backend. All ClickHouse access is server-side.
const j = async (res) => {
  if (!res.ok) {
    const body = await res.json().catch(() => ({}))
    throw new Error(body.error || `HTTP ${res.status}`)
  }
  return res.json()
}

export const api = {
  clusters: (sinceMinutes) =>
    fetch(`/api/clusters?sinceMinutes=${sinceMinutes}`).then(j),

  namespaces: (cluster, sinceMinutes) =>
    fetch(`/api/namespaces?cluster=${encodeURIComponent(cluster)}&sinceMinutes=${sinceMinutes}`).then(j),

  workloads: (cluster, namespace, sinceMinutes) =>
    fetch(
      `/api/workloads?cluster=${encodeURIComponent(cluster)}&namespace=${encodeURIComponent(
        namespace,
      )}&sinceMinutes=${sinceMinutes}`,
    ).then(j),

  generate: (body) =>
    fetch('/api/generate', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify(body),
    }).then(j),
}
