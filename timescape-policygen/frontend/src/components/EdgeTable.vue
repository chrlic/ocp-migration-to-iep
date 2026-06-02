<script setup>
defineProps({
  title: { type: String, required: true },
  edges: { type: Array, default: () => [] },
  peerLabel: { type: String, default: 'Source' },
})

function peerName(e) {
  if (e.peerWorkload) return `${e.peerNamespace || '?'}/${e.peerWorkload}`
  if (e.peerNamespace) return `${e.peerNamespace} (pod)`
  if (e.peerIdentity) return `reserved:${e.peerIdentity}` // host/world/...
  return 'unknown'
}
</script>

<template>
  <div class="edge-table" v-if="edges && edges.length">
    <h4>{{ title }} <span class="count">({{ edges.length }} edges)</span></h4>
    <table>
      <thead>
        <tr>
          <th>{{ peerLabel }}</th>
          <th>Target</th>
          <th>Proto</th>
          <th>Port</th>
          <th>Flows</th>
        </tr>
      </thead>
      <tbody>
        <tr v-for="(e, i) in edges" :key="i">
          <td>{{ peerName(e) }}</td>
          <td>{{ e.targetWorkload || '—' }}</td>
          <td>{{ e.protocol }}</td>
          <td>{{ e.port }}</td>
          <td class="num">{{ e.flows }}</td>
        </tr>
      </tbody>
    </table>
  </div>
</template>
