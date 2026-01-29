#!/bin/bash
# Crane Rental - hatch lifecycle hooks
# Place this alongside hatch.conf in the project root

TOKEN="0000000000000000000000000000000000000000"
ACTIONS_SECRET_KEY="2222222222222222222222222222222222222222"

crane_rental_setup() {
  local port
  port=$(hatch_resolve_port "contember-engine")
  local api_url="http://localhost:${port}"
  local content_url="${api_url}/content/crane-rental-management/live"
  local actions_url="${api_url}/actions/crane-rental-management"
  local tenant_url="${api_url}/tenant"

  _header "Crane Rental: Project-specific setup"

  # Step 1: Get tenant person ID
  _info "Getting tenant person ID..."
  local tenant_response
  tenant_response=$(curl --silent --request POST \
    --url "$tenant_url" \
    --header "Authorization: Bearer $TOKEN" \
    --header "Content-Type: application/json" \
    --data '{"query": "query { me { person { id } } }"}')

  local tenant_person_id
  tenant_person_id=$(echo "$tenant_response" | grep -o '"id":"[^"]*"' | head -1 | sed 's/"id":"//;s/"//')

  if [ -z "$tenant_person_id" ]; then
    _warn "Could not get tenant person ID"
    _warn "Response: $tenant_response"
    return
  fi

  _info "Tenant person ID: $tenant_person_id"

  # Step 2: Create Person record
  _info "Creating Person record..."
  local person_response
  person_response=$(curl --silent --request POST \
    --url "$content_url" \
    --header "Authorization: Bearer $TOKEN" \
    --header "Content-Type: application/json" \
    --data "{\"query\": \"mutation { createPerson(data: { personId: \\\"$tenant_person_id\\\" }) { ok node { id } } }\"}")

  local person_id
  person_id=$(echo "$person_response" | grep -o '"id":"[^"]*"' | head -1 | sed 's/"id":"//;s/"//')

  # If create failed, try to get existing
  if [ -z "$person_id" ]; then
    local get_person
    get_person=$(curl --silent --request POST \
      --url "$content_url" \
      --header "Authorization: Bearer $TOKEN" \
      --header "Content-Type: application/json" \
      --data "{\"query\": \"query { getPerson(by: { personId: \\\"$tenant_person_id\\\" }) { id } }\"}")
    person_id=$(echo "$get_person" | grep -o '"id":"[^"]*"' | head -1 | sed 's/"id":"//;s/"//')
  fi

  if [ -n "$person_id" ]; then
    _info "Person ID: $person_id"

    # Step 3: Create User record
    _info "Creating User record..."
    curl --silent --request POST \
      --url "$content_url" \
      --header "Authorization: Bearer $TOKEN" \
      --header "Content-Type: application/json" \
      --data "{\"query\": \"mutation { createUser(data: { person: { connect: { id: \\\"$person_id\\\" } }, firstName: \\\"Contember\\\", lastName: \\\"Admin\\\" }) { ok } }\"}" > /dev/null
    _success "User setup complete"
  else
    _warn "Could not create/find Person record"
  fi

  # Step 4: Set system variables
  _info "Setting system variables..."
  local worker_port
  worker_port=$(hatch_resolve_port "worker")
  local variables_response
  variables_response=$(curl --silent --request POST \
    --url "$actions_url" \
    --header "Authorization: Bearer $TOKEN" \
    --header "Content-Type: application/json" \
    --data "{\"query\": \"mutation { setVariables(args: { variables: [{ name: \\\"apiKey\\\", value: \\\"$ACTIONS_SECRET_KEY\\\" }, { name: \\\"baseUrl\\\", value: \\\"http://$(_docker_host):${worker_port}\\\" }] }) { ok } }\"}")

  if echo "$variables_response" | grep -q '"ok":true'; then
    _success "Variables set successfully"
  else
    _warn "Variables response: $variables_response"
  fi

  _success "Crane Rental setup complete"
}
