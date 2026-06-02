import { defineStore } from 'pinia'
import { api } from '../api/client'

// Central state for the cascading selectors and the generation result.
export const usePolicyGen = defineStore('policygen', {
  state: () => ({
    // selection
    sinceMinutes: 60,
    cluster: '',
    namespace: '',
    scope: 'workload', // 'workload' | 'namespace'
    selectedTargets: [], // [{kind,name}]
    sourceNamespaceFilter: '',
    includeEgress: false,
    includeDropped: false,

    // options loaded from backend
    clusters: [],
    namespaces: [],
    workloads: [],

    // result
    result: null, // { ingress, egress, yaml }
    loading: false,
    error: '',
  }),
  actions: {
    async loadClusters() {
      this.error = ''
      try {
        this.clusters = (await api.clusters(this.sinceMinutes)) || []
      } catch (e) {
        this.error = e.message
      }
    },
    async selectCluster(c) {
      this.cluster = c
      this.namespace = ''
      this.workloads = []
      this.selectedTargets = []
      this.result = null
      try {
        this.namespaces = (await api.namespaces(c, this.sinceMinutes)) || []
      } catch (e) {
        this.error = e.message
      }
    },
    async selectNamespace(ns) {
      this.namespace = ns
      this.selectedTargets = []
      this.result = null
      try {
        this.workloads = (await api.workloads(this.cluster, ns, this.sinceMinutes)) || []
      } catch (e) {
        this.error = e.message
      }
    },
    toggleTarget(w) {
      const i = this.selectedTargets.findIndex((t) => t.name === w.name && t.kind === w.kind)
      if (i >= 0) this.selectedTargets.splice(i, 1)
      else this.selectedTargets.push(w)
    },
    async generate() {
      this.error = ''
      this.loading = true
      this.result = null
      try {
        this.result = await api.generate({
          cluster: this.cluster,
          namespace: this.namespace,
          scope: this.scope,
          targets: this.scope === 'workload' ? this.selectedTargets : [],
          sourceNamespaceFilter: this.sourceNamespaceFilter,
          sinceMinutes: this.sinceMinutes,
          includeEgress: this.includeEgress,
          includeDropped: this.includeDropped,
        })
      } catch (e) {
        this.error = e.message
      } finally {
        this.loading = false
      }
    },
  },
})
