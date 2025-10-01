#!/bin/bash
set -e

DEFAULT_STAGING_HOSTS=(
  "payments-stg.pagar.me"
  "payments-stg.stone.com.br"
  "payments-stg.mundipagg.com"
)
DEFAULT_PRODUCTION_HOSTS=(
  "payments.pagar.me"
  "payments.stone.com.br"
  "payments.mundipagg.com"
)

if [ -z "$1" ]; then
  echo "✅ Nenhum arquivo de serviço foi alterado. Pulando a verificação."
  exit 0
fi

CHANGED_FILES="$1"
echo "🔍 Arquivos alterados para verificação: $CHANGED_FILES"

extract_routes() {
  find services -type f -name '*.yml' | while read -r file; do
    # Determina qual lista de hosts padrão usar
    local -n default_hosts_ref=DEFAULT_STAGING_HOSTS # Referência para o array
    if [[ "$file" == *"services/production/"* ]]; then
      default_hosts_ref=DEFAULT_PRODUCTION_HOSTS
    fi

    # Converte o array bash para um array JSON para passar ao jq
    default_hosts_json=$(printf '%s\n' "${default_hosts_ref[@]}" | jq -R . | jq -s .)

    # yq para converter para JSON, jq para extrair e achatar os dados
    yq e -o=json "$file" | jq -c \
      --arg file "$file" \
      --argjson default_hosts "$default_hosts_json" \
      '
      .services[]? | . as $service |
      .routes[]? | . as $route |
      # Usa a LISTA de hosts padrão se .hosts for nulo ou vazio
      ($route.hosts // $default_hosts | if length == 0 then $default_hosts else . end) as $hosts |
      ($route.paths // []) as $paths |
      # Expande para criar um objeto para cada combinação de host e path
      $hosts[] as $h |
      $paths[] as $p |
      {
        file: $file,
        service: $service.name,
        route: $route.name,
        host: $h,
        path: $p
      }
      '
  done
}

# --- Lógica Principal (o restante do script permanece o mesmo) ---
CONFLICT_FOUND=0
echo "⚙️  Construindo o mapa de todas as rotas existentes..."
ALL_ROUTES_FLAT=$(extract_routes)

# Pega apenas as rotas dos arquivos alterados
CHANGED_ROUTES_FLAT=$(echo "$ALL_ROUTES_FLAT" | grep -Ff <(echo "$CHANGED_FILES" | tr ' ' '\n'))

echo "🔎 Verificando conflitos para as rotas alteradas..."

# Itera sobre cada rota alterada
while read -r changed_route_json; do
  c_file=$(echo "$changed_route_json" | jq -r .file)
  c_service=$(echo "$changed_route_json" | jq -r .service)
  c_route=$(echo "$changed_route_json" | jq -r .route)
  c_host=$(echo "$changed_route_json" | jq -r .host)
  c_path=$(echo "$changed_route_json" | jq -r .path)

  # Itera sobre todas as rotas existentes para comparação
  while read -r existing_route_json; do
    e_file=$(echo "$existing_route_json" | jq -r .file)
    e_service=$(echo "$existing_route_json" | jq -r .service)
    e_route=$(echo "$existing_route_json" | jq -r .route)
    e_host=$(echo "$existing_route_json" | jq -r .host)
    e_path=$(echo "$existing_route_json" | jq -r .path)

    # Não compara uma rota consigo mesma (mesmo arquivo, serviço e rota)
    if [ "$c_file" == "$e_file" ] && [ "$c_service" == "$e_service" ] && [ "$c_route" == "$e_route" ]; then
      continue
    fi
    
    # Verifica se os hosts são iguais
    if [ "$c_host" == "$e_host" ]; then
      # Lógica de comparação de paths (incluindo regex)
      # Remove o prefixo '~' para o match de regex em bash
      c_path_clean=${c_path#\~}
      e_path_clean=${e_path#\~}
      
      # Caso 1: Ambos são strings literais e iguais
      if [[ ! "$c_path" == "~"* && ! "$e_path" == "~"* && "$c_path" == "$e_path" ]]; then
        CONFLICT_FOUND=1
        
      # Caso 2: Path existente é regex e dá match com o novo path
      elif [[ "$e_path" == "~"* && "$c_path" != "~"* && "$c_path" =~ $e_path_clean ]]; then
        CONFLICT_FOUND=1

      # Caso 3: Novo path é regex e dá match com o path existente
      elif [[ "$c_path" == "~"* && "$e_path" != "~"* && "$e_path" =~ $c_path_clean ]]; then
        CONFLICT_FOUND=1
      
      # Caso 4: Ambos são regex e são idênticos (checar sobreposição real é muito complexo)
      elif [[ "$c_path" == "~"* && "$e_path" == "~"* && "$c_path" == "$e_path" ]]; then
        CONFLICT_FOUND=1
      fi

      if [ $CONFLICT_FOUND -eq 1 ]; then
        echo "======================================================================"
        echo "🚨 ERRO: Conflito de Rota Detectado!"
        echo "----------------------------------------------------------------------"
        echo "A rota em seu Pull Request:"
        echo "  - Arquivo:  $c_file"
        echo "  - Serviço:  $c_service"
        echo "  - Rota:     $c_route"
        echo "  - Host:     $c_host"
        echo "  - Path:     $c_path"
        echo ""
        echo "Entra em conflito com a rota existente:"
        echo "  - Arquivo:  $e_file"
        echo "  - Serviço:  $e_service"
        echo "  - Rota:     $e_route"
        echo "  - Host:     $e_host"
        echo "  - Path:     $e_path"
        echo "======================================================================"
        # Não precisa continuar checando esta rota, já encontramos um conflito
        break
      fi
    fi
  done < <(echo "$ALL_ROUTES_FLAT") # Alimenta o loop com a lista de todas as rotas
  
  if [ $CONFLICT_FOUND -eq 1 ]; then
    # Para o script inteiro se um conflito for encontrado
    break
  fi
done < <(echo "$CHANGED_ROUTES_FLAT") # Alimenta o loop com a lista de rotas alteradas

# --- Conclusão ---
if [ $CONFLICT_FOUND -eq 1 ]; then
  exit 1
else
  echo "✅ Nenhum conflito de rota foi detectado."
  exit 0
fi