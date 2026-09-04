<script setup lang="ts">
import { computed, ref } from "vue";

const count = ref(0);
const doubled = computed(() => count.value * 2);
</script>

<template>
  <main>
    <button type="button" @click="count++">Count: {{ count }}</button>
    <output>{{ doubled }}</output>
  </main>
</template>
