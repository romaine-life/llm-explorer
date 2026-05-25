# ============================================================================
# llm-explorer infrastructure
# ============================================================================
# Per-app workload identity for the llm-explorer pod, plus the data-plane
# grants the pod actually needs.
#
# Migrated from nelsong6/infra-bootstrap/tofu/llm-explorer-identity.tf as
# part of retiring the "app-specific resources in shared bootstrap" anti-
# pattern. infra-bootstrap creates the per-app SP + grants it Owner on
# the cluster sub; the app's own tofu owns everything else.
#
# Resources are imported in-place from infra-bootstrap.tfstate via the
# `import` blocks below. Companion change in infra-bootstrap drops them
# from that state with `removed { lifecycle { destroy = false } }`.
# ============================================================================

# ----------------------------------------------------------------------------
# UAMI — the pod's workload identity
# ----------------------------------------------------------------------------
resource "azurerm_user_assigned_identity" "llm_explorer" {
  name                = "llm-explorer-identity"
  resource_group_name = data.azurerm_resource_group.main.name
  location            = data.azurerm_resource_group.main.location
}

import {
  to = azurerm_user_assigned_identity.llm_explorer
  id = "/subscriptions/aee0cbd2-8074-4001-b610-0f8edb4eaa3c/resourceGroups/infra/providers/Microsoft.ManagedIdentity/userAssignedIdentities/llm-explorer-identity"
}

# ----------------------------------------------------------------------------
# Data-plane grants the pod actually uses
# ----------------------------------------------------------------------------
# Cosmos data-plane on HomepageDB — Built-in Data Contributor lets the
# pod query the `userdata` container filtered by `type='llm-session'`.
resource "azurerm_cosmosdb_sql_role_assignment" "llm_explorer_cosmos" {
  resource_group_name = data.azurerm_resource_group.main.name
  account_name        = data.azurerm_cosmosdb_account.serverless.name
  role_definition_id  = "${data.azurerm_cosmosdb_account.serverless.id}/sqlRoleDefinitions/00000000-0000-0000-0000-000000000002"
  principal_id        = azurerm_user_assigned_identity.llm_explorer.principal_id
  scope               = "${data.azurerm_cosmosdb_account.serverless.id}/dbs/HomepageDB"
}

import {
  to = azurerm_cosmosdb_sql_role_assignment.llm_explorer_cosmos
  id = "/subscriptions/aee0cbd2-8074-4001-b610-0f8edb4eaa3c/resourceGroups/infra/providers/Microsoft.DocumentDB/databaseAccounts/infra-cosmos-serverless/sqlRoleAssignments/cbf8b44c-7af5-f0a3-a496-3064c1586ed2"
}

# Key Vault Secrets User on the legacy shared JWT-signing secret that
# config.js reads.
resource "azurerm_role_assignment" "llm_explorer_kv_jwt_secret" {
  scope                = "${data.azurerm_key_vault.shared.id}/secrets/api-jwt-signing-secret"
  role_definition_name = "Key Vault Secrets User"
  principal_id         = azurerm_user_assigned_identity.llm_explorer.principal_id
}

import {
  to = azurerm_role_assignment.llm_explorer_kv_jwt_secret
  id = "/subscriptions/aee0cbd2-8074-4001-b610-0f8edb4eaa3c/resourceGroups/infra/providers/Microsoft.KeyVault/vaults/romaine-kv/secrets/api-jwt-signing-secret/providers/Microsoft.Authorization/roleAssignments/8b12305b-6a6f-4263-5432-1f14c3e874da"
}

resource "azurerm_role_assignment" "llm_explorer_app_keyvault" {
  scope                = azurerm_key_vault.main.id
  role_definition_name = "Key Vault Secrets User"
  principal_id         = azurerm_user_assigned_identity.llm_explorer.principal_id
}

# App Configuration Data Reader at store level — config.js reads
# `cosmos_db_endpoint` (App Config has no per-key RBAC).
resource "azurerm_role_assignment" "llm_explorer_appconfig" {
  scope                = data.azurerm_app_configuration.main.id
  role_definition_name = "App Configuration Data Reader"
  principal_id         = azurerm_user_assigned_identity.llm_explorer.principal_id
}

import {
  to = azurerm_role_assignment.llm_explorer_appconfig
  id = "/subscriptions/aee0cbd2-8074-4001-b610-0f8edb4eaa3c/resourceGroups/infra/providers/Microsoft.AppConfiguration/configurationStores/infra-appconfig/providers/Microsoft.Authorization/roleAssignments/d51f3233-e09e-cb03-586d-337cfce5732f"
}

# ----------------------------------------------------------------------------
# Federated credential — binds the pod SA to this UAMI
# ----------------------------------------------------------------------------
# Single FIC for the dedicated-cluster topology. The pre-migration shape
# in infra-bootstrap had a paired `aks-llm-explorer` FIC gated on the
# same-sub case (count = local.cluster_uses_dedicated_subscription ? 0
# : 1) that has never been live; only `aks-cluster-llm-explorer` is in
# state. Carry forward just the live one.
resource "azurerm_federated_identity_credential" "llm_explorer" {
  name                = "aks-cluster-llm-explorer"
  resource_group_name = data.azurerm_resource_group.main.name
  parent_id           = azurerm_user_assigned_identity.llm_explorer.id
  audience            = ["api://AzureADTokenExchange"]
  issuer              = local.aks_oidc_issuer_url
  subject             = "system:serviceaccount:llm-explorer:infra-shared"
}

import {
  to = azurerm_federated_identity_credential.llm_explorer
  id = "/subscriptions/aee0cbd2-8074-4001-b610-0f8edb4eaa3c/resourceGroups/infra/providers/Microsoft.ManagedIdentity/userAssignedIdentities/llm-explorer-identity/federatedIdentityCredentials/aks-cluster-llm-explorer"
}

output "llm_explorer_identity_client_id" {
  value       = azurerm_user_assigned_identity.llm_explorer.client_id
  description = "client_id of llm-explorer-identity. Pin into llm-explorer/k8s/serviceaccount.yaml."
}
