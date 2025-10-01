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

# --- Validação de Entradas ---
if [ -z "$1" ]; then
  echo "✅ Nenhum arquivo de serviço foi alterado. Pulando a verificação."
  exit 0
fi

CHANGED_FILES="$1"
echo "🔍 Arquivos alterados para verificação: $CHANGED_FILES"

# --- Função para extrair todas as rotas de todos os arquivos ---
extract_routes() {
  find services -type f -name '*.yml' | while read -r file; do
    local -n default_hosts_ref=DEFAULT_STAGING_HOSTS
    if [[ "$file" == *"services/production/"* ]]; then
      default_hosts_ref=DEFAULT_PRODUCTION_HOSTS
    fi
    default_hosts_json=$(printf '%s\n' "${default_hosts_ref[@]}" | jq -R . | jq -s .)
    yq e -o=json "$file" | jq -c \
      --arg file "$file" \
      --argjson default_hosts "$default_hosts_json" \
      '
      .services[]? | . as $service |
      .routes[]? | . as $route |
      ($route.hosts // $default_hosts | if length == 0 then $default_hosts else . end) as $hosts |
      ($route.paths // []) as $paths |
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

# --- Lógica Principal ---
CONFLICT_FOUND=0
echo "⚙️  Construindo o mapa de todas as rotas existentes..."
ALL_ROUTES_FLAT=$(extract_routes)
CHANGED_ROUTES_FLAT=$(echo "$ALL_ROUTES_FLAT" | grep -Ff <(echo "$CHANGED_FILES" | tr ' ' '\n'))

echo "🔎 Verificando conflitos para as rotas alteradas..."

while read -r changed_route_json; do
  c_host=$(echo "$changed_route_json" | jq -r .host)
  c_path=$(echo "$changed_route_json" | jq -r .path)

  while read -r existing_route_json; do
    # ✅✅✅ CORREÇÃO APLICADA AQUI ✅✅✅
    # Compara as strings JSON inteiras. Isso previne que uma rota seja comparada
    # consigo mesma, mas permite a comparação de duas rotas idênticas em arquivos diferentes.
    if [ "$changed_route_json" == "$existing_route_json" ]; then
      continue
    fi
    
    e_host=$(echo "$existing_route_json" | jq -r .host)
    e_path=$(echo "$existing_route_json" | jq -r .path)

    if [ "$c_host" == "$e_host" ]; then
      c_path_clean=${c_path#\~}
      e_path_clean=${e_path#\~}
      
      CONFLICT=0
      if [[ ! "$c_path" == "~"* && ! "$e_path" == "~"* && "$c_path" == "$e_path" ]]; then
        CONFLICT=1
      elif [[ "$e_path" == "~"* && ! "$c_path" == "~"* && "$c_path" =~ $e_path_clean ]]; then
        CONFLICT=1
      elif [[ "$c_path" == "~"* && ! "$e_path" == "~"* && "$e_path" =~ $c_path_clean ]]; then
        CONFLICT=1
      elif [[ "$c_path" == "~"* && "$e_path" == "~"* && "$c_path" == "$e_path" ]]; then
        CONFLICT=1
      fi

      if [ $CONFLICT -eq 1 ]; then
        CONFLICT_FOUND=1
        c_file=$(echo "$changed_route_json" | jq -r .file)
        c_service=$(echo "$changed_route_json" | jq -r .service)
        c_route=$(echo "$changed_route_json" | jq -r .route)
        e_file=$(echo "$existing_route_json" | jq -r .file)
        e_service=$(echo "$existing_route_json" | jq -r .service)
        e_route=$(echo "$existing_route_json" | jq -r .route)

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
        break
      fi
    fi
  done < <(echo "$ALL_ROUTES_FLAT")
  
  if [ $CONFLICT_FOUND -eq 1 ]; then
    break
  fi
done < <(echo "$CHANGED_ROUTES_FLAT")

# --- Conclusão ---
if [ $CONFLICT_FOUND -eq 1 ]; then
  exit 1
else
  echo "✅ Nenhum conflito de rota foi detectado."
  exit 0
fi
