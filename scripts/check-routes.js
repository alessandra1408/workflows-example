const fs = require('fs');
const path = require('path');
const yaml = require('js-yaml');

const changedFiles = JSON.parse(process.argv[2]);

// Carrega todas as rotas existentes (exceto as que estão sendo alteradas)
const allRoutes = fs.readdirSync('services')
  .filter(f => f.endsWith('.yaml') && !changedFiles.includes(`services/${f}`))
  .map(f => yaml.load(fs.readFileSync(path.join('services', f), 'utf8')));

// Carrega as rotas alteradas
const newRoutes = changedFiles.map(f => yaml.load(fs.readFileSync(f, 'utf8')));

// Função simples de detecção de conflito (host/regex)
function hasConflict(route, existingRoutes) {
  return existingRoutes.some(r => r.host === route.host && new RegExp(r.path).test(route.path));
}

// Verifica conflitos
let conflictDetected = false;
newRoutes.forEach(r => {
  if (hasConflict(r, allRoutes)) {
    console.error(`Conflito detectado para host=${r.host} path=${r.path}`);
    conflictDetected = true;
  }
});

if (conflictDetected) process.exit(1);
