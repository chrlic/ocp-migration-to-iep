<script setup>
import { onMounted, computed } from 'vue'
import { usePolicyGen } from './stores/policygen'
import EdgeTable from './components/EdgeTable.vue'

const s = usePolicyGen()
onMounted(() => s.loadClusters())

const canGenerate = computed(
  () =>
    s.cluster &&
    s.namespace &&
    (s.scope === 'namespace' || s.selectedTargets.length > 0),
)

function isSelected(w) {
  return s.selectedTargets.some((t) => t.name === w.name && t.kind === w.kind)
}
function copyYaml() {
  if (s.result?.yaml) navigator.clipboard.writeText(s.result.yaml)
}
function downloadYaml() {
  if (!s.result?.yaml) return
  const blob = new Blob([s.result.yaml], { type: 'text/yaml' })
  const a = document.createElement('a')
  a.href = URL.createObjectURL(blob)
  a.download = `cnp-${s.namespace}.yaml`
  a.click()
}
</script>

<template>
  <div class="layout">
    <aside class="panel">
      <h1>Timescape PolicyGen</h1>
      <p class="sub">Generate CiliumNetworkPolicy from observed flows (L4)</p>

      <label>Timeframe (minutes)
        <input type="number" min="5" v-model.number="s.sinceMinutes" @change="s.loadClusters()" />
      </label>

      <label>Target cluster
        <select :value="s.cluster" @change="s.selectCluster($event.target.value)">
          <option value="" disabled>— select —</option>
          <option v-for="c in s.clusters" :key="c" :value="c">{{ c }}</option>
        </select>
      </label>

      <label>Namespace
        <select :value="s.namespace" :disabled="!s.cluster" @change="s.selectNamespace($event.target.value)">
          <option value="" disabled>— select —</option>
          <option v-for="n in s.namespaces" :key="n" :value="n">{{ n }}</option>
        </select>
      </label>

      <fieldset class="scope">
        <legend>Policy scope</legend>
        <label class="radio"><input type="radio" value="workload" v-model="s.scope" /> Per workload</label>
        <label class="radio"><input type="radio" value="namespace" v-model="s.scope" /> Whole namespace</label>
      </fieldset>

      <div v-if="s.scope === 'workload' && s.namespace" class="workloads">
        <h4>Target workloads <span class="count">({{ s.selectedTargets.length }} selected)</span></h4>
        <ul>
          <li v-for="w in s.workloads" :key="w.kind + w.name"
              :class="{ sel: isSelected(w) }" @click="s.toggleTarget(w)">
            <span class="kind">{{ w.kind || 'Pod' }}</span> {{ w.name }}
          </li>
          <li v-if="!s.workloads.length" class="empty">no workloads in window</li>
        </ul>
      </div>

      <label>Source namespace filter (optional)
        <input type="text" v-model="s.sourceNamespaceFilter" placeholder="restrict peer namespace" />
      </label>

      <label class="check"><input type="checkbox" v-model="s.includeEgress" /> include egress rules</label>
      <label class="check"><input type="checkbox" v-model="s.includeDropped" /> include DROPPED flows (audit)</label>

      <button :disabled="!canGenerate || s.loading" @click="s.generate()">
        {{ s.loading ? 'Generating…' : 'Generate policy' }}
      </button>
      <p v-if="s.error" class="error">{{ s.error }}</p>
    </aside>

    <main class="content">
      <template v-if="s.result">
        <section class="yaml">
          <div class="yaml-head">
            <h3>Generated CiliumNetworkPolicy</h3>
            <div>
              <button @click="copyYaml">Copy</button>
              <button @click="downloadYaml">Download</button>
            </div>
          </div>
          <pre>{{ s.result.yaml }}</pre>
          <p class="hint">Review and apply in audit mode first: <code>oc apply -f cnp.yaml</code></p>
        </section>
        <section class="edges">
          <EdgeTable title="Ingress (into target)" :edges="s.result.ingress" peer-label="Source" />
          <EdgeTable v-if="s.includeEgress" title="Egress (from target)" :edges="s.result.egress" peer-label="Destination" />
        </section>
      </template>
      <div v-else class="placeholder">
        <p>Select a cluster, namespace, and target(s), then generate a policy from the flows Timescape observed in the chosen window.</p>
      </div>
    </main>
  </div>
</template>
