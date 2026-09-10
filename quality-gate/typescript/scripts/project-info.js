#!/usr/bin/env node
'use strict';

const fs = require('node:fs');
const path = require('node:path');

process.on('uncaughtException', (error) => {
  console.error(error.message);
  process.exit(1);
});

const rawArgs = process.argv.slice(2);
let directoryArgument = '.';
let check = '';
let requirePackageManager = false;

for (let i = 0; i < rawArgs.length; i++) {
  const arg = rawArgs[i];
  if (arg === '--require-package-manager') {
    requirePackageManager = true;
  } else if (arg === '--check') {
    if (i + 1 < rawArgs.length) {
      check = rawArgs[++i];
    }
  } else if (arg.startsWith('--check=')) {
    check = arg.slice('--check='.length);
  } else if (arg === '--working-directory') {
    if (i + 1 < rawArgs.length) {
      directoryArgument = rawArgs[++i];
    }
  } else if (arg.startsWith('--working-directory=')) {
    directoryArgument = arg.slice('--working-directory='.length);
  } else if (arg === '--') {
    if (i + 1 < rawArgs.length) {
      directoryArgument = rawArgs[++i];
    }
  } else if (!arg.startsWith('--')) {
    directoryArgument = arg;
  }
}

const checkRequiresRuntime = check === 'app:typecheck' || check === 'app:test';
const needsPackageManager = requirePackageManager || checkRequiresRuntime;
const projectDirectory = path.resolve(directoryArgument);
const readJson = (file) => JSON.parse(fs.readFileSync(path.join(projectDirectory, file), 'utf8'));
const project = readJson('package.json');
const dependencies = {
  ...(project.dependencies || {}),
  ...(project.devDependencies || {}),
  ...(project.optionalDependencies || {}),
};

if (checkRequiresRuntime && !fs.existsSync(path.join(projectDirectory, '.node-version'))) {
  throw new Error(`Missing .node-version for TypeScript ${check} check. Add the Node.js major version used by the project.`);
}

if (needsPackageManager) {
  if (fs.existsSync(path.join(projectDirectory, 'pnpm-lock.yaml'))) {
    const packageManager = project.packageManager || '';
    if (!packageManager.startsWith('pnpm@')) {
      throw new Error('package.json must declare packageManager as pnpm@<version>.');
    }
    console.log('manager=pnpm');
    console.log(`version=${packageManager.slice(5)}`);
  } else if (fs.existsSync(path.join(projectDirectory, 'package-lock.json'))) {
    console.log('manager=npm');
  } else {
    throw new Error('No lockfile found for TypeScript project. Commit pnpm-lock.yaml (pnpm) or package-lock.json (npm).');
  }
}

const ignoredDirectories = new Set(['.git', '.nuxt', 'node_modules', 'dist', 'build']);
const hasVueFile = (directory, depth = 0) => {
  if (!fs.existsSync(directory)) return false;
  for (const entry of fs.readdirSync(directory, { withFileTypes: true })) {
    if (ignoredDirectories.has(entry.name)) continue;
    const entryPath = path.join(directory, entry.name);
    if (entry.isDirectory() && depth < 5 && hasVueFile(entryPath, depth + 1)) return true;
    if (entry.isFile() && entry.name.endsWith('.vue')) return true;
  }
  return false;
};

const hasNuxtConfig = [
  'nuxt.config.ts',
  'nuxt.config.mts',
  'nuxt.config.js',
  'nuxt.config.mjs',
  'nuxt.config.cjs',
].some((file) => fs.existsSync(path.join(projectDirectory, file)));

let framework = 'none';
if (dependencies.nuxt || hasNuxtConfig) {
  framework = 'nuxt';
} else if (dependencies.vue || hasVueFile(projectDirectory)) {
  framework = 'vue';
}

const hasReact = Boolean(dependencies.react || dependencies['react-dom']);
const hasTypecheckScript = Boolean(project.scripts && project.scripts.typecheck);
console.log(`framework=${framework}`);
console.log(`react=${hasReact}`);
console.log(`has_typecheck_script=${hasTypecheckScript}`);
