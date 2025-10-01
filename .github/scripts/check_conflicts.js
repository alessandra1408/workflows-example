const fs = require('fs');
const path = require('path');
const yaml = require('js-yaml');
const { globSync } = require('glob');
const automaton = require('automata.js');


// --- Configuração ---
const DEFAULT_HOSTS = {
    staging: [
        "payments-stg.pagar.me",
        "payments-stg.stone.com.br",
        "payments-stg.mundipagg.com"
    ],
    production: [
        "payments.pagar.me",
        "payments.stone.com.br",
        "payments.mundipagg.com"
    ],
};

function extractRoutes(filePath) {
    const routes = [];
    try {
        const fileContent = fs.readFileSync(filePath, 'utf8');
        const data = yaml.load(fileContent);
        if (!data || !data.services) return [];
        const env = filePath.includes('staging') ? 'staging' : 'production';
        const defaultHostsForEnv = DEFAULT_HOSTS[env] || [];
        for (const service of data.services || []) {
            for (const route of service.routes || []) {
                const hosts = route.hosts || defaultHostsForEnv;
                const paths = route.paths || [];
                for (const host of hosts) {
                    for (const p of paths) {
                        routes.push({ file: filePath, service: service.name, route: route.name, host: host, path: p });
                    }
                }
            }
        }
    } catch (e) {
        console.warn(`⚠️ Aviso: Falha ao ler o arquivo ${filePath}: ${e.message}`);
    }
    return routes;
}

function checkConflict(path1, path2) {
    const isRegex1 = path1.startsWith('~');
    const isRegex2 = path2.startsWith('~');
    const normalizeRegex = (str) => str.replace(/\(\?<[^>]+>/g, '(');
    let path1Clean = isRegex1 ? normalizeRegex(path1.substring(1)) : path1;
    let path2Clean = isRegex2 ? normalizeRegex(path2.substring(1)) : path2;

    if (!isRegex1 && !isRegex2) return path1 === path2;
    if (isRegex1 && !isRegex2) return new RegExp(`^${path1Clean}$`).test(path2);
    if (!isRegex1 && isRegex2) return new RegExp(`^${path2Clean}$`).test(path1);
    
    if (isRegex1 && isRegex2) {
        try {
            const nfa1 = automaton.regex.toNFA(path1Clean);
            const nfa2 = automaton.regex.toNFA(path2Clean);
            if (!nfa1 || !nfa2) {
                throw new Error("Falha ao converter regex para NFA.");
            }
            const intersectionNFA = automaton.nfa.intersection(nfa1, nfa2);
            return !automaton.nfa.isEmpty(intersectionNFA);
        } catch (e) {
            console.warn(`⚠️ Aviso: Falha na análise avançada de regex. Recorrendo à comparação de string para "${path1}" e "${path2}". Detalhe: ${e.message}`);
            return path1 === path2;
        }
    }
    return false;
}

async function main() {
    const changedFiles = process.argv.slice(2);
    if (changedFiles.length === 0) {
        console.log("✅ Nenhum arquivo de serviço foi alterado. Pulando a verificação.");
        process.exit(0);
    }
    console.log(`🔍 Arquivos alterados para verificação: ${changedFiles.join(', ')}`);
    const allServiceFiles = globSync('services/**/*.yml');
    const allRoutes = allServiceFiles.flatMap(extractRoutes);
    const changedRoutes = allRoutes.filter(r => changedFiles.includes(r.file));
    console.log("🔎 Verificando conflitos...");
    let conflictFound = false;
    for (const cRoute of changedRoutes) {
        for (const eRoute of allRoutes) {
            if (JSON.stringify(cRoute) === JSON.stringify(eRoute)) continue;
            if (cRoute.host === eRoute.host && checkConflict(cRoute.path, eRoute.path)) {
                conflictFound = true;
                console.log("\n" + "=".repeat(70), "\n🚨 ERRO: Conflito de Rota Detectado!", "\n" + "-".repeat(70));
                console.log("A rota em seu Pull Request:", `\n  - Arquivo:  ${cRoute.file}`, `\n  - Serviço:  ${cRoute.service}`, `\n  - Rota:     ${cRoute.route}`, `\n  - Host:     ${cRoute.host}`, `\n  - Path:     ${cRoute.path}`);
                console.log("\nEntra em conflito com a rota existente:", `\n  - Arquivo:  ${eRoute.file}`, `\n  - Serviço:  ${eRoute.service}`, `\n  - Rota:     ${eRoute.route}`, `\n  - Host:     ${eRoute.host}`, `\n  - Path:     ${eRoute.path}`);
                console.log("=".repeat(70) + "\n");
                break; 
            }
        }
        if (conflictFound) break;
    }
    if (conflictFound) process.exit(1);
    else console.log("✅ Nenhum conflito de rota foi detectado.");
}

main();